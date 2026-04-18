defmodule Espex.DispatchTest do
  use ExUnit.Case, async: true

  alias Espex.{ConnectionState, DeviceConfig, Dispatch, InfraredProxy, Proto, SerialProxy}
  alias Espex.Test.{FakeEntityProvider, FakeInfraredProxy}

  defp state(overrides \\ []) do
    defaults = [
      device_config: %DeviceConfig{name: "test", project_name: "test_proj", project_version: "0.0.1"},
      peer: "1.2.3.4:5678",
      clock_fun: fn -> 1_700_000_000 end
    ]

    ConnectionState.new(Keyword.merge(defaults, overrides))
  end

  describe "HelloRequest" do
    test "sends HelloResponse with API version and server info" do
      {_state, effects} = Dispatch.step(state(), %Proto.HelloRequest{client_info: "test-client"})
      assert [{:log, :info, _}, {:send, response}] = effects
      assert response.api_version_major == DeviceConfig.api_version_major()
      assert response.api_version_minor == DeviceConfig.api_version_minor()
      assert response.name == "test"
      assert response.server_info =~ "test_proj"
    end
  end

  describe "AuthenticationRequest / PingRequest" do
    test "auth: invalid_password is false" do
      {_s, [{:send, %Proto.AuthenticationResponse{invalid_password: false}}]} =
        Dispatch.step(state(), %Proto.AuthenticationRequest{})
    end

    test "ping: empty response" do
      assert {_s, [{:send, %Proto.PingResponse{}}]} = Dispatch.step(state(), %Proto.PingRequest{})
    end
  end

  describe "DeviceInfoRequest" do
    test "response includes serial proxies from frozen state" do
      info = SerialProxy.Info.new(instance: 0, name: "zigbee", port_type: :ttl)
      {_s, [{:send, resp}]} = Dispatch.step(state(serial_proxies: [info]), %Proto.DeviceInfoRequest{})
      assert resp.name == "test"
      assert [%Proto.SerialProxyInfo{name: "zigbee", port_type: :SERIAL_PROXY_PORT_TYPE_TTL}] = resp.serial_proxies
    end

    test "response uses zwave fields from config" do
      cfg = %DeviceConfig{zwave_feature_flags: 1, zwave_home_id: 0x1234}
      {_s, [{:send, resp}]} = Dispatch.step(state(device_config: cfg), %Proto.DeviceInfoRequest{})
      assert resp.zwave_proxy_feature_flags == 1
      assert resp.zwave_home_id == 0x1234
    end
  end

  describe "ListEntitiesRequest" do
    test "returns only Done when no adapters configured" do
      {_s, [{:send, %Proto.ListEntitiesDoneResponse{}}]} =
        Dispatch.step(state(), %Proto.ListEntitiesRequest{})
    end

    test "emits frozen IR entities then Done" do
      ir = InfraredProxy.Entity.new(key: 42, object_id: "ir", name: "IR", capabilities: [:transmit])
      {_s, effects} = Dispatch.step(state(infrared_entities: [ir]), %Proto.ListEntitiesRequest{})

      assert [
               {:send, %Proto.ListEntitiesInfraredResponse{key: 42, name: "IR"}},
               {:send, %Proto.ListEntitiesDoneResponse{}}
             ] = effects
    end

    test "emits frozen custom entities" do
      custom = %Proto.ListEntitiesBinarySensorResponse{key: 7, object_id: "x", name: "X"}
      {_s, effects} = Dispatch.step(state(entities: [custom]), %Proto.ListEntitiesRequest{})
      assert [{:send, ^custom}, {:send, %Proto.ListEntitiesDoneResponse{}}] = effects
    end

    test "does not call adapter list_entities at dispatch time — state is the source of truth" do
      adapters = %{
        serial_proxy: nil,
        zwave_proxy: nil,
        infrared_proxy: FakeInfraredProxy,
        entity_provider: FakeEntityProvider
      }

      {_s, effects} = Dispatch.step(state(adapters: adapters), %Proto.ListEntitiesRequest{})
      assert effects == [{:send, %Proto.ListEntitiesDoneResponse{}}]
    end
  end

  describe "SubscribeStatesRequest" do
    test "no adapter: no effects" do
      {_s, effects} = Dispatch.step(state(), %Proto.SubscribeStatesRequest{})
      assert effects == []
    end

    test "with EntityProvider: emits initial states" do
      adapters = %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: nil, entity_provider: FakeEntityProvider}
      {_s, effects} = Dispatch.step(state(adapters: adapters), %Proto.SubscribeStatesRequest{})

      assert [{:send, %Proto.BinarySensorStateResponse{key: 1, state: true}}] = effects
    end

    test "with InfraredProxy: emits :infrared_subscribe effect once and flips the flag" do
      adapters = %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: FakeInfraredProxy, entity_provider: nil}
      {state_after, effects} = Dispatch.step(state(adapters: adapters), %Proto.SubscribeStatesRequest{})
      assert effects == [:infrared_subscribe]
      assert state_after.infrared_subscribed

      {_, effects} = Dispatch.step(state_after, %Proto.SubscribeStatesRequest{})
      assert effects == []
    end
  end

  describe "DisconnectRequest" do
    test "sends DisconnectResponse and closes" do
      {_s, effects} = Dispatch.step(state(), %Proto.DisconnectRequest{})
      assert [{:log, _, _}, {:send, %Proto.DisconnectResponse{}}, {:close, :disconnect_requested}] = effects
    end
  end

  describe "GetTimeRequest" do
    test "uses injected clock_fun and masks to 32 bits" do
      {_s, [{:send, %Proto.GetTimeResponse{epoch_seconds: 1_700_000_000}}]} =
        Dispatch.step(state(), %Proto.GetTimeRequest{})
    end

    test "masks values exceeding 32 bits" do
      huge = 0x1_0000_0042
      {_s, [{:send, %Proto.GetTimeResponse{epoch_seconds: seconds}}]} =
        Dispatch.step(state(clock_fun: fn -> huge end), %Proto.GetTimeRequest{})

      assert seconds == 0x42
    end
  end

  describe "SerialProxyConfigureRequest" do
    test "unknown instance: logs warning, no open" do
      {_s, [{:log, :warning, msg}]} =
        Dispatch.step(state(), %Proto.SerialProxyConfigureRequest{instance: 99})

      assert msg =~ "unknown instance 99"
    end

    test "known instance, not yet open: emits :serial_open with translated opts" do
      info = SerialProxy.Info.new(instance: 0, name: "n", port_type: :ttl)

      req = %Proto.SerialProxyConfigureRequest{
        instance: 0,
        baudrate: 115_200,
        data_size: 8,
        stop_bits: 1,
        parity: :SERIAL_PROXY_PARITY_EVEN,
        flow_control: true
      }

      {_s, [{:serial_open, 0, opts}]} = Dispatch.step(state(serial_proxies: [info]), req)
      assert opts[:speed] == 115_200
      assert opts[:parity] == :even
      assert opts[:flow_control] == :hardware
    end

    test "known instance already open: emits :serial_close then :serial_open" do
      info = SerialProxy.Info.new(instance: 0, name: "n")
      s = state(serial_proxies: [info]) |> ConnectionState.put_port(0, :existing_handle)
      {_s, effects} = Dispatch.step(s, %Proto.SerialProxyConfigureRequest{instance: 0})
      assert [{:serial_close, 0}, {:serial_open, 0, _opts}] = effects
    end
  end

  describe "SerialProxyWriteRequest" do
    test "opened instance: emits :serial_write" do
      s = state() |> ConnectionState.put_port(3, :h)
      {_s, [{:serial_write, 3, "hi"}]} = Dispatch.step(s, %Proto.SerialProxyWriteRequest{instance: 3, data: "hi"})
    end

    test "unopened instance: logs warning" do
      {_s, [{:log, :warning, _}]} =
        Dispatch.step(state(), %Proto.SerialProxyWriteRequest{instance: 3, data: "hi"})
    end
  end

  describe "ZWaveProxyRequest" do
    test "subscribe with adapter: emits :zwave_subscribe" do
      adapters = %{serial_proxy: nil, zwave_proxy: Espex.Test.FakeZWaveProxy, infrared_proxy: nil, entity_provider: nil}
      {_s, [:zwave_subscribe]} =
        Dispatch.step(state(adapters: adapters), %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE})
    end

    test "subscribe without adapter: logs only" do
      {_s, [{:log, :info, _}]} =
        Dispatch.step(state(), %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE})
    end

    test "unsubscribe when subscribed: flips flag and emits effect" do
      s = state() |> ConnectionState.put_zwave_subscribed(true)
      {new_s, [:zwave_unsubscribe]} =
        Dispatch.step(s, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE})

      refute new_s.zwave_subscribed
    end

    test "unsubscribe when not subscribed: no effects" do
      {_s, []} = Dispatch.step(state(), %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE})
    end
  end

  describe "ZWaveProxyFrame" do
    test "with adapter: emits :zwave_send_frame" do
      adapters = %{serial_proxy: nil, zwave_proxy: Espex.Test.FakeZWaveProxy, infrared_proxy: nil, entity_provider: nil}
      {_s, [{:zwave_send_frame, "abc"}]} = Dispatch.step(state(adapters: adapters), %Proto.ZWaveProxyFrame{data: "abc"})
    end

    test "without adapter: logs warning" do
      {_s, [{:log, :warning, _}]} = Dispatch.step(state(), %Proto.ZWaveProxyFrame{data: "abc"})
    end
  end

  describe "InfraredRFTransmitRawTimingsRequest" do
    test "with adapter, first time: subscribes and transmits with defaults" do
      adapters = %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: FakeInfraredProxy, entity_provider: nil}
      req = %Proto.InfraredRFTransmitRawTimingsRequest{key: 99, timings: [100, 200]}
      {new_s, effects} = Dispatch.step(state(adapters: adapters), req)

      assert [:infrared_subscribe, {:infrared_transmit, 99, [100, 200], opts}] = effects
      assert opts[:carrier_frequency] == 38_000
      assert opts[:repeat_count] == 1
      assert new_s.infrared_subscribed
    end

    test "with adapter, already subscribed: just transmits" do
      adapters = %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: FakeInfraredProxy, entity_provider: nil}
      s = state(adapters: adapters) |> ConnectionState.put_infrared_subscribed(true)
      req = %Proto.InfraredRFTransmitRawTimingsRequest{key: 99, timings: [1], carrier_frequency: 40_000, repeat_count: 3}

      {_s, [{:infrared_transmit, 99, [1], opts}]} = Dispatch.step(s, req)
      assert opts[:carrier_frequency] == 40_000
      assert opts[:repeat_count] == 3
    end

    test "without adapter: logs warning" do
      {_s, [{:log, :warning, _}]} =
        Dispatch.step(state(), %Proto.InfraredRFTransmitRawTimingsRequest{key: 1, timings: []})
    end
  end

  describe "entity command dispatch" do
    test "with EntityProvider: emits :entity_command" do
      adapters = %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: nil, entity_provider: FakeEntityProvider}
      req = %Proto.SwitchCommandRequest{key: 1, state: true}
      {_s, [{:entity_command, ^req}]} = Dispatch.step(state(adapters: adapters), req)
    end

    test "without EntityProvider: logs only" do
      {_s, [{:log, :debug, _}]} =
        Dispatch.step(state(), %Proto.SwitchCommandRequest{key: 1, state: true})
    end
  end

  describe "handle_event/2" do
    test "serial data routed to correct instance" do
      s = state() |> ConnectionState.put_port(4, :my_handle)
      {_s, [{:send, %Proto.SerialProxyDataReceived{instance: 4, data: "bytes"}}]} =
        Dispatch.handle_event(s, {:espex_serial_data, :my_handle, "bytes"})
    end

    test "serial data for unknown handle: silently dropped" do
      {_s, []} = Dispatch.handle_event(state(), {:espex_serial_data, :nope, "bytes"})
    end

    test "zwave frame dropped when not subscribed" do
      {_s, []} = Dispatch.handle_event(state(), {:espex_zwave_frame, "xx"})
    end

    test "zwave frame sent when subscribed" do
      s = state() |> ConnectionState.put_zwave_subscribed(true)
      {_, [{:send, %Proto.ZWaveProxyFrame{data: "xx"}}]} = Dispatch.handle_event(s, {:espex_zwave_frame, "xx"})
    end

    test "zwave home_id_changed always sent" do
      {_, [{:send, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE, data: <<1, 2, 3, 4>>}}]} =
        Dispatch.handle_event(state(), {:espex_zwave_home_id_changed, <<1, 2, 3, 4>>})
    end

    test "ir receive dropped when not subscribed" do
      {_s, []} = Dispatch.handle_event(state(), {:espex_ir_receive, 7, [100]})
    end

    test "ir receive sent when subscribed" do
      s = state() |> ConnectionState.put_infrared_subscribed(true)
      {_, [{:send, %Proto.InfraredRFReceiveEvent{key: 7, timings: [100]}}]} =
        Dispatch.handle_event(s, {:espex_ir_receive, 7, [100]})
    end
  end

  describe "modem_pins_response/2" do
    test "ok result maps rts/dtr through" do
      r = Dispatch.modem_pins_response(3, {:ok, %{rts: true, dtr: false}})
      assert %Proto.SerialProxyGetModemPinsResponse{instance: 3, rts: true, dtr: false} = r
    end

    test "error result yields false/false" do
      r = Dispatch.modem_pins_response(3, {:error, :nope})
      assert %Proto.SerialProxyGetModemPinsResponse{instance: 3, rts: false, dtr: false} = r
    end
  end
end
