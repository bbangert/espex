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

  # A connection that owns `instance` (API 1.17): the subscribe intent is
  # recorded only after a successful Server claim, so setting it here is
  # the pure-state stand-in for "this connection SUBSCRIBEd".
  defp owned_state(serial_proxies, instance) do
    state(serial_proxies: serial_proxies) |> ConnectionState.put_serial_subscription(instance)
  end

  defp ble_scanner_adapters(scanner) do
    %{
      serial_proxy: nil,
      zwave_proxy: nil,
      infrared_proxy: nil,
      bluetooth_scanner: scanner,
      bluetooth_proxy: nil,
      entity_provider: nil
    }
  end

  defp ble_proxy_adapters(proxy) do
    %{
      serial_proxy: nil,
      zwave_proxy: nil,
      infrared_proxy: nil,
      bluetooth_scanner: nil,
      bluetooth_proxy: proxy,
      entity_provider: nil
    }
  end

  describe "HelloRequest" do
    test "sends HelloResponse with API version and server info" do
      {_state, actions} = Dispatch.handle_request(state(), %Proto.HelloRequest{client_info: "test-client"})
      assert [{:log, :info, _}, {:send, response}, :client_connected] = actions
      assert response.api_version_major == DeviceConfig.api_version_major()
      assert response.api_version_minor == DeviceConfig.api_version_minor()
      assert response.name == "test"
      assert response.server_info =~ "test_proj"
    end

    test "records client_info/api_version and emits :client_connected" do
      req = %Proto.HelloRequest{client_info: "HA 2026.1.0", api_version_major: 1, api_version_minor: 9}
      {new_state, actions} = Dispatch.handle_request(state(), req)

      assert new_state.client_info == "HA 2026.1.0"
      assert new_state.api_version == {1, 9}
      assert [{:log, :info, _}, {:send, %Proto.HelloResponse{}}, :client_connected] = actions
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

  describe "DisconnectResponse" do
    test "while disconnecting: closes the connection" do
      s = state() |> ConnectionState.put_disconnecting()
      {_s, actions} = Dispatch.handle_request(s, %Proto.DisconnectResponse{})
      assert actions == [{:close, :server_disconnect}]
    end

    test "unsolicited: only a debug log, no close" do
      {_s, actions} = Dispatch.handle_request(state(), %Proto.DisconnectResponse{})
      assert [{:log, :debug, _}] = actions
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
    test "unknown instance: logs warning, acks INVALID_ARGUMENT, no open" do
      {_s, [{:log, :warning, msg}, {:send, ack}]} =
        Dispatch.handle_request(state(), %Proto.SerialProxyConfigureRequest{instance: 99})

      assert msg =~ "unknown instance 99"

      assert %Proto.SerialProxyRequestResponse{
               instance: 99,
               type: :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE,
               status: :SERIAL_PROXY_STATUS_INVALID_ARGUMENT
             } = ack
    end

    test "owned instance, not yet open: emits :serial_open with translated opts" do
      info = SerialProxy.Info.new(instance: 0, name: "n", port_type: :ttl)

      req = %Proto.SerialProxyConfigureRequest{
        instance: 0,
        baudrate: 115_200,
        data_size: 8,
        stop_bits: 1,
        parity: :SERIAL_PROXY_PARITY_EVEN,
        flow_control: true
      }

      {_s, [{:serial_open, 0, opts}]} = Dispatch.handle_request(owned_state([info], 0), req)

      assert opts[:speed] == 115_200
      assert opts[:parity] == :even
      assert opts[:flow_control] == :hardware
    end

    test "owned instance already open: emits :serial_close then :serial_open" do
      info = SerialProxy.Info.new(instance: 0, name: "n")
      s = owned_state([info], 0) |> ConnectionState.put_port(0, :existing_handle)
      {_s, actions} = Dispatch.handle_request(s, %Proto.SerialProxyConfigureRequest{instance: 0})

      assert [{:serial_close, 0}, {:serial_open, 0, _opts}] = actions
    end

    test "known instance without SUBSCRIBE: acks PORT_IN_USE, no open" do
      info = SerialProxy.Info.new(instance: 0, name: "n")

      {_s, [{:log, :info, msg}, {:send, ack}]} =
        Dispatch.handle_request(state(serial_proxies: [info]), %Proto.SerialProxyConfigureRequest{instance: 0})

      assert msg =~ "not the owner"

      assert %Proto.SerialProxyRequestResponse{
               instance: 0,
               type: :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE,
               status: :SERIAL_PROXY_STATUS_PORT_IN_USE
             } = ack
    end
  end

  describe "SerialProxyWriteRequest" do
    test "owned, opened instance: emits :serial_write" do
      s = owned_state([], 3) |> ConnectionState.put_port(3, :h)

      {_s, [{:serial_write, 3, "hi"}]} =
        Dispatch.handle_request(s, %Proto.SerialProxyWriteRequest{instance: 3, data: "hi"})
    end

    test "owned but unopened instance: lazily opens with default opts then writes" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      {_s, actions} =
        Dispatch.handle_request(owned_state([info], 3), %Proto.SerialProxyWriteRequest{instance: 3, data: "hi"})

      assert [{:log, :debug, _}, {:serial_open, 3, :default_opts}, {:serial_write, 3, "hi"}] = actions
    end

    test "known instance without SUBSCRIBE: dropped with a debug log, no ack" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      {_s, [{:log, :debug, msg}]} =
        Dispatch.handle_request(state(serial_proxies: [info]), %Proto.SerialProxyWriteRequest{instance: 3, data: "hi"})

      assert msg =~ "not the owner"

      # Open on this connection (a non-owner's GET_MODEM_PINS can open it)
      # but still not subscribed: same outcome.
      s = state() |> ConnectionState.put_port(3, :h)
      {_s, [{:log, :debug, _}]} = Dispatch.handle_request(s, %Proto.SerialProxyWriteRequest{instance: 3, data: "hi"})
    end

    test "unknown instance: logs warning" do
      {_s, [{:log, :warning, msg}]} =
        Dispatch.handle_request(state(), %Proto.SerialProxyWriteRequest{instance: 3, data: "hi"})

      assert msg =~ "unknown instance"
    end
  end

  describe "SerialProxySetModemPinsRequest" do
    test "unpacks line_states bitmask into rts/dtr booleans" do
      s = owned_state([], 3) |> ConnectionState.put_port(3, :h)

      {_, [{:serial_modem_pins_set, 3, true, false}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModemPinsRequest{instance: 3, line_states: 0x01})

      {_, [{:serial_modem_pins_set, 3, false, true}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModemPinsRequest{instance: 3, line_states: 0x02})

      {_, [{:serial_modem_pins_set, 3, true, true}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModemPinsRequest{instance: 3, line_states: 0x03})

      {_, [{:serial_modem_pins_set, 3, false, false}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModemPinsRequest{instance: 3, line_states: 0})
    end

    test "owned but unopened instance: lazily opens with default opts then sets pins" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      {_s, actions} =
        Dispatch.handle_request(owned_state([info], 3), %Proto.SerialProxySetModemPinsRequest{
          instance: 3,
          line_states: 0x01
        })

      assert [{:log, :debug, _}, {:serial_open, 3, :default_opts}, {:serial_modem_pins_set, 3, true, false}] =
               actions
    end

    test "known instance without SUBSCRIBE: acks PORT_IN_USE" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      {_s, [{:log, :info, _}, {:send, ack}]} =
        Dispatch.handle_request(state(serial_proxies: [info]), %Proto.SerialProxySetModemPinsRequest{
          instance: 3,
          line_states: 0x01
        })

      assert %Proto.SerialProxyRequestResponse{
               instance: 3,
               type: :SERIAL_PROXY_REQUEST_TYPE_SET_MODEM_PINS,
               status: :SERIAL_PROXY_STATUS_PORT_IN_USE
             } = ack
    end

    test "unknown instance: logs warning and acks INVALID_ARGUMENT" do
      {_, [{:log, :warning, msg}, {:send, ack}]} =
        Dispatch.handle_request(state(), %Proto.SerialProxySetModemPinsRequest{instance: 3, line_states: 0})

      assert msg =~ "unknown instance"

      assert %Proto.SerialProxyRequestResponse{
               instance: 3,
               type: :SERIAL_PROXY_REQUEST_TYPE_SET_MODEM_PINS,
               status: :SERIAL_PROXY_STATUS_INVALID_ARGUMENT
             } = ack
    end
  end

  describe "SerialProxyGetModemPinsRequest" do
    test "opened instance: emits :serial_modem_pins_get" do
      s = state() |> ConnectionState.put_port(3, :h)

      {_, [{:serial_modem_pins_get, 3}]} =
        Dispatch.handle_request(s, %Proto.SerialProxyGetModemPinsRequest{instance: 3})
    end

    test "advertised but unopened instance, no SUBSCRIBE: still lazily opens and reads (ungated)" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      {_s, actions} =
        Dispatch.handle_request(state(serial_proxies: [info]), %Proto.SerialProxyGetModemPinsRequest{instance: 3})

      assert [{:log, :debug, _}, {:serial_open, 3, :default_opts}, {:serial_modem_pins_get, 3}] = actions
    end

    test "unknown instance: logs warning and still sends zeroed response" do
      {_, [{:log, :warning, msg}, {:send, response}]} =
        Dispatch.handle_request(state(), %Proto.SerialProxyGetModemPinsRequest{instance: 3})

      assert msg =~ "unknown instance"

      assert %Proto.SerialProxyGetModemPinsResponse{
               instance: 3,
               line_states: 0,
               status: :SERIAL_PROXY_STATUS_INVALID_ARGUMENT
             } = response
    end
  end

  describe "SerialProxyRequest with an acknowledgement-only type" do
    test "CONFIGURE / SET_MODEM_PINS / SET_MODE are refused with INVALID_ARGUMENT" do
      for wire <- [
            :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE,
            :SERIAL_PROXY_REQUEST_TYPE_SET_MODEM_PINS,
            :SERIAL_PROXY_REQUEST_TYPE_SET_MODE
          ] do
        {_s, [{:log, :warning, _}, {:send, response}]} =
          Dispatch.handle_request(state(), %Proto.SerialProxyRequest{instance: 0, type: wire})

        assert %Proto.SerialProxyRequestResponse{
                 instance: 0,
                 type: ^wire,
                 status: :SERIAL_PROXY_STATUS_INVALID_ARGUMENT
               } = response
      end
    end
  end

  describe "DeviceCapabilitiesRequest" do
    test "mirrors the feature flags and serial proxies DeviceInfoResponse carries" do
      config = %DeviceConfig{
        name: "caps",
        bluetooth_feature_flags: 0x23,
        zwave_feature_flags: 1,
        zwave_home_id: 0xDEADBEEF
      }

      info = SerialProxy.Info.new(instance: 0, name: "zigbee", port_type: :rs485, configured_line_states: [:rts])
      s = state(device_config: config, serial_proxies: [info])

      {_s, [{:send, %Proto.DeviceInfoResponse{} = device_info}]} =
        Dispatch.handle_request(s, %Proto.DeviceInfoRequest{})

      {_s, [{:send, %Proto.DeviceCapabilitiesResponse{} = caps}]} =
        Dispatch.handle_request(s, %Proto.DeviceCapabilitiesRequest{})

      assert caps.bluetooth_proxy.feature_flags == device_info.bluetooth_proxy_feature_flags
      assert caps.zwave_proxy.feature_flags == device_info.zwave_proxy_feature_flags
      assert caps.zwave_proxy.home_id == device_info.zwave_home_id
      assert caps.serial_proxies == device_info.serial_proxies
      assert caps.voice_assistant.feature_flags == 0
      assert caps.bluetooth_proxy.mac_address == ""
    end
  end

  describe "SerialProxyRequest" do
    test "SUBSCRIBE / UNSUBSCRIBE on a known instance: emit only the ownership action, state untouched" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      for s <- [state(serial_proxies: [info]), state(serial_proxies: [info]) |> ConnectionState.put_port(3, :h)] do
        {^s, [{:serial_subscribe, 3}]} =
          Dispatch.handle_request(s, %Proto.SerialProxyRequest{instance: 3, type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE})

        # Intent is recorded by the Connection after the Server claim, never here.
        refute ConnectionState.serial_subscribed?(s, 3)

        {^s, [{:serial_unsubscribe, 3}]} =
          Dispatch.handle_request(s, %Proto.SerialProxyRequest{
            instance: 3,
            type: :SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE
          })
      end
    end

    test "flush on an owned, open instance: emits :serial_request" do
      s = owned_state([SerialProxy.Info.new(instance: 3, name: "n")], 3) |> ConnectionState.put_port(3, :h)

      {_, [{:serial_request, 3, :flush}]} =
        Dispatch.handle_request(s, %Proto.SerialProxyRequest{instance: 3, type: :SERIAL_PROXY_REQUEST_TYPE_FLUSH})
    end

    test "flush on an owned but unopened instance: lazily opens then flushes" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      {_, actions} =
        Dispatch.handle_request(owned_state([info], 3), %Proto.SerialProxyRequest{
          instance: 3,
          type: :SERIAL_PROXY_REQUEST_TYPE_FLUSH
        })

      assert [{:log, :debug, _}, {:serial_open, 3, :default_opts}, {:serial_request, 3, :flush}] = actions
    end

    test "flush without SUBSCRIBE: acks PORT_IN_USE" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      {_, [{:log, :info, _}, {:send, ack}]} =
        Dispatch.handle_request(state(serial_proxies: [info]), %Proto.SerialProxyRequest{
          instance: 3,
          type: :SERIAL_PROXY_REQUEST_TYPE_FLUSH
        })

      assert %Proto.SerialProxyRequestResponse{
               instance: 3,
               type: :SERIAL_PROXY_REQUEST_TYPE_FLUSH,
               status: :SERIAL_PROXY_STATUS_PORT_IN_USE,
               error_message: "port owned by another client or not subscribed"
             } = ack
    end

    test "flush / subscribe / unsubscribe for unknown instance: INVALID_ARGUMENT" do
      for wire <- [
            :SERIAL_PROXY_REQUEST_TYPE_FLUSH,
            :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE,
            :SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE
          ] do
        {_, [{:log, :warning, msg}, {:send, response}]} =
          Dispatch.handle_request(state(), %Proto.SerialProxyRequest{instance: 3, type: wire})

        assert msg =~ "unknown instance"

        assert %Proto.SerialProxyRequestResponse{
                 instance: 3,
                 type: ^wire,
                 status: :SERIAL_PROXY_STATUS_INVALID_ARGUMENT,
                 error_message: "unknown instance"
               } = response
      end
    end

    test "out-of-range request type: sends ERROR response echoing the raw value" do
      s = state() |> ConnectionState.put_port(3, :h)
      # The decoder yields the integer for a value outside the enum.
      {_, [{:log, :warning, _}, {:send, response}]} =
        Dispatch.handle_request(s, %Proto.SerialProxyRequest{instance: 3, type: 99})

      assert %Proto.SerialProxyRequestResponse{type: 99, status: :SERIAL_PROXY_STATUS_ERROR} = response
    end
  end

  describe "SerialProxySetModeRequest" do
    test "unknown instance: INVALID_ARGUMENT with the SET_MODE type" do
      {_, [{:log, :warning, msg}, {:send, ack}]} =
        Dispatch.handle_request(state(), %Proto.SerialProxySetModeRequest{instance: 9, mode: :SERIAL_PROXY_MODE_RAW})

      assert msg =~ "unknown instance"

      assert %Proto.SerialProxyRequestResponse{
               instance: 9,
               type: :SERIAL_PROXY_REQUEST_TYPE_SET_MODE,
               status: :SERIAL_PROXY_STATUS_INVALID_ARGUMENT
             } = ack
    end

    test "known instance without SUBSCRIBE: PORT_IN_USE" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      {_, [{:log, :info, _}, {:send, ack}]} =
        Dispatch.handle_request(state(serial_proxies: [info]), %Proto.SerialProxySetModeRequest{
          instance: 3,
          mode: :SERIAL_PROXY_MODE_PROTOCOL
        })

      assert %Proto.SerialProxyRequestResponse{
               instance: 3,
               type: :SERIAL_PROXY_REQUEST_TYPE_SET_MODE,
               status: :SERIAL_PROXY_STATUS_PORT_IN_USE
             } = ack
    end

    test "non-owner with a mode outside the enum: PORT_IN_USE wins (ownership is checked first)" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      {_, [{:log, :info, _}, {:send, ack}]} =
        Dispatch.handle_request(state(serial_proxies: [info]), %Proto.SerialProxySetModeRequest{instance: 3, mode: 7})

      assert ack.status == :SERIAL_PROXY_STATUS_PORT_IN_USE
    end

    test "mode outside the enum (decoded as an integer): INVALID_ARGUMENT" do
      s = owned_state([SerialProxy.Info.new(instance: 3, name: "n")], 3) |> ConnectionState.put_port(3, :h)

      {_, [{:log, :warning, msg}, {:send, ack}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModeRequest{instance: 3, mode: 7})

      assert msg =~ "unknown mode"

      assert %Proto.SerialProxyRequestResponse{
               instance: 3,
               type: :SERIAL_PROXY_REQUEST_TYPE_SET_MODE,
               status: :SERIAL_PROXY_STATUS_INVALID_ARGUMENT,
               error_message: "unknown mode"
             } = ack
    end

    test "RAW / PROTOCOL on an owned, open instance: emits :serial_set_mode" do
      s = owned_state([SerialProxy.Info.new(instance: 3, name: "n")], 3) |> ConnectionState.put_port(3, :h)

      {_, [{:serial_set_mode, 3, :raw}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModeRequest{instance: 3, mode: :SERIAL_PROXY_MODE_RAW})

      {_, [{:serial_set_mode, 3, :protocol}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModeRequest{instance: 3, mode: :SERIAL_PROXY_MODE_PROTOCOL})
    end

    test "owned but unopened instance: lazily opens first (the callback needs a handle)" do
      info = SerialProxy.Info.new(instance: 3, name: "n")

      {_, actions} =
        Dispatch.handle_request(owned_state([info], 3), %Proto.SerialProxySetModeRequest{
          instance: 3,
          mode: :SERIAL_PROXY_MODE_PROTOCOL
        })

      assert [{:log, :debug, _}, {:serial_open, 3, :default_opts}, {:serial_set_mode, 3, :protocol}] = actions
    end
  end

  describe "serial_request_response/3" do
    test "ok status maps to wire enum with empty error_message" do
      r = Dispatch.serial_request_response(2, :flush, {:ok, :ok})

      assert %Proto.SerialProxyRequestResponse{
               instance: 2,
               type: :SERIAL_PROXY_REQUEST_TYPE_FLUSH,
               status: :SERIAL_PROXY_STATUS_OK,
               error_message: ""
             } = r
    end

    test "assumed_success and not_supported map through" do
      r = Dispatch.serial_request_response(2, :subscribe, {:ok, :assumed_success})
      assert r.status == :SERIAL_PROXY_STATUS_ASSUMED_SUCCESS

      r = Dispatch.serial_request_response(2, :subscribe, {:ok, :not_supported})
      assert r.status == :SERIAL_PROXY_STATUS_NOT_SUPPORTED
    end

    test "error tuple yields ERROR status and inspects reason" do
      r = Dispatch.serial_request_response(2, :flush, {:error, :port_busy})
      assert r.status == :SERIAL_PROXY_STATUS_ERROR
      assert r.error_message == ":port_busy"
    end

    test ":set_mode acknowledges with the SET_MODE wire type" do
      r = Dispatch.serial_request_response(2, :set_mode, {:ok, :not_supported})
      assert r.type == :SERIAL_PROXY_REQUEST_TYPE_SET_MODE
      assert r.status == :SERIAL_PROXY_STATUS_NOT_SUPPORTED
    end
  end

  describe "serial_port_in_use_response/2" do
    test "builds the PORT_IN_USE ack for the given type" do
      r = Dispatch.serial_port_in_use_response(1, :subscribe)

      assert %Proto.SerialProxyRequestResponse{
               instance: 1,
               type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE,
               status: :SERIAL_PROXY_STATUS_PORT_IN_USE,
               error_message: "port owned by another client or not subscribed"
             } = r
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

    test "subscribe without adapter: logs and acks NOT_SUPPORTED" do
      {_s, [{:log, :info, _}, {:send, ack}]} =
        Dispatch.handle_request(state(), %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE})

      assert %Proto.ZWaveProxyRequestResponse{
               type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE,
               status: :ZWAVE_PROXY_STATUS_NOT_SUPPORTED
             } = ack
    end

    test "unsubscribe when subscribed: flips flag, emits action, then acks OK" do
      s = state() |> ConnectionState.put_zwave_subscribed(true)

      {new_s, [:zwave_unsubscribe, {:send, ack}]} =
        Dispatch.handle_request(s, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE})

      refute new_s.zwave_subscribed
      assert ack == Dispatch.zwave_request_response(:unsubscribe, :ok)
    end

    test "unsubscribe when not subscribed: acks OK only" do
      {_s, [{:send, ack}]} =
        Dispatch.handle_request(state(), %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE})

      assert %Proto.ZWaveProxyRequestResponse{
               type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE,
               status: :ZWAVE_PROXY_STATUS_OK
             } = ack
    end

    test "zwave_request_response/2 maps every status" do
      assert %Proto.ZWaveProxyRequestResponse{status: :ZWAVE_PROXY_STATUS_OK} =
               Dispatch.zwave_request_response(:subscribe, :ok)

      assert %Proto.ZWaveProxyRequestResponse{status: :ZWAVE_PROXY_STATUS_IN_USE} =
               Dispatch.zwave_request_response(:subscribe, :in_use)

      assert %Proto.ZWaveProxyRequestResponse{status: :ZWAVE_PROXY_STATUS_NOT_SUPPORTED} =
               Dispatch.zwave_request_response(:subscribe, :not_supported)
    end
  end

  describe "ZWaveProxyFrame" do
    test "subscribed connection: emits :zwave_send_frame" do
      adapters = %{serial_proxy: nil, zwave_proxy: Espex.Test.FakeZWaveProxy, infrared_proxy: nil, entity_provider: nil}
      s = state(adapters: adapters) |> ConnectionState.put_zwave_subscribed(true)

      {_s, [{:zwave_send_frame, "abc"}]} =
        Dispatch.handle_request(s, %Proto.ZWaveProxyFrame{data: "abc"})
    end

    test "adapter present but connection not subscribed: dropped with warning" do
      adapters = %{serial_proxy: nil, zwave_proxy: Espex.Test.FakeZWaveProxy, infrared_proxy: nil, entity_provider: nil}

      {_s, [{:log, :warning, msg}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.ZWaveProxyFrame{data: "abc"})

      assert msg =~ "not subscribed"
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

  describe "handle_event/2 :espex_disconnect (server-initiated disconnect)" do
    defp hello_done(overrides \\ []) do
      state(overrides) |> ConnectionState.put_client_hello("HA", {1, 10})
    end

    test "after hello: sends DisconnectRequest, arms the grace timer, marks disconnecting" do
      {new_state, actions} =
        Dispatch.handle_event(hello_done(disconnect_grace_ms: 123), {:espex_disconnect, :unspecified})

      assert [
               {:log, :info, _},
               {:send, %Proto.DisconnectRequest{reason: :DISCONNECT_REASON_UNSPECIFIED}},
               {:arm_disconnect_timeout, 123}
             ] = actions

      assert new_state.disconnecting
    end

    test "the reason is carried on the wire" do
      {_s, actions} = Dispatch.handle_event(hello_done(), {:espex_disconnect, :provisioning_closed})
      assert [_, {:send, %Proto.DisconnectRequest{reason: :DISCONNECT_REASON_PROVISIONING_CLOSED}}, _] = actions
    end

    test "a second event while disconnecting does nothing (fan-out is idempotent)" do
      {s, _} = Dispatch.handle_event(hello_done(), {:espex_disconnect, :unspecified})
      assert {^s, []} = Dispatch.handle_event(s, {:espex_disconnect, :unspecified})
    end

    test "before hello: closes without sending a frame" do
      {s, actions} = Dispatch.handle_event(state(), {:espex_disconnect, :unspecified})
      assert actions == [{:close, :server_disconnect}]
      refute s.disconnecting
    end

    test "mid Noise handshake: closes without sending a frame" do
      {_s, actions} = Dispatch.handle_event(state(encryption: :awaiting_hello), {:espex_disconnect, :unspecified})
      assert actions == [{:close, :server_disconnect}]
    end

    test "a client DisconnectRequest while we are disconnecting is answered and closes" do
      s = hello_done() |> ConnectionState.put_disconnecting()
      {_s, actions} = Dispatch.handle_request(s, %Proto.DisconnectRequest{})
      assert [{:log, _, _}, {:send, %Proto.DisconnectResponse{}}, {:close, :disconnect_requested}] = actions
    end

    test "grace timeout while disconnecting: warns and closes" do
      s = hello_done() |> ConnectionState.put_disconnecting()
      {_s, actions} = Dispatch.handle_event(s, :espex_disconnect_timeout)
      assert [{:log, :warning, _}, {:close, :server_disconnect_timeout}] = actions
    end

    test "grace timeout when not disconnecting: no-op" do
      assert {_s, []} = Dispatch.handle_event(hello_done(), :espex_disconnect_timeout)
    end
  end

  describe "handle_event/2" do
    test "serial data routed to the owner's instance" do
      s = owned_state([], 4) |> ConnectionState.put_port(4, :my_handle)

      {_s, [{:send, %Proto.SerialProxyDataReceived{instance: 4, data: "bytes"}}]} =
        Dispatch.handle_event(s, {:espex_serial_data, :my_handle, "bytes"})
    end

    test "serial data on a handle this connection does not own: silently dropped" do
      # A non-owner can hold a handle via the ungated GET_MODEM_PINS lazy open.
      s = state() |> ConnectionState.put_port(4, :my_handle)
      {_s, []} = Dispatch.handle_event(s, {:espex_serial_data, :my_handle, "bytes"})
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

  describe "SubscribeBluetoothLEAdvertisementsRequest" do
    test "without adapter: logs and does not subscribe" do
      {s, [{:log, :info, _}]} =
        Dispatch.handle_request(state(), %Proto.SubscribeBluetoothLEAdvertisementsRequest{})

      refute s.bluetooth_scanner_subscribed
    end

    test "with adapter: emits :ble_scanner_subscribe and flips the flag" do
      adapters = ble_scanner_adapters(Espex.Test.FakeBluetoothScanner)

      {new_s, [:ble_scanner_subscribe]} =
        Dispatch.handle_request(
          state(adapters: adapters),
          %Proto.SubscribeBluetoothLEAdvertisementsRequest{}
        )

      assert new_s.bluetooth_scanner_subscribed
    end

    test "already subscribed: no-op (no adapter call)" do
      adapters = ble_scanner_adapters(Espex.Test.FakeBluetoothScanner)
      s = state(adapters: adapters) |> ConnectionState.put_bluetooth_scanner_subscribed(true)

      {^s, []} = Dispatch.handle_request(s, %Proto.SubscribeBluetoothLEAdvertisementsRequest{})
    end

    test "non-zero flags are logged at debug (no defined flag bits yet)" do
      adapters = ble_scanner_adapters(Espex.Test.FakeBluetoothScanner)

      {_s, actions} =
        Dispatch.handle_request(
          state(adapters: adapters),
          %Proto.SubscribeBluetoothLEAdvertisementsRequest{flags: 0x02}
        )

      assert :ble_scanner_subscribe in actions
      assert Enum.any?(actions, &match?({:log, :debug, _}, &1))
    end
  end

  describe "UnsubscribeBluetoothLEAdvertisementsRequest" do
    test "not subscribed: no action" do
      {_s, []} =
        Dispatch.handle_request(state(), %Proto.UnsubscribeBluetoothLEAdvertisementsRequest{})
    end

    test "subscribed: emits :ble_scanner_unsubscribe and clears the flag" do
      adapters = ble_scanner_adapters(Espex.Test.FakeBluetoothScanner)
      s = state(adapters: adapters) |> ConnectionState.put_bluetooth_scanner_subscribed(true)

      {new_s, [:ble_scanner_unsubscribe]} =
        Dispatch.handle_request(s, %Proto.UnsubscribeBluetoothLEAdvertisementsRequest{})

      refute new_s.bluetooth_scanner_subscribed
    end
  end

  describe "BluetoothScannerSetModeRequest" do
    test "without adapter: logs and emits no action" do
      {_s, [{:log, :info, _}]} =
        Dispatch.handle_request(state(), %Proto.BluetoothScannerSetModeRequest{
          mode: :BLUETOOTH_SCANNER_MODE_ACTIVE
        })
    end

    test "with adapter: emits {:ble_scanner_set_mode, atom} mapping wire enum" do
      adapters = ble_scanner_adapters(Espex.Test.FakeBluetoothScanner)

      {_s, [{:ble_scanner_set_mode, :passive}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothScannerSetModeRequest{
          mode: :BLUETOOTH_SCANNER_MODE_PASSIVE
        })

      {_s, [{:ble_scanner_set_mode, :active}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothScannerSetModeRequest{
          mode: :BLUETOOTH_SCANNER_MODE_ACTIVE
        })
    end

    test "unknown wire mode (forward-compat): logs warning, no adapter action" do
      adapters = ble_scanner_adapters(Espex.Test.FakeBluetoothScanner)

      {_s, [{:log, :warning, msg}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothScannerSetModeRequest{
          mode: 99
        })

      assert msg =~ "unknown wire mode"
    end
  end

  describe "BluetoothScanner events" do
    test "advertisement dropped when not subscribed" do
      {_s, []} =
        Dispatch.handle_event(state(), {:espex_ble_advertisement, 0xAABBCC, -55, 0, <<1, 2>>})
    end

    test "advertisement wrapped one-per-response when subscribed" do
      s = state() |> ConnectionState.put_bluetooth_scanner_subscribed(true)

      {_s, [{:send, response}]} =
        Dispatch.handle_event(s, {:espex_ble_advertisement, 0xAABBCC, -55, 1, "payload"})

      assert %Proto.BluetoothLERawAdvertisementsResponse{
               advertisements: [
                 %Proto.BluetoothLERawAdvertisement{
                   address: 0xAABBCC,
                   rssi: -55,
                   address_type: 1,
                   data: "payload"
                 }
               ]
             } = response
    end

    test "scanner_state event always emitted (no gating on subscribed flag)" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(state(), {:espex_ble_scanner_state, :running, :passive, :active})

      assert %Proto.BluetoothScannerStateResponse{
               state: :BLUETOOTH_SCANNER_STATE_RUNNING,
               mode: :BLUETOOTH_SCANNER_MODE_PASSIVE,
               configured_mode: :BLUETOOTH_SCANNER_MODE_ACTIVE
             } = response
    end

    test "scanner_state maps every documented state atom to its wire enum" do
      for {atom, wire} <- [
            {:idle, :BLUETOOTH_SCANNER_STATE_IDLE},
            {:starting, :BLUETOOTH_SCANNER_STATE_STARTING},
            {:running, :BLUETOOTH_SCANNER_STATE_RUNNING},
            {:failed, :BLUETOOTH_SCANNER_STATE_FAILED},
            {:stopping, :BLUETOOTH_SCANNER_STATE_STOPPING},
            {:stopped, :BLUETOOTH_SCANNER_STATE_STOPPED}
          ] do
        {_s, [{:send, %Proto.BluetoothScannerStateResponse{state: ^wire}}]} =
          Dispatch.handle_event(state(), {:espex_ble_scanner_state, atom, :passive, :passive})
      end
    end
  end

  describe "BluetoothDeviceRequest" do
    test "without adapter: logs and emits no action" do
      {_s, [{:log, :info, _}]} =
        Dispatch.handle_request(state(), %Proto.BluetoothDeviceRequest{
          request_type: :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT,
          address: 0xAABB
        })
    end

    test "CONNECT emits {:ble_connect, address, opts} with default cache mode" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      {_s, [{:ble_connect, 0xAABB, opts}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothDeviceRequest{
          request_type: :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT,
          address: 0xAABB
        })

      assert opts[:cache_mode] == :default
      assert opts[:address_type] == nil
    end

    test "CONNECT carries address_type when has_address_type is true" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      {_s, [{:ble_connect, _addr, opts}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothDeviceRequest{
          request_type: :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT,
          address: 1,
          has_address_type: true,
          address_type: 1
        })

      assert opts[:address_type] == 1
    end

    test "CONNECT_V3_WITH_CACHE / WITHOUT_CACHE pass the cache mode through" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      {_s, [{:ble_connect, _, opts_with}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothDeviceRequest{
          request_type: :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITH_CACHE,
          address: 1
        })

      assert opts_with[:cache_mode] == :with_cache

      {_s, [{:ble_connect, _, opts_without}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothDeviceRequest{
          request_type: :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITHOUT_CACHE,
          address: 1
        })

      assert opts_without[:cache_mode] == :without_cache
    end

    test "DISCONNECT / PAIR / UNPAIR / CLEAR_CACHE emit the matching action atom" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      for {wire, action} <- [
            {:BLUETOOTH_DEVICE_REQUEST_TYPE_DISCONNECT, :ble_disconnect},
            {:BLUETOOTH_DEVICE_REQUEST_TYPE_PAIR, :ble_pair},
            {:BLUETOOTH_DEVICE_REQUEST_TYPE_UNPAIR, :ble_unpair},
            {:BLUETOOTH_DEVICE_REQUEST_TYPE_CLEAR_CACHE, :ble_clear_cache}
          ] do
        {_s, [{^action, 99}]} =
          Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothDeviceRequest{
            request_type: wire,
            address: 99
          })
      end
    end

    test "unknown request_type logs warning, no action" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      {_s, [{:log, :warning, msg}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothDeviceRequest{
          request_type: 42,
          address: 1
        })

      assert msg =~ "unknown request_type"
    end
  end

  describe "BluetoothSetConnectionParamsRequest" do
    test "without adapter: logs and emits no action" do
      {_s, [{:log, :info, _}]} =
        Dispatch.handle_request(state(), %Proto.BluetoothSetConnectionParamsRequest{address: 1})
    end

    test "with adapter: emits {:ble_set_connection_params, address, %{params}}" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      {_s, [{:ble_set_connection_params, 1, params}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothSetConnectionParamsRequest{
          address: 1,
          min_interval: 6,
          max_interval: 16,
          latency: 0,
          timeout: 400
        })

      assert params == %{min_interval: 6, max_interval: 16, latency: 0, timeout: 400}
    end
  end

  describe "SubscribeBluetoothConnectionsFreeRequest" do
    test "without adapter: logs and does not subscribe" do
      {s, [{:log, :info, _}]} =
        Dispatch.handle_request(state(), %Proto.SubscribeBluetoothConnectionsFreeRequest{})

      refute s.bluetooth_connections_free_subscribed
    end

    test "with adapter: flips the flag and pushes once" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      {new_s, [:ble_push_connections_free]} =
        Dispatch.handle_request(
          state(adapters: adapters),
          %Proto.SubscribeBluetoothConnectionsFreeRequest{}
        )

      assert new_s.bluetooth_connections_free_subscribed
    end

    test "already subscribed: still emits a push (refresh on resubscribe)" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      s =
        state(adapters: adapters)
        |> ConnectionState.put_bluetooth_connections_free_subscribed(true)

      {^s, [:ble_push_connections_free]} =
        Dispatch.handle_request(s, %Proto.SubscribeBluetoothConnectionsFreeRequest{})
    end
  end

  describe "BluetoothProxy events" do
    test "{:espex_ble_connection, address, {:ok, mtu}} sends connected response when owned" do
      s = state() |> ConnectionState.add_bluetooth_owned(0xAABB)

      {_s, [{:send, response} | _]} =
        Dispatch.handle_event(s, {:espex_ble_connection, 0xAABB, {:ok, 247}})

      assert %Proto.BluetoothDeviceConnectionResponse{
               address: 0xAABB,
               connected: true,
               mtu: 247,
               error: 0
             } = response
    end

    test "{:espex_ble_connection, address, {:ok, _}} is dropped when not owned (late event)" do
      {_s, []} = Dispatch.handle_event(state(), {:espex_ble_connection, 0xAABB, {:ok, 247}})
    end

    test "{:espex_ble_connection, _, {:error, code}} always sends (no ownership gate on failure)" do
      {_s, [{:send, response} | _]} =
        Dispatch.handle_event(state(), {:espex_ble_connection, 0xAABB, {:error, -1}})

      assert %Proto.BluetoothDeviceConnectionResponse{connected: false, error: -1} = response
    end

    test "failed connect for an owned address drops bluetooth_owned + emits :ble_release_ownership" do
      s = state() |> ConnectionState.add_bluetooth_owned(0xAABB)

      {new_s, actions} = Dispatch.handle_event(s, {:espex_ble_connection, 0xAABB, {:error, -1}})

      refute ConnectionState.bluetooth_owns?(new_s, 0xAABB)
      assert {:ble_release_ownership, 0xAABB} in actions
    end

    test "successful connect re-pushes connections_free when client is subscribed" do
      s =
        state()
        |> ConnectionState.add_bluetooth_owned(0xAABB)
        |> ConnectionState.put_bluetooth_connections_free_subscribed(true)

      {_s, actions} = Dispatch.handle_event(s, {:espex_ble_connection, 0xAABB, {:ok, 247}})
      assert :ble_push_connections_free in actions
    end

    test "{:espex_ble_pair, ...} → BluetoothDevicePairingResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(state(), {:espex_ble_pair, 0xAABB, true, 0})

      assert %Proto.BluetoothDevicePairingResponse{address: 0xAABB, paired: true, error: 0} = response
    end

    test "{:espex_ble_unpair, ...} → BluetoothDeviceUnpairingResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(state(), {:espex_ble_unpair, 0xAABB, true, 0})

      assert %Proto.BluetoothDeviceUnpairingResponse{address: 0xAABB, success: true, error: 0} = response
    end

    test "{:espex_ble_clear_cache, ...} → BluetoothDeviceClearCacheResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(state(), {:espex_ble_clear_cache, 0xAABB, true, 0})

      assert %Proto.BluetoothDeviceClearCacheResponse{address: 0xAABB, success: true, error: 0} = response
    end

    test "{:espex_ble_connection_params, ...} → BluetoothSetConnectionParamsResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(state(), {:espex_ble_connection_params, 0xAABB, 0})

      assert %Proto.BluetoothSetConnectionParamsResponse{address: 0xAABB, error: 0} = response
    end
  end

  describe "BluetoothGATT requests" do
    test "without adapter: logs and emits no action" do
      {_s, [{:log, :info, _}]} =
        Dispatch.handle_request(state(), %Proto.BluetoothGATTGetServicesRequest{address: 0xAABB})
    end

    test "GetServices emits {:ble_gatt_get_services, address}" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      {_s, [{:ble_gatt_get_services, 0xAABB}]} =
        Dispatch.handle_request(
          state(adapters: adapters),
          %Proto.BluetoothGATTGetServicesRequest{address: 0xAABB}
        )
    end

    test "Read emits {:ble_gatt_read, address, handle}" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      {_s, [{:ble_gatt_read, 0xAABB, 7}]} =
        Dispatch.handle_request(
          state(adapters: adapters),
          %Proto.BluetoothGATTReadRequest{address: 0xAABB, handle: 7}
        )
    end

    test "Write carries handle, data, and response? flag" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      {_s, [{:ble_gatt_write, 0xAABB, 7, "abc", true}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothGATTWriteRequest{
          address: 0xAABB,
          handle: 7,
          data: "abc",
          response: true
        })
    end

    test "ReadDescriptor / WriteDescriptor / Notify emit the matching action tuple" do
      adapters = ble_proxy_adapters(Espex.Test.FakeBluetoothProxy)

      {_s, [{:ble_gatt_read_descriptor, 0xAABB, 7}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothGATTReadDescriptorRequest{
          address: 0xAABB,
          handle: 7
        })

      {_s, [{:ble_gatt_write_descriptor, 0xAABB, 7, "abc"}]} =
        Dispatch.handle_request(
          state(adapters: adapters),
          %Proto.BluetoothGATTWriteDescriptorRequest{address: 0xAABB, handle: 7, data: "abc"}
        )

      {_s, [{:ble_gatt_notify, 0xAABB, 7, true}]} =
        Dispatch.handle_request(state(adapters: adapters), %Proto.BluetoothGATTNotifyRequest{
          address: 0xAABB,
          handle: 7,
          enable: true
        })
    end
  end

  describe "BluetoothGATT events" do
    alias Espex.BluetoothProxy.{Characteristic, Descriptor, Service}

    # All GATT events are gated on ownership — a late event after
    # disconnect would otherwise leak to the client. Each test
    # pre-owns the address through ConnectionState.add_bluetooth_owned/2.
    defp owning_state(address \\ 0xAABB) do
      state() |> ConnectionState.add_bluetooth_owned(address)
    end

    test "{:espex_ble_gatt_service, ...} wraps one service per GetServicesResponse" do
      service =
        Service.new(
          uuid: 0x180D,
          handle: 1,
          characteristics: [
            Characteristic.new(
              uuid: 0x2A37,
              handle: 2,
              properties: 0x10,
              descriptors: [Descriptor.new(uuid: 0x2902, handle: 3)]
            )
          ]
        )

      {_s, [{:send, response}]} =
        Dispatch.handle_event(owning_state(), {:espex_ble_gatt_service, 0xAABB, service})

      assert %Proto.BluetoothGATTGetServicesResponse{
               address: 0xAABB,
               services: [%Proto.BluetoothGATTService{short_uuid: 0x180D}]
             } = response
    end

    test "{:espex_ble_gatt_services_done, address} → GetServicesDoneResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(owning_state(), {:espex_ble_gatt_services_done, 0xAABB})

      assert %Proto.BluetoothGATTGetServicesDoneResponse{address: 0xAABB} = response
    end

    test "{:espex_ble_gatt_read, _, _, {:ok, data}} → ReadResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(owning_state(), {:espex_ble_gatt_read, 0xAABB, 7, {:ok, "hello"}})

      assert %Proto.BluetoothGATTReadResponse{address: 0xAABB, handle: 7, data: "hello"} = response
    end

    test "{:espex_ble_gatt_read, _, _, {:error, code}} → ErrorResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(owning_state(), {:espex_ble_gatt_read, 0xAABB, 7, {:error, -5}})

      assert %Proto.BluetoothGATTErrorResponse{address: 0xAABB, handle: 7, error: -5} = response
    end

    test "{:espex_ble_gatt_write, _, _, {:ok, _}} → WriteResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(owning_state(), {:espex_ble_gatt_write, 0xAABB, 7, {:ok, :ack}})

      assert %Proto.BluetoothGATTWriteResponse{address: 0xAABB, handle: 7} = response
    end

    test "{:espex_ble_gatt_write, _, _, {:error, code}} → ErrorResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(owning_state(), {:espex_ble_gatt_write, 0xAABB, 7, {:error, -6}})

      assert %Proto.BluetoothGATTErrorResponse{address: 0xAABB, handle: 7, error: -6} = response
    end

    test "{:espex_ble_gatt_notify, _, _, {:ok, _}} → NotifyResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(owning_state(), {:espex_ble_gatt_notify, 0xAABB, 7, {:ok, :ack}})

      assert %Proto.BluetoothGATTNotifyResponse{address: 0xAABB, handle: 7} = response
    end

    test "{:espex_ble_gatt_notify, _, _, {:error, code}} → ErrorResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(owning_state(), {:espex_ble_gatt_notify, 0xAABB, 9, {:error, -7}})

      assert %Proto.BluetoothGATTErrorResponse{address: 0xAABB, handle: 9, error: -7} = response
    end

    test "{:espex_ble_gatt_notify_data, ...} → NotifyDataResponse" do
      {_s, [{:send, response}]} =
        Dispatch.handle_event(owning_state(), {:espex_ble_gatt_notify_data, 0xAABB, 7, "tick"})

      assert %Proto.BluetoothGATTNotifyDataResponse{address: 0xAABB, handle: 7, data: "tick"} =
               response
    end

    test "GATT events for an unowned address are dropped silently" do
      # Late event after disconnect/release: ownership cleared but the
      # adapter's in-flight read response still arrives. Mustn't forward.
      events = [
        {:espex_ble_gatt_read, 0xCCDD, 7, {:ok, "stale"}},
        {:espex_ble_gatt_write, 0xCCDD, 7, {:ok, :ack}},
        {:espex_ble_gatt_notify, 0xCCDD, 7, {:ok, :enabled}},
        {:espex_ble_gatt_notify_data, 0xCCDD, 7, "tick"},
        {:espex_ble_gatt_services_done, 0xCCDD}
      ]

      # State owns 0xAABB but not 0xCCDD.
      s = owning_state(0xAABB)

      for event <- events do
        assert {^s, []} = Dispatch.handle_event(s, event)
      end
    end
  end

  describe "modem_pins_response/2 status" do
    test "OK on success, NOT_SUPPORTED and ERROR on the two failure kinds" do
      assert %{status: :SERIAL_PROXY_STATUS_OK} = Dispatch.modem_pins_response(1, {:ok, %{rts: false, dtr: false}})
      assert %{status: :SERIAL_PROXY_STATUS_NOT_SUPPORTED} = Dispatch.modem_pins_response(1, {:error, :not_supported})

      assert %{status: :SERIAL_PROXY_STATUS_ERROR, line_states: 0} =
               Dispatch.modem_pins_response(1, {:error, :not_open})
    end
  end

  describe "modem_pins_response/2" do
    test "ok result packs rts/dtr into line_states bitmask" do
      r = Dispatch.modem_pins_response(3, {:ok, %{rts: true, dtr: false}})
      assert %Proto.SerialProxyGetModemPinsResponse{instance: 3, line_states: 0x01} = r

      r = Dispatch.modem_pins_response(3, {:ok, %{rts: true, dtr: true}})
      assert %Proto.SerialProxyGetModemPinsResponse{instance: 3, line_states: 0x03} = r
    end

    test "error result yields empty bitmask" do
      r = Dispatch.modem_pins_response(3, {:error, :nope})
      assert %Proto.SerialProxyGetModemPinsResponse{instance: 3, line_states: 0} = r
    end
  end

  describe "NoiseEncryptionSetKeyRequest" do
    # Home Assistant sends the 32-byte PSK base64-encoded on the wire (44 bytes).
    # @key32 is the decoded PSK that must reach :set_psk; @key_b64 is what HA puts
    # in the request's key field.
    @key32 :crypto.hash(:sha256, "provisioned")
    @key_b64 Base.encode64(@key32)

    test "rotation over an encrypted channel base64-decodes and emits :set_psk" do
      s = state(encryption: {:active, :tx, :rx})
      assert {^s, [{:set_psk, @key32}]} = Dispatch.handle_request(s, %Proto.NoiseEncryptionSetKeyRequest{key: @key_b64})
    end

    test "plaintext bootstrap when opted in base64-decodes and emits :set_psk" do
      cfg = %DeviceConfig{accepts_key_provisioning: true}
      s = state(device_config: cfg, encryption: :disabled)
      assert {^s, [{:set_psk, @key32}]} = Dispatch.handle_request(s, %Proto.NoiseEncryptionSetKeyRequest{key: @key_b64})
    end

    test "plaintext without opt-in is rejected with success: false and no :set_psk" do
      cfg = %DeviceConfig{accepts_key_provisioning: false}
      s = state(device_config: cfg, encryption: :disabled)

      assert {^s, actions} = Dispatch.handle_request(s, %Proto.NoiseEncryptionSetKeyRequest{key: @key_b64})
      assert {:send, %Proto.NoiseEncryptionSetKeyResponse{success: false}} in actions
      refute Enum.any?(actions, &match?({:set_psk, _}, &1))
    end

    test "non-base64 garbage is rejected even over an encrypted channel" do
      s = state(encryption: {:active, :tx, :rx})

      assert {^s, actions} = Dispatch.handle_request(s, %Proto.NoiseEncryptionSetKeyRequest{key: <<1, 2, 3>>})
      assert {:send, %Proto.NoiseEncryptionSetKeyResponse{success: false}} in actions
      refute Enum.any?(actions, &match?({:set_psk, _}, &1))
    end

    test "valid base64 that decodes to the wrong length is rejected" do
      s = state(encryption: {:active, :tx, :rx})
      short = Base.encode64(:crypto.strong_rand_bytes(16))

      assert {^s, actions} = Dispatch.handle_request(s, %Proto.NoiseEncryptionSetKeyRequest{key: short})
      assert {:send, %Proto.NoiseEncryptionSetKeyResponse{success: false}} in actions
      refute Enum.any?(actions, &match?({:set_psk, _}, &1))
    end

    test "a raw (unencoded) 32-byte key is rejected — HA always base64-encodes" do
      s = state(encryption: {:active, :tx, :rx})

      assert {^s, actions} = Dispatch.handle_request(s, %Proto.NoiseEncryptionSetKeyRequest{key: @key32})
      assert {:send, %Proto.NoiseEncryptionSetKeyResponse{success: false}} in actions
      refute Enum.any?(actions, &match?({:set_psk, _}, &1))
    end
  end
end
