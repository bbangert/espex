defmodule Espex.Dispatch do
  @moduledoc false

  import Bitwise

  alias Espex.{BluetoothProxy, ConnectionState, DeviceConfig, InfraredProxy, Proto, SerialProxy}

  # Bit positions for Proto.SerialProxy{Set,Get}ModemPins{Request,Response}.line_states,
  # per ESPHome's SerialProxyLineStateFlag enum in serial_proxy.h.
  @rts_bit 0x01
  @dtr_bit 0x02

  # Every protobuf struct in this list routes through
  # Espex.EntityProvider.handle_command/1 when a provider is configured.
  @entity_command_types [
    Proto.CoverCommandRequest,
    Proto.FanCommandRequest,
    Proto.LightCommandRequest,
    Proto.SwitchCommandRequest,
    Proto.ClimateCommandRequest,
    Proto.NumberCommandRequest,
    Proto.SelectCommandRequest,
    Proto.SirenCommandRequest,
    Proto.LockCommandRequest,
    Proto.ButtonCommandRequest,
    Proto.MediaPlayerCommandRequest,
    Proto.AlarmControlPanelCommandRequest,
    Proto.TextCommandRequest,
    Proto.DateCommandRequest,
    Proto.TimeCommandRequest,
    Proto.ValveCommandRequest,
    Proto.DateTimeCommandRequest,
    Proto.UpdateCommandRequest,
    Proto.WaterHeaterCommandRequest
  ]

  @type action ::
          {:send, struct()}
          | {:close, atom()}
          | {:log, :debug | :info | :warning | :error, String.t()}
          | {:serial_open, instance :: non_neg_integer(), SerialProxy.open_opts()}
          | {:serial_write, instance :: non_neg_integer(), data :: binary()}
          | {:serial_close, instance :: non_neg_integer()}
          | {:serial_modem_pins_set, instance :: non_neg_integer(), rts :: boolean(), dtr :: boolean()}
          | {:serial_modem_pins_get, instance :: non_neg_integer()}
          | {:serial_request, instance :: non_neg_integer(), SerialProxy.request_type()}
          | {:replay_pending_subscribe, instance :: non_neg_integer()}
          | :zwave_subscribe
          | :zwave_unsubscribe
          | {:zwave_send_frame, binary()}
          | :infrared_subscribe
          | :infrared_unsubscribe
          | {:infrared_transmit, key :: non_neg_integer(), timings :: [integer()], SerialProxy.open_opts()}
          | :ble_scanner_subscribe
          | :ble_scanner_unsubscribe
          | {:ble_scanner_set_mode, :passive | :active}
          | {:ble_connect, address :: non_neg_integer(), opts :: keyword()}
          | {:ble_disconnect, address :: non_neg_integer()}
          | {:ble_release_ownership, address :: non_neg_integer()}
          | {:ble_pair, address :: non_neg_integer()}
          | {:ble_unpair, address :: non_neg_integer()}
          | {:ble_clear_cache, address :: non_neg_integer()}
          | {:ble_set_connection_params, address :: non_neg_integer(), params :: map()}
          | :ble_push_connections_free
          | {:ble_gatt_get_services, address :: non_neg_integer()}
          | {:ble_gatt_read, address :: non_neg_integer(), handle :: non_neg_integer()}
          | {:ble_gatt_write, address :: non_neg_integer(), handle :: non_neg_integer(), data :: binary(),
             response? :: boolean()}
          | {:ble_gatt_read_descriptor, address :: non_neg_integer(), handle :: non_neg_integer()}
          | {:ble_gatt_write_descriptor, address :: non_neg_integer(), handle :: non_neg_integer(), data :: binary()}
          | {:ble_gatt_notify, address :: non_neg_integer(), handle :: non_neg_integer(), enable? :: boolean()}
          | {:entity_command, struct()}
          | {:set_psk, binary()}
          | :client_connected

  @type result :: {ConnectionState.t(), [action()]}

  # ---------------------------------------------------------------------------
  # handle_request/2 — one dispatch per inbound protobuf message
  # ---------------------------------------------------------------------------

  @doc """
  Dispatch an inbound protobuf message against the current state.
  """
  @spec handle_request(ConnectionState.t(), struct()) :: result()
  def handle_request(state, message)

  def handle_request(state, %Proto.HelloRequest{} = req) do
    state = ConnectionState.put_client_hello(state, req.client_info, {req.api_version_major, req.api_version_minor})

    response = %Proto.HelloResponse{
      api_version_major: DeviceConfig.api_version_major(),
      api_version_minor: DeviceConfig.api_version_minor(),
      server_info: DeviceConfig.server_info(state.device_config),
      name: state.device_config.name
    }

    {state,
     [
       {:log, :info, "hello from #{state.peer} (client_info=#{inspect(req.client_info)})"},
       {:send, response},
       :client_connected
     ]}
  end

  def handle_request(state, %Proto.AuthenticationRequest{}) do
    {state, [{:send, %Proto.AuthenticationResponse{invalid_password: false}}]}
  end

  def handle_request(state, %Proto.PingRequest{}) do
    {state, [{:send, %Proto.PingResponse{}}]}
  end

  # The client answering one of OUR keepalive pings (see Espex.Connection).
  # The bytes themselves already reset the idle clock in handle_data; the
  # message needs no further action.
  def handle_request(state, %Proto.PingResponse{}) do
    {state, []}
  end

  def handle_request(state, %Proto.DeviceInfoRequest{}) do
    serial_protos = Enum.map(state.serial_proxies, &SerialProxy.Info.to_proto/1)
    response = DeviceConfig.to_device_info_response(state.device_config, serial_protos)
    {state, [{:send, response}]}
  end

  def handle_request(state, %Proto.ListEntitiesRequest{}) do
    ir_actions = Enum.map(state.infrared_entities, &{:send, InfraredProxy.Entity.to_proto(&1)})
    custom_actions = Enum.map(state.entities, &{:send, &1})

    {state, ir_actions ++ custom_actions ++ [{:send, %Proto.ListEntitiesDoneResponse{}}]}
  end

  def handle_request(state, %Proto.SubscribeStatesRequest{}) do
    initial_state_actions =
      case ConnectionState.adapter(state, :entity_provider) do
        nil -> []
        module -> Enum.map(module.initial_states(), &{:send, &1})
      end

    {subscribe_actions, state} =
      if ConnectionState.adapter?(state, :infrared_proxy) and not state.infrared_subscribed do
        {[:infrared_subscribe], ConnectionState.put_infrared_subscribed(state, true)}
      else
        {[], state}
      end

    {state, initial_state_actions ++ subscribe_actions}
  end

  def handle_request(state, %Proto.SubscribeLogsRequest{} = req) do
    {state, [{:log, :debug, "#{state.peer} subscribed to logs (level=#{req.level})"}]}
  end

  def handle_request(state, %Proto.SubscribeHomeassistantServicesRequest{}) do
    {state, [{:log, :debug, "#{state.peer} subscribed to HA services"}]}
  end

  def handle_request(state, %Proto.SubscribeHomeAssistantStatesRequest{}) do
    {state, [{:log, :debug, "#{state.peer} subscribed to HA states"}]}
  end

  def handle_request(state, %Proto.DisconnectRequest{}) do
    {state,
     [
       {:log, :info, "#{state.peer} requested disconnect"},
       {:send, %Proto.DisconnectResponse{}},
       {:close, :disconnect_requested}
     ]}
  end

  def handle_request(state, %Proto.GetTimeRequest{}) do
    epoch = state.clock_fun.() |> Bitwise.band(0xFFFFFFFF)
    {state, [{:send, %Proto.GetTimeResponse{epoch_seconds: epoch}}]}
  end

  # -- Serial Proxy --

  def handle_request(state, %Proto.SerialProxyConfigureRequest{} = req) do
    if ConnectionState.find_serial_proxy(state, req.instance) do
      opts = SerialProxy.configure_request_to_open_opts(req)

      close_actions =
        if ConnectionState.port_open?(state, req.instance) do
          [{:serial_close, req.instance}]
        else
          []
        end

      open_actions = [
        {:serial_open, req.instance, opts},
        {:replay_pending_subscribe, req.instance}
      ]

      {state, close_actions ++ open_actions}
    else
      {state, [{:log, :warning, "serial proxy configure for unknown instance #{req.instance}"}]}
    end
  end

  def handle_request(state, %Proto.SerialProxyWriteRequest{} = req) do
    if ConnectionState.port_open?(state, req.instance) do
      {state, [{:serial_write, req.instance, req.data}]}
    else
      {state, [{:log, :warning, "serial proxy write for unopened instance #{req.instance}"}]}
    end
  end

  def handle_request(state, %Proto.SerialProxySetModemPinsRequest{} = req) do
    if ConnectionState.port_open?(state, req.instance) do
      {rts, dtr} = unpack_line_states(req.line_states)
      {state, [{:serial_modem_pins_set, req.instance, rts, dtr}]}
    else
      {state, [{:log, :warning, "set_modem_pins for unopened instance #{req.instance}"}]}
    end
  end

  def handle_request(state, %Proto.SerialProxyGetModemPinsRequest{} = req) do
    if ConnectionState.port_open?(state, req.instance) do
      {state, [{:serial_modem_pins_get, req.instance}]}
    else
      response = %Proto.SerialProxyGetModemPinsResponse{instance: req.instance, line_states: 0}
      {state, [{:log, :warning, "get_modem_pins for unopened instance #{req.instance}"}, {:send, response}]}
    end
  end

  def handle_request(state, %Proto.SerialProxyRequest{} = req) do
    case normalize_request_type(req.type) do
      nil ->
        response = serial_request_error(req.instance, req.type, "unknown request type")

        {state,
         [
           {:log, :warning, "serial proxy request unknown type: #{inspect(req.type)}"},
           {:send, response}
         ]}

      :flush ->
        handle_flush_request(state, req)

      type when type in [:subscribe, :unsubscribe] ->
        handle_subscription_request(state, req, type)
    end
  end

  # -- Infrared Proxy --

  def handle_request(state, %Proto.InfraredRFTransmitRawTimingsRequest{} = req) do
    if ConnectionState.adapter?(state, :infrared_proxy) do
      opts = [
        carrier_frequency: if(req.carrier_frequency > 0, do: req.carrier_frequency, else: 38_000),
        repeat_count: if(req.repeat_count > 0, do: req.repeat_count, else: 1)
      ]

      {sub_actions, state} =
        if state.infrared_subscribed do
          {[], state}
        else
          {[:infrared_subscribe], ConnectionState.put_infrared_subscribed(state, true)}
        end

      {state, sub_actions ++ [{:infrared_transmit, req.key, req.timings, opts}]}
    else
      {state, [{:log, :warning, "infrared transmit ignored — no adapter configured"}]}
    end
  end

  # -- Z-Wave Proxy --

  def handle_request(state, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE}) do
    if ConnectionState.adapter?(state, :zwave_proxy) do
      {state, [:zwave_subscribe]}
    else
      {state, [{:log, :info, "Z-Wave subscribe ignored — no adapter configured"}]}
    end
  end

  def handle_request(state, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE}) do
    if state.zwave_subscribed do
      {ConnectionState.put_zwave_subscribed(state, false), [:zwave_unsubscribe]}
    else
      {state, []}
    end
  end

  def handle_request(state, %Proto.ZWaveProxyRequest{} = req) do
    {state, [{:log, :debug, "unhandled Z-Wave proxy request type: #{inspect(req.type)}"}]}
  end

  def handle_request(state, %Proto.ZWaveProxyFrame{data: data}) do
    if ConnectionState.adapter?(state, :zwave_proxy) do
      {state, [{:zwave_send_frame, data}]}
    else
      {state, [{:log, :warning, "Z-Wave frame dropped — no adapter configured"}]}
    end
  end

  # -- Bluetooth scanner subscribe / unsubscribe / set-mode --

  def handle_request(state, %Proto.SubscribeBluetoothLEAdvertisementsRequest{flags: flags}) do
    cond do
      not ConnectionState.adapter?(state, :bluetooth_scanner) ->
        {state, [{:log, :info, "BLE scanner subscribe ignored — no adapter configured"}]}

      state.bluetooth_scanner_subscribed ->
        {state, scanner_flag_log(flags)}

      true ->
        state = ConnectionState.put_bluetooth_scanner_subscribed(state, true)
        {state, [:ble_scanner_subscribe | scanner_flag_log(flags)]}
    end
  end

  def handle_request(state, %Proto.UnsubscribeBluetoothLEAdvertisementsRequest{}) do
    if state.bluetooth_scanner_subscribed do
      {ConnectionState.put_bluetooth_scanner_subscribed(state, false), [:ble_scanner_unsubscribe]}
    else
      {state, []}
    end
  end

  def handle_request(state, %Proto.BluetoothScannerSetModeRequest{mode: wire_mode}) do
    cond do
      not ConnectionState.adapter?(state, :bluetooth_scanner) ->
        {state, [{:log, :info, "BLE scanner set-mode ignored — no adapter configured"}]}

      true ->
        case scanner_mode_from_wire(wire_mode) do
          nil ->
            {state, [{:log, :warning, "BLE scanner set-mode ignored — unknown wire mode #{inspect(wire_mode)}"}]}

          mode ->
            {state, [{:ble_scanner_set_mode, mode}]}
        end
    end
  end

  # -- Bluetooth active proxy: device requests + connection_params --

  def handle_request(state, %Proto.BluetoothDeviceRequest{} = req) do
    cond do
      not ConnectionState.adapter?(state, :bluetooth_proxy) ->
        {state, [{:log, :info, "BLE device request ignored — no adapter configured"}]}

      true ->
        case ble_device_action(req) do
          nil ->
            {state,
             [
               {:log, :warning, "BLE device request ignored — unknown request_type #{inspect(req.request_type)}"}
             ]}

          action ->
            {state, [action]}
        end
    end
  end

  def handle_request(state, %Proto.BluetoothSetConnectionParamsRequest{} = req) do
    if ConnectionState.adapter?(state, :bluetooth_proxy) do
      params = %{
        min_interval: req.min_interval,
        max_interval: req.max_interval,
        latency: req.latency,
        timeout: req.timeout
      }

      {state, [{:ble_set_connection_params, req.address, params}]}
    else
      {state, [{:log, :info, "BLE set_connection_params ignored — no adapter configured"}]}
    end
  end

  def handle_request(state, %Proto.SubscribeBluetoothConnectionsFreeRequest{}) do
    cond do
      not ConnectionState.adapter?(state, :bluetooth_proxy) ->
        {state, [{:log, :info, "BLE connections_free subscribe ignored — no adapter configured"}]}

      state.bluetooth_connections_free_subscribed ->
        {state, [:ble_push_connections_free]}

      true ->
        state = ConnectionState.put_bluetooth_connections_free_subscribed(state, true)
        {state, [:ble_push_connections_free]}
    end
  end

  # -- Bluetooth GATT requests --

  def handle_request(state, %Proto.BluetoothGATTGetServicesRequest{address: address}) do
    ble_gatt_action(state, {:ble_gatt_get_services, address})
  end

  def handle_request(state, %Proto.BluetoothGATTReadRequest{address: address, handle: handle}) do
    ble_gatt_action(state, {:ble_gatt_read, address, handle})
  end

  def handle_request(state, %Proto.BluetoothGATTWriteRequest{} = req) do
    ble_gatt_action(state, {:ble_gatt_write, req.address, req.handle, req.data, req.response})
  end

  def handle_request(state, %Proto.BluetoothGATTReadDescriptorRequest{address: address, handle: handle}) do
    ble_gatt_action(state, {:ble_gatt_read_descriptor, address, handle})
  end

  def handle_request(state, %Proto.BluetoothGATTWriteDescriptorRequest{} = req) do
    ble_gatt_action(state, {:ble_gatt_write_descriptor, req.address, req.handle, req.data})
  end

  def handle_request(state, %Proto.BluetoothGATTNotifyRequest{} = req) do
    ble_gatt_action(state, {:ble_gatt_notify, req.address, req.handle, req.enable})
  end

  # -- Entity commands (routed to EntityProvider if configured) --

  def handle_request(state, %type{} = message) when type in @entity_command_types do
    if ConnectionState.adapter?(state, :entity_provider) do
      {state, [{:entity_command, message}]}
    else
      {state, [{:log, :debug, "entity command #{inspect(type)} ignored — no adapter configured"}]}
    end
  end

  # -- Noise PSK provisioning / rotation --

  def handle_request(state, %Proto.NoiseEncryptionSetKeyRequest{key: key}) do
    cond do
      byte_size(key) != 32 ->
        {state,
         [
           {:log, :warning, "SetKey rejected — key must be 32 bytes, got #{byte_size(key)}"},
           {:send, %Proto.NoiseEncryptionSetKeyResponse{success: false}}
         ]}

      set_key_allowed?(state) ->
        {state, [{:set_psk, key}]}

      true ->
        {state,
         [
           {:log, :warning, "SetKey rejected over plaintext — accepts_key_provisioning is false"},
           {:send, %Proto.NoiseEncryptionSetKeyResponse{success: false}}
         ]}
    end
  end

  # -- Catch-all --

  def handle_request(state, message) do
    {state, [{:log, :debug, "unhandled message: #{inspect(message.__struct__)}"}]}
  end

  # ---------------------------------------------------------------------------
  # handle_event/2 — dispatch for adapter-driven events
  # ---------------------------------------------------------------------------

  @doc """
  Dispatch an adapter-driven event (forwarded by the handler's
  `handle_info/2`) against the current state.
  """
  @spec handle_event(ConnectionState.t(), term()) :: result()
  def handle_event(state, event)

  def handle_event(state, {:espex_serial_data, handle, data}) do
    case ConnectionState.instance_for_handle(state, handle) do
      nil ->
        {state, []}

      instance ->
        {state, [{:send, %Proto.SerialProxyDataReceived{instance: instance, data: data}}]}
    end
  end

  def handle_event(state, {:espex_zwave_frame, data}) do
    if state.zwave_subscribed do
      {state, [{:send, %Proto.ZWaveProxyFrame{data: data}}]}
    else
      {state, []}
    end
  end

  def handle_event(state, {:espex_zwave_home_id_changed, <<_::binary-size(4)>> = bytes}) do
    message = %Proto.ZWaveProxyRequest{
      type: :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE,
      data: bytes
    }

    {state, [{:send, message}]}
  end

  def handle_event(state, {:espex_ir_receive, key, timings}) do
    if state.infrared_subscribed do
      {state, [{:send, %Proto.InfraredRFReceiveEvent{key: key, timings: timings}}]}
    else
      {state, []}
    end
  end

  def handle_event(state, {:espex_ble_advertisement, address, rssi, address_type, data}) do
    if state.bluetooth_scanner_subscribed do
      advertisement = %Proto.BluetoothLERawAdvertisement{
        address: address,
        rssi: rssi,
        address_type: address_type,
        data: data
      }

      {state, [{:send, %Proto.BluetoothLERawAdvertisementsResponse{advertisements: [advertisement]}}]}
    else
      {state, []}
    end
  end

  def handle_event(state, {:espex_ble_scanner_state, scanner_state, mode, configured_mode}) do
    response = %Proto.BluetoothScannerStateResponse{
      state: scanner_state_to_wire(scanner_state),
      mode: scanner_mode_to_wire(mode),
      configured_mode: scanner_mode_to_wire(configured_mode)
    }

    {state, [{:send, response}]}
  end

  def handle_event(state, {:espex_ble_connection, address, {:ok, mtu}}) do
    if ConnectionState.bluetooth_owns?(state, address) do
      response = %Proto.BluetoothDeviceConnectionResponse{
        address: address,
        connected: true,
        mtu: mtu,
        error: Espex.BluetoothProxy.ErrorCodes.ok()
      }

      {state, [{:send, response} | maybe_push_connections_free(state)]}
    else
      # Adapter reported a connection for an address we don't own —
      # probably a late event after release. Drop silently rather than
      # confuse the client with a successful connection it didn't ask
      # for.
      {state, []}
    end
  end

  def handle_event(state, {:espex_ble_connection, address, {:error, error_code}}) do
    response = %Proto.BluetoothDeviceConnectionResponse{
      address: address,
      connected: false,
      mtu: 0,
      error: error_code
    }

    if ConnectionState.bluetooth_owns?(state, address) do
      state = ConnectionState.drop_bluetooth_owned(state, address)

      {state, [{:send, response}, {:ble_release_ownership, address} | maybe_push_connections_free(state)]}
    else
      {state, [{:send, response}]}
    end
  end

  def handle_event(state, {:espex_ble_pair, address, paired?, error}) do
    response = %Proto.BluetoothDevicePairingResponse{
      address: address,
      paired: paired?,
      error: error
    }

    {state, [{:send, response}]}
  end

  def handle_event(state, {:espex_ble_unpair, address, success?, error}) do
    response = %Proto.BluetoothDeviceUnpairingResponse{
      address: address,
      success: success?,
      error: error
    }

    {state, [{:send, response}]}
  end

  def handle_event(state, {:espex_ble_clear_cache, address, success?, error}) do
    response = %Proto.BluetoothDeviceClearCacheResponse{
      address: address,
      success: success?,
      error: error
    }

    {state, [{:send, response}]}
  end

  def handle_event(state, {:espex_ble_connection_params, address, error}) do
    response = %Proto.BluetoothSetConnectionParamsResponse{
      address: address,
      error: error
    }

    {state, [{:send, response}]}
  end

  # GATT event handlers gate every outbound proto on
  # `ConnectionState.bluetooth_owns?/2`. A late event (e.g. an
  # in-flight read response that arrives after the client issued
  # DISCONNECT) is dropped silently so we don't forward stale GATT
  # frames for a peripheral the connection no longer owns. Mirrors the
  # `{:espex_ble_connection, _, {:ok, _}}` pattern.

  def handle_event(state, {:espex_ble_gatt_service, address, %BluetoothProxy.Service{} = service}) do
    if_gatt_owned(state, address, fn ->
      # Spec allows multiple services per response; we stream one per frame
      # for adapter simplicity (the proto field is `repeated` so any count
      # is wire-valid).
      [
        {:send,
         %Proto.BluetoothGATTGetServicesResponse{
           address: address,
           services: [BluetoothProxy.Service.to_proto(service)]
         }}
      ]
    end)
  end

  def handle_event(state, {:espex_ble_gatt_services_done, address}) do
    if_gatt_owned(state, address, fn ->
      [{:send, %Proto.BluetoothGATTGetServicesDoneResponse{address: address}}]
    end)
  end

  def handle_event(state, {:espex_ble_gatt_read, address, handle, {:ok, data}}) do
    if_gatt_owned(state, address, fn ->
      [{:send, %Proto.BluetoothGATTReadResponse{address: address, handle: handle, data: data}}]
    end)
  end

  def handle_event(state, {:espex_ble_gatt_read, address, handle, {:error, error_code}}) do
    if_gatt_owned(state, address, fn ->
      [
        {:send, %Proto.BluetoothGATTErrorResponse{address: address, handle: handle, error: error_code}}
      ]
    end)
  end

  def handle_event(state, {:espex_ble_gatt_write, address, handle, {:ok, _}}) do
    if_gatt_owned(state, address, fn ->
      [{:send, %Proto.BluetoothGATTWriteResponse{address: address, handle: handle}}]
    end)
  end

  def handle_event(state, {:espex_ble_gatt_write, address, handle, {:error, error_code}}) do
    if_gatt_owned(state, address, fn ->
      [
        {:send, %Proto.BluetoothGATTErrorResponse{address: address, handle: handle, error: error_code}}
      ]
    end)
  end

  def handle_event(state, {:espex_ble_gatt_notify, address, handle, {:ok, _}}) do
    if_gatt_owned(state, address, fn ->
      [{:send, %Proto.BluetoothGATTNotifyResponse{address: address, handle: handle}}]
    end)
  end

  def handle_event(state, {:espex_ble_gatt_notify, address, handle, {:error, error_code}}) do
    if_gatt_owned(state, address, fn ->
      [
        {:send, %Proto.BluetoothGATTErrorResponse{address: address, handle: handle, error: error_code}}
      ]
    end)
  end

  def handle_event(state, {:espex_ble_gatt_notify_data, address, handle, data}) do
    if_gatt_owned(state, address, fn ->
      [
        {:send, %Proto.BluetoothGATTNotifyDataResponse{address: address, handle: handle, data: data}}
      ]
    end)
  end

  def handle_event(state, {:espex_state_update, %_{} = struct}) do
    {state, [{:send, struct}]}
  end

  def handle_event(state, event) do
    {state, [{:log, :debug, "unhandled adapter event: #{inspect(event)}"}]}
  end

  # ---------------------------------------------------------------------------
  # Response builders for actions that the handler resolves inline
  # (e.g. it performs an adapter call then needs to reply with a struct)
  # ---------------------------------------------------------------------------

  @doc """
  Build a `SerialProxyGetModemPinsResponse` from an adapter's return
  value. The handler calls this after resolving a
  `:serial_modem_pins_get` action.
  """
  @spec modem_pins_response(non_neg_integer(), {:ok, %{rts: boolean(), dtr: boolean()}} | {:error, term()}) ::
          Proto.SerialProxyGetModemPinsResponse.t()
  def modem_pins_response(instance, {:ok, %{rts: rts, dtr: dtr}}) do
    %Proto.SerialProxyGetModemPinsResponse{instance: instance, line_states: pack_line_states(rts, dtr)}
  end

  def modem_pins_response(instance, {:error, _reason}) do
    %Proto.SerialProxyGetModemPinsResponse{instance: instance, line_states: 0}
  end

  @doc """
  Build a `SerialProxyRequestResponse` from an adapter's return value.
  The handler calls this after resolving a `:serial_request` action.
  """
  @spec serial_request_response(
          non_neg_integer(),
          SerialProxy.request_type(),
          {:ok, SerialProxy.request_status()} | {:error, term()}
        ) :: Proto.SerialProxyRequestResponse.t()
  def serial_request_response(instance, type, {:ok, status}) do
    %Proto.SerialProxyRequestResponse{
      instance: instance,
      type: to_wire_request_type(type),
      status: to_wire_status(status),
      error_message: ""
    }
  end

  def serial_request_response(instance, type, {:error, reason}) do
    %Proto.SerialProxyRequestResponse{
      instance: instance,
      type: to_wire_request_type(type),
      status: :SERIAL_PROXY_STATUS_ERROR,
      error_message: inspect(reason)
    }
  end

  # SetKey is accepted over an already-encrypted channel (rotation —
  # the channel is authenticated) or over plaintext only when the node
  # opted into runtime provisioning while keyless (bootstrap).
  defp set_key_allowed?(state) do
    match?({:active, _, _}, state.encryption) or
      (state.encryption == :disabled and state.device_config.accepts_key_provisioning)
  end

  defp unpack_line_states(bits) do
    {(bits &&& @rts_bit) != 0, (bits &&& @dtr_bit) != 0}
  end

  defp pack_line_states(rts, dtr) do
    if(rts, do: @rts_bit, else: 0) ||| if(dtr, do: @dtr_bit, else: 0)
  end

  defp normalize_request_type(:SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE), do: :subscribe
  defp normalize_request_type(:SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE), do: :unsubscribe
  defp normalize_request_type(:SERIAL_PROXY_REQUEST_TYPE_FLUSH), do: :flush
  defp normalize_request_type(_), do: nil

  defp to_wire_request_type(:subscribe), do: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
  defp to_wire_request_type(:unsubscribe), do: :SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE
  defp to_wire_request_type(:flush), do: :SERIAL_PROXY_REQUEST_TYPE_FLUSH

  defp to_wire_status(:ok), do: :SERIAL_PROXY_STATUS_OK
  defp to_wire_status(:assumed_success), do: :SERIAL_PROXY_STATUS_ASSUMED_SUCCESS
  defp to_wire_status(:error), do: :SERIAL_PROXY_STATUS_ERROR
  defp to_wire_status(:timeout), do: :SERIAL_PROXY_STATUS_TIMEOUT
  defp to_wire_status(:not_supported), do: :SERIAL_PROXY_STATUS_NOT_SUPPORTED

  defp serial_request_error(instance, wire_type, message) do
    %Proto.SerialProxyRequestResponse{
      instance: instance,
      type: wire_type,
      status: :SERIAL_PROXY_STATUS_ERROR,
      error_message: message
    }
  end

  defp serial_request_ok(instance, wire_type) do
    %Proto.SerialProxyRequestResponse{
      instance: instance,
      type: wire_type,
      status: :SERIAL_PROXY_STATUS_OK,
      error_message: ""
    }
  end

  defp handle_flush_request(state, req) do
    if ConnectionState.port_open?(state, req.instance) do
      {state, [{:serial_request, req.instance, :flush}]}
    else
      response = serial_request_error(req.instance, req.type, "instance not open")

      {state,
       [
         {:log, :warning, "serial proxy flush for unopened instance #{req.instance}"},
         {:send, response}
       ]}
    end
  end

  defp handle_subscription_request(state, req, type) do
    cond do
      ConnectionState.find_serial_proxy(state, req.instance) == nil ->
        response = serial_request_error(req.instance, req.type, "unknown instance")

        {state,
         [
           {:log, :warning, "serial proxy #{type} for unknown instance #{req.instance}"},
           {:send, response}
         ]}

      ConnectionState.port_open?(state, req.instance) ->
        {state, [{:serial_request, req.instance, type}]}

      type == :subscribe ->
        {ConnectionState.put_pending_subscription(state, req.instance),
         [{:send, serial_request_ok(req.instance, req.type)}]}

      type == :unsubscribe ->
        {ConnectionState.drop_pending_subscription(state, req.instance),
         [{:send, serial_request_ok(req.instance, req.type)}]}
    end
  end

  defp scanner_flag_log(0), do: []

  defp scanner_flag_log(flags) do
    [{:log, :debug, "BLE scanner subscribe flags=#{flags} ignored — no flags are defined yet"}]
  end

  defp scanner_mode_from_wire(:BLUETOOTH_SCANNER_MODE_PASSIVE), do: :passive
  defp scanner_mode_from_wire(:BLUETOOTH_SCANNER_MODE_ACTIVE), do: :active
  defp scanner_mode_from_wire(_unknown), do: nil

  defp scanner_mode_to_wire(:passive), do: :BLUETOOTH_SCANNER_MODE_PASSIVE
  defp scanner_mode_to_wire(:active), do: :BLUETOOTH_SCANNER_MODE_ACTIVE

  defp scanner_state_to_wire(:idle), do: :BLUETOOTH_SCANNER_STATE_IDLE
  defp scanner_state_to_wire(:starting), do: :BLUETOOTH_SCANNER_STATE_STARTING
  defp scanner_state_to_wire(:running), do: :BLUETOOTH_SCANNER_STATE_RUNNING
  defp scanner_state_to_wire(:failed), do: :BLUETOOTH_SCANNER_STATE_FAILED
  defp scanner_state_to_wire(:stopping), do: :BLUETOOTH_SCANNER_STATE_STOPPING
  defp scanner_state_to_wire(:stopped), do: :BLUETOOTH_SCANNER_STATE_STOPPED

  defp ble_device_action(%Proto.BluetoothDeviceRequest{request_type: type, address: address} = req) do
    case type do
      :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT ->
        {:ble_connect, address, ble_connect_opts(req, :default)}

      :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITH_CACHE ->
        {:ble_connect, address, ble_connect_opts(req, :with_cache)}

      :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITHOUT_CACHE ->
        {:ble_connect, address, ble_connect_opts(req, :without_cache)}

      :BLUETOOTH_DEVICE_REQUEST_TYPE_DISCONNECT ->
        {:ble_disconnect, address}

      :BLUETOOTH_DEVICE_REQUEST_TYPE_PAIR ->
        {:ble_pair, address}

      :BLUETOOTH_DEVICE_REQUEST_TYPE_UNPAIR ->
        {:ble_unpair, address}

      :BLUETOOTH_DEVICE_REQUEST_TYPE_CLEAR_CACHE ->
        {:ble_clear_cache, address}

      _other ->
        nil
    end
  end

  defp ble_connect_opts(%Proto.BluetoothDeviceRequest{has_address_type: true, address_type: t}, cache_mode) do
    [address_type: t, cache_mode: cache_mode]
  end

  defp ble_connect_opts(%Proto.BluetoothDeviceRequest{}, cache_mode) do
    [address_type: nil, cache_mode: cache_mode]
  end

  # Shared gate for all BLE GATT requests. The ownership check that
  # gates the actual adapter call lives in the interpreter — Dispatch
  # is pure and only emits the action tuple.
  defp ble_gatt_action(state, action) do
    if ConnectionState.adapter?(state, :bluetooth_proxy) do
      {state, [action]}
    else
      {state, [{:log, :info, "BLE GATT request ignored — no adapter configured"}]}
    end
  end

  # Drop GATT events for addresses this connection doesn't own (late
  # arrivals after disconnect/release). Called by every GATT
  # handle_event clause.
  defp if_gatt_owned(state, address, build_actions) do
    if ConnectionState.bluetooth_owns?(state, address) do
      {state, build_actions.()}
    else
      {state, []}
    end
  end

  # Returns the connections_free push action when the client has
  # subscribed, otherwise an empty list. Used after any event that
  # changes the `allocated` set (connect succeeded, connection failed
  # and released ownership, disconnect, cleanup sweep).
  defp maybe_push_connections_free(%ConnectionState{bluetooth_connections_free_subscribed: true}) do
    [:ble_push_connections_free]
  end

  defp maybe_push_connections_free(%ConnectionState{}), do: []
end
