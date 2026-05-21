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

      {_s, [{:serial_open, 0, opts}, {:replay_pending_subscribe, 0}]} =
        Dispatch.handle_request(state(serial_proxies: [info]), req)

      assert opts[:speed] == 115_200
      assert opts[:parity] == :even
      assert opts[:flow_control] == :hardware
    end

    test "known instance already open: emits :serial_close then :serial_open then :replay_pending_subscribe" do
      info = SerialProxy.Info.new(instance: 0, name: "n")
      s = state(serial_proxies: [info]) |> ConnectionState.put_port(0, :existing_handle)
      {_s, actions} = Dispatch.handle_request(s, %Proto.SerialProxyConfigureRequest{instance: 0})

      assert [{:serial_close, 0}, {:serial_open, 0, _opts}, {:replay_pending_subscribe, 0}] = actions
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

  describe "SerialProxySetModemPinsRequest" do
    test "unpacks line_states bitmask into rts/dtr booleans" do
      s = state() |> ConnectionState.put_port(3, :h)

      {_, [{:serial_modem_pins_set, 3, true, false}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModemPinsRequest{instance: 3, line_states: 0x01})

      {_, [{:serial_modem_pins_set, 3, false, true}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModemPinsRequest{instance: 3, line_states: 0x02})

      {_, [{:serial_modem_pins_set, 3, true, true}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModemPinsRequest{instance: 3, line_states: 0x03})

      {_, [{:serial_modem_pins_set, 3, false, false}]} =
        Dispatch.handle_request(s, %Proto.SerialProxySetModemPinsRequest{instance: 3, line_states: 0})
    end
  end

  describe "SerialProxyRequest" do
    test "open instance with known type: emits :serial_request action" do
      info = SerialProxy.Info.new(instance: 3, name: "n")
      s = state(serial_proxies: [info]) |> ConnectionState.put_port(3, :h)

      {_, [{:serial_request, 3, :subscribe}]} =
        Dispatch.handle_request(s, %Proto.SerialProxyRequest{
          instance: 3,
          type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
        })

      {_, [{:serial_request, 3, :unsubscribe}]} =
        Dispatch.handle_request(s, %Proto.SerialProxyRequest{
          instance: 3,
          type: :SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE
        })

      {_, [{:serial_request, 3, :flush}]} =
        Dispatch.handle_request(s, %Proto.SerialProxyRequest{
          instance: 3,
          type: :SERIAL_PROXY_REQUEST_TYPE_FLUSH
        })
    end

    test "flush for unopened instance: sends ERROR response" do
      {_, [{:log, :warning, _}, {:send, response}]} =
        Dispatch.handle_request(state(), %Proto.SerialProxyRequest{
          instance: 3,
          type: :SERIAL_PROXY_REQUEST_TYPE_FLUSH
        })

      assert %Proto.SerialProxyRequestResponse{
               instance: 3,
               type: :SERIAL_PROXY_REQUEST_TYPE_FLUSH,
               status: :SERIAL_PROXY_STATUS_ERROR,
               error_message: "instance not open"
             } = response
    end

    test "unknown request type: sends ERROR response and logs" do
      s = state() |> ConnectionState.put_port(3, :h)

      {_, [{:log, :warning, _}, {:send, response}]} =
        Dispatch.handle_request(s, %Proto.SerialProxyRequest{instance: 3, type: :SERIAL_PROXY_REQUEST_TYPE_UNKNOWN})

      assert %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_ERROR} = response
    end

    test "subscribe before configure: stashes pending and replies OK" do
      info = SerialProxy.Info.new(instance: 4, name: "n")

      {new_s, [{:send, response}]} =
        Dispatch.handle_request(state(serial_proxies: [info]), %Proto.SerialProxyRequest{
          instance: 4,
          type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
        })

      assert %Proto.SerialProxyRequestResponse{
               instance: 4,
               type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE,
               status: :SERIAL_PROXY_STATUS_OK,
               error_message: ""
             } = response

      assert ConnectionState.pending_subscription?(new_s, 4)
    end

    test "subscribe before configure for unknown instance: ERROR 'unknown instance'" do
      {_, [{:log, :warning, _}, {:send, response}]} =
        Dispatch.handle_request(state(), %Proto.SerialProxyRequest{
          instance: 9,
          type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
        })

      assert %Proto.SerialProxyRequestResponse{
               instance: 9,
               type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE,
               status: :SERIAL_PROXY_STATUS_ERROR,
               error_message: "unknown instance"
             } = response
    end

    test "unsubscribe before configure: drops pending and replies OK" do
      info = SerialProxy.Info.new(instance: 4, name: "n")
      s = state(serial_proxies: [info]) |> ConnectionState.put_pending_subscription(4)

      {new_s, [{:send, response}]} =
        Dispatch.handle_request(s, %Proto.SerialProxyRequest{
          instance: 4,
          type: :SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE
        })

      assert response.status == :SERIAL_PROXY_STATUS_OK
      refute ConnectionState.pending_subscription?(new_s, 4)
    end

    test "subscribe + configure pair: configure emits :replay_pending_subscribe alongside :serial_open" do
      info = SerialProxy.Info.new(instance: 4, name: "n")

      {after_sub, _} =
        Dispatch.handle_request(state(serial_proxies: [info]), %Proto.SerialProxyRequest{
          instance: 4,
          type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
        })

      {after_cfg, actions} =
        Dispatch.handle_request(after_sub, %Proto.SerialProxyConfigureRequest{instance: 4})

      assert [{:serial_open, 4, _opts}, {:replay_pending_subscribe, 4}] = actions
      # dispatch doesn't clear pending — the replay interpreter does
      assert ConnectionState.pending_subscription?(after_cfg, 4)
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
end
