defmodule Espex.Dispatch do
  @moduledoc false

  import Bitwise

  alias Espex.{ConnectionState, DeviceConfig, InfraredProxy, Proto, SerialProxy}

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
          | :zwave_subscribe
          | :zwave_unsubscribe
          | {:zwave_send_frame, binary()}
          | :infrared_subscribe
          | :infrared_unsubscribe
          | {:infrared_transmit, key :: non_neg_integer(), timings :: [integer()], SerialProxy.open_opts()}
          | {:entity_command, struct()}

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
    response = %Proto.HelloResponse{
      api_version_major: DeviceConfig.api_version_major(),
      api_version_minor: DeviceConfig.api_version_minor(),
      server_info: DeviceConfig.server_info(state.device_config),
      name: state.device_config.name
    }

    {state, [{:log, :info, "hello from #{state.peer} (client_info=#{inspect(req.client_info)})"}, {:send, response}]}
  end

  def handle_request(state, %Proto.AuthenticationRequest{}) do
    {state, [{:send, %Proto.AuthenticationResponse{invalid_password: false}}]}
  end

  def handle_request(state, %Proto.PingRequest{}) do
    {state, [{:send, %Proto.PingResponse{}}]}
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

      {state, close_actions ++ [{:serial_open, req.instance, opts}]}
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

      type ->
        if ConnectionState.port_open?(state, req.instance) do
          {state, [{:serial_request, req.instance, type}]}
        else
          response = serial_request_error(req.instance, req.type, "instance not open")

          {state,
           [
             {:log, :warning, "serial proxy request for unopened instance #{req.instance}"},
             {:send, response}
           ]}
        end
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

  # -- Entity commands (routed to EntityProvider if configured) --

  def handle_request(state, %type{} = message) when type in @entity_command_types do
    if ConnectionState.adapter?(state, :entity_provider) do
      {state, [{:entity_command, message}]}
    else
      {state, [{:log, :debug, "entity command #{inspect(type)} ignored — no adapter configured"}]}
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
end
