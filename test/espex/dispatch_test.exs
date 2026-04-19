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
      {_state, actions} = Dispatch.handle_request(state(), %Proto.HelloRequest{client_info: "test-client"})
      assert [{:log, :info, _}, {:send, response}] = actions
      assert response.api_version_major == DeviceConfig.api_version_major()
      assert response.api_version_minor == DeviceConfig.api_version_minor()
      assert response.name == "test"
      assert response.server_info =~ "test_proj"
    end
  end

  describe "AuthenticationRequest / PingRequest" do
    test "auth: invalid_password is false" do
      {_s, [{:send, %Proto.AuthenticationResponse{invalid_password: false}}]} =
        Dispatch.handle_request(state(), %Proto.AuthenticationRequest{})
    end

    test "ping: empty response" do
      assert {_s, [{:send, %Proto.PingResponse{}}]} = Dispatch.handle_request(state(), %Proto.PingRequest{})
    end
  end

  describe "DeviceInfoRequest" do
    test "response includes serial proxies from frozen state" do
      info = SerialProxy.Info.new(instance: 0, name: "zigbee", port_type: :ttl)
      {_s, [{:send, resp}]} = Dispatch.handle_request(state(serial_proxies: [info]), %Proto.DeviceInfoRequest{})
      assert resp.name == "test"
      assert [%Proto.SerialProxyInfo{name: "zigbee", port_type: :SERIAL_PROXY_PORT_TYPE_TTL}] = resp.serial_proxies
    end

    test "response uses zwave fields from config" do
      cfg = %DeviceConfig{zwave_feature_flags: 1, zwave_home_id: 0x1234}
      {_s, [{:send, resp}]} = Dispatch.handle_request(state(device_config: cfg), %Proto.DeviceInfoRequest{})
      assert resp.zwave_proxy_feature_flags == 1
      assert resp.zwave_home_id == 0x1234
    end

    test "response includes sub-devices from config" do
      cfg = %DeviceConfig{
        devices: [
          Espex.DeviceConfig.Device.new(id: 1, name: "Switch Pod"),
          Espex.DeviceConfig.Device.new(id: 2, name: "Button Pod", area_id: 5)
        ]
      }

      {_s, [{:send, resp}]} = Dispatch.handle_request(state(device_config: cfg), %Proto.DeviceInfoRequest{})

      assert [
               %Proto.DeviceInfo{device_id: 1, name: "Switch Pod", area_id: 0},
               %Proto.DeviceInfo{device_id: 2, name: "Button Pod", area_id: 5}
             ] = resp.devices
    end
  end

  describe "ListEntitiesRequest" do
    test "returns only Done when no adapters configured" do
      {_s, [{:send, %Proto.ListEntitiesDoneResponse{}}]} =
        Dispatch.handle_request(state(), %Proto.ListEntitiesRequest{})
    end

    test "emits frozen IR entities then Done" do
      ir = InfraredProxy.Entity.new(key: 42, object_id: "ir", name: "IR", capabilities: [:transmit])
      {_s, actions} = Dispatch.handle_request(state(infrared_entities: [ir]), %Proto.ListEntitiesRequest{})

      assert [
               {:send, %Proto.ListEntitiesInfraredResponse{key: 42, name: "IR"}},
               {:send, %Proto.ListEntitiesDoneResponse{}}
             ] = actions
    end

    test "emits frozen custom entities" do
      custom = %Proto.ListEntitiesBinarySensorResponse{key: 7, object_id: "x", name: "X"}
      {_s, actions} = Dispatch.handle_request(state(entities: [custom]), %Proto.ListEntitiesRequest{})
      assert [{:send, ^custom}, {:send, %Proto.ListEntitiesDoneResponse{}}] = actions
    end

    test "does not call adapter list_entities at dispatch time — state is the source of truth" do
      adapters = %{
        serial_proxy: nil,
        zwave_proxy: nil,
        infrared_proxy: FakeInfraredProxy,
        entity_provider: FakeEntityProvider
      }

      {_s, actions} = Dispatch.handle_request(state(adapters: adapters), %Proto.ListEntitiesRequest{})
      assert actions == [{:send, %Proto.ListEntitiesDoneResponse{}}]
    end
  end

  describe "SubscribeStatesRequest" do
    test "no adapter: no actions" do
      {_s, actions} = Dispatch.handle_request(state(), %Proto.SubscribeStatesRequest{})
      assert actions == []
    end

    test "with EntityProvider: emits initial states" do
      adapters = %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: nil, entity_provider: FakeEntityProvider}
      {_s, actions} = Dispatch.handle_request(state(adapters: adapters), %Proto.SubscribeStatesRequest{})

      assert [{:send, %Proto.BinarySensorStateResponse{key: 1, state: true}}] = actions
    end

    test "with InfraredProxy: emits :infrared_subscribe action once and flips the flag" do
      adapters = %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: FakeInfraredProxy, entity_provider: nil}
      {state_after, actions} = Dispatch.handle_request(state(adapters: adapters), %Proto.SubscribeStatesRequest{})
      assert actions == [:infrared_subscribe]
      assert state_after.infrared_subscribed

      {_, actions} = Dispatch.handle_request(state_after, %Proto.SubscribeStatesRequest{})
      assert actions == []
    end
  end

  describe "DisconnectRequest" do
    test "sends DisconnectResponse and closes" do
      {_s, actions} = Dispatch.handle_request(state(), %Proto.DisconnectRequest{})
      assert [{:log, _, _}, {:send, %Proto.DisconnectResponse{}}, {:close, :disconnect_requested}] = actions
    end
  end

  describe "GetTimeRequest" do
    test "uses injected clock_fun and masks to 32 bits" do
      {_s, [{:send, %Proto.GetTimeResponse{epoch_seconds: 1_700_000_000}}]} =
        Dispatch.handle_request(state(), %Proto.GetTimeRequest{})
    end

    test "masks values exceeding 32 bits" do
      huge = 0x1_0000_0042

      {_s, [{:send, %Proto.GetTimeResponse{epoch_seconds: seconds}}]} =
        Dispatch.handle_request(state(clock_fun: fn -> huge end), %Proto.GetTimeRequest{})

      assert seconds == 0x42
    end
  end

  describe "SerialProxyConfigureRequest" do
    test "unknown instance: logs warning, no open" do
      {_s, [{:log, :warning, msg}]} =
        Dispatch.handle_request(state(), %Proto.SerialProxyConfigureRequest{instance: 99})

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

      {_s, [{:serial_open, 0, opts}]} = Dispatch.handle_request(state(serial_proxies: [info]), req)
      assert opts[:speed] == 115_200
      assert opts[:parity] == :even
      assert opts[:flow_control] == :hardware
    end

    test "known instance already open: emits :serial_close then :serial_open" do
      info = SerialProxy.Info.new(instance: 0, name: "n")
      s = state(serial_proxies: [info]) |> ConnectionState.put_port(0, :existing_handle)
      {_s, actions} = Dispatch.handle_request(s, %Proto.SerialProxyConfigureRequest{instance: 0})
      assert [{:serial_close, 0}, {:serial_open, 0, _opts}] = actions
    end
  end

  describe "SerialProxyWriteRequest" do
    test "opened instance: emits :serial_write" do
      s = state() |> ConnectionState.put_port(3, :h)

      {_s, [{:serial_write, 3, "hi"}]} =
        Dispatch.handle_request(s, %Proto.SerialProxyWriteRequest{instance: 3, data: "hi"})
    end

    test "unopened instance: logs warning" do
      {_s, [{:log, :warning, _}]} =
        Dispatch.handle_request(state(), %Proto.SerialProxyWriteRequest{instance: 3, data: "hi"})
    end
  end

  describe "ZWaveProxyRequest" do
    test "subscribe with adapter: emits :zwave_subscribe" do
      adapters = %{serial_proxy: nil, zwave_proxy: Espex.Test.FakeZWaveProxy, infrared_proxy: nil, entity_provider: nil}

      {_s, [:zwave_subscribe]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.ZWaveProxyRequest{
          type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE
        })
    end

    test "subscribe without adapter: logs only" do
      {_s, [{:log, :info, _}]} =
        Dispatch.handle_request(state(), %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE})
    end

    test "unsubscribe when subscribed: flips flag and emits action" do
      s = state() |> ConnectionState.put_zwave_subscribed(true)

      {new_s, [:zwave_unsubscribe]} =
        Dispatch.handle_request(s, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE})

      refute new_s.zwave_subscribed
    end

    test "unsubscribe when not subscribed: no actions" do
      {_s, []} = Dispatch.handle_request(state(), %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE})
    end
  end

  describe "ZWaveProxyFrame" do
    test "with adapter: emits :zwave_send_frame" do
      adapters = %{serial_proxy: nil, zwave_proxy: Espex.Test.FakeZWaveProxy, infrared_proxy: nil, entity_provider: nil}

      {_s, [{:zwave_send_frame, "abc"}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.ZWaveProxyFrame{data: "abc"})
    end

    test "without adapter: logs warning" do
      {_s, [{:log, :warning, _}]} = Dispatch.handle_request(state(), %Proto.ZWaveProxyFrame{data: "abc"})
    end
  end

  describe "InfraredRFTransmitRawTimingsRequest" do
    test "with adapter, first time: subscribes and transmits with defaults" do
      adapters = %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: FakeInfraredProxy, entity_provider: nil}
      req = %Proto.InfraredRFTransmitRawTimingsRequest{key: 99, timings: [100, 200]}
      {new_s, actions} = Dispatch.handle_request(state(adapters: adapters), req)

      assert [:infrared_subscribe, {:infrared_transmit, 99, [100, 200], opts}] = actions
      assert opts[:carrier_frequency] == 38_000
      assert opts[:repeat_count] == 1
      assert new_s.infrared_subscribed
    end

    test "with adapter, already subscribed: just transmits" do
      adapters = %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: FakeInfraredProxy, entity_provider: nil}
      s = state(adapters: adapters) |> ConnectionState.put_infrared_subscribed(true)

      req = %Proto.InfraredRFTransmitRawTimingsRequest{
        key: 99,
        timings: [1],
        carrier_frequency: 40_000,
        repeat_count: 3
      }

      {_s, [{:infrared_transmit, 99, [1], opts}]} = Dispatch.handle_request(s, req)
      assert opts[:carrier_frequency] == 40_000
      assert opts[:repeat_count] == 3
    end

    test "without adapter: logs warning" do
      {_s, [{:log, :warning, _}]} =
        Dispatch.handle_request(state(), %Proto.InfraredRFTransmitRawTimingsRequest{key: 1, timings: []})
    end
  end

  describe "entity command dispatch" do
    test "with EntityProvider: emits :entity_command" do
      adapters = %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: nil, entity_provider: FakeEntityProvider}
      req = %Proto.SwitchCommandRequest{key: 1, state: true}
      {_s, [{:entity_command, ^req}]} = Dispatch.handle_request(state(adapters: adapters), req)
    end

    test "without EntityProvider: logs only" do
      {_s, [{:log, :debug, _}]} =
        Dispatch.handle_request(state(), %Proto.SwitchCommandRequest{key: 1, state: true})
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
