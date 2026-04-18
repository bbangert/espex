defmodule Espex.Dispatch do
  @moduledoc """
  Pure message dispatch for the ESPHome Native API server.

  The `Espex.Connection` handler runs each decoded inbound frame and each
  adapter-driven event through `step/2` or `handle_event/2`, gets back a
  new `%ConnectionState{}` plus a list of effects, and interprets those
  effects against its socket and the configured adapters.

  Adapter module calls (e.g. `InfraredProxy.list_entities/0`) happen
  inline here — they are just function calls on consumer-provided
  modules and stay testable through fake adapters. Everything with
  socket or process side-effects (sending frames, opening ports,
  subscribing) is emitted as an effect so the handler owns those
  interactions exclusively.
  """

  alias Espex.{ConnectionState, DeviceConfig, InfraredProxy, Proto, SerialProxy}

  @type effect ::
          {:send, struct()}
          | {:close, atom()}
          | {:log, :debug | :info | :warning | :error, String.t()}
          | {:serial_open, instance :: non_neg_integer(), SerialProxy.open_opts()}
          | {:serial_write, instance :: non_neg_integer(), data :: binary()}
          | {:serial_close, instance :: non_neg_integer()}
          | {:serial_modem_pins_set, instance :: non_neg_integer(), rts :: boolean(), dtr :: boolean()}
          | {:serial_modem_pins_get, instance :: non_neg_integer()}
          | :zwave_subscribe
          | :zwave_unsubscribe
          | {:zwave_send_frame, binary()}
          | :infrared_subscribe
          | :infrared_unsubscribe
          | {:infrared_transmit, key :: non_neg_integer(), timings :: [integer()], SerialProxy.open_opts()}
          | {:entity_command, struct()}

  @type result :: {ConnectionState.t(), [effect()]}

  # ---------------------------------------------------------------------------
  # step/2 — dispatch for inbound protobuf messages
  # ---------------------------------------------------------------------------

  @doc """
  Dispatch an inbound protobuf message against the current state.
  """
  @spec step(ConnectionState.t(), struct()) :: result()
  def step(state, message)

  def step(state, %Proto.HelloRequest{} = req) do
    response = %Proto.HelloResponse{
      api_version_major: DeviceConfig.api_version_major(),
      api_version_minor: DeviceConfig.api_version_minor(),
      server_info: DeviceConfig.server_info(state.device_config),
      name: state.device_config.name
    }

    {state, [{:log, :info, "hello from #{state.peer} (client_info=#{inspect(req.client_info)})"}, {:send, response}]}
  end

  def step(state, %Proto.AuthenticationRequest{}) do
    {state, [{:send, %Proto.AuthenticationResponse{invalid_password: false}}]}
  end

  def step(state, %Proto.PingRequest{}) do
    {state, [{:send, %Proto.PingResponse{}}]}
  end

  def step(state, %Proto.DeviceInfoRequest{}) do
    serial_protos = Enum.map(state.serial_proxies, &SerialProxy.Info.to_proto/1)
    response = DeviceConfig.to_device_info_response(state.device_config, serial_protos)
    {state, [{:send, response}]}
  end

  def step(state, %Proto.ListEntitiesRequest{}) do
    ir_effects =
      state.infrared_entities
      |> Enum.map(&InfraredProxy.Entity.to_proto/1)
      |> Enum.map(&{:send, &1})

    custom_effects = Enum.map(state.entities, &{:send, &1})

    {state, ir_effects ++ custom_effects ++ [{:send, %Proto.ListEntitiesDoneResponse{}}]}
  end

  def step(state, %Proto.SubscribeStatesRequest{}) do
    initial_state_effects =
      case ConnectionState.adapter(state, :entity_provider) do
        nil -> []
        module -> Enum.map(module.initial_states(), &{:send, &1})
      end

    {subscribe_effects, state} =
      if ConnectionState.adapter?(state, :infrared_proxy) and not state.infrared_subscribed do
        {[:infrared_subscribe], ConnectionState.put_infrared_subscribed(state, true)}
      else
        {[], state}
      end

    {state, initial_state_effects ++ subscribe_effects}
  end

  def step(state, %Proto.SubscribeLogsRequest{} = req) do
    {state, [{:log, :debug, "#{state.peer} subscribed to logs (level=#{req.level})"}]}
  end

  def step(state, %Proto.SubscribeHomeassistantServicesRequest{}) do
    {state, [{:log, :debug, "#{state.peer} subscribed to HA services"}]}
  end

  def step(state, %Proto.SubscribeHomeAssistantStatesRequest{}) do
    {state, [{:log, :debug, "#{state.peer} subscribed to HA states"}]}
  end

  def step(state, %Proto.DisconnectRequest{}) do
    {state,
     [
       {:log, :info, "#{state.peer} requested disconnect"},
       {:send, %Proto.DisconnectResponse{}},
       {:close, :disconnect_requested}
     ]}
  end

  def step(state, %Proto.GetTimeRequest{}) do
    epoch = state.clock_fun.() |> Bitwise.band(0xFFFFFFFF)
    {state, [{:send, %Proto.GetTimeResponse{epoch_seconds: epoch}}]}
  end

  # -- Serial Proxy --

  def step(state, %Proto.SerialProxyConfigureRequest{} = req) do
    case ConnectionState.find_serial_proxy(state, req.instance) do
      nil ->
        {state, [{:log, :warning, "serial proxy configure for unknown instance #{req.instance}"}]}

      _info ->
        opts = SerialProxy.configure_request_to_open_opts(req)
        close_effects =
          case ConnectionState.port_handle(state, req.instance) do
            {:ok, _h} -> [{:serial_close, req.instance}]
            :error -> []
          end

        {state, close_effects ++ [{:serial_open, req.instance, opts}]}
    end
  end

  def step(state, %Proto.SerialProxyWriteRequest{} = req) do
    case ConnectionState.port_handle(state, req.instance) do
      {:ok, _handle} ->
        {state, [{:serial_write, req.instance, req.data}]}

      :error ->
        {state, [{:log, :warning, "serial proxy write for unopened instance #{req.instance}"}]}
    end
  end

  def step(state, %Proto.SerialProxySetModemPinsRequest{} = req) do
    case ConnectionState.port_handle(state, req.instance) do
      {:ok, _h} -> {state, [{:serial_modem_pins_set, req.instance, req.rts, req.dtr}]}
      :error -> {state, [{:log, :warning, "set_modem_pins for unopened instance #{req.instance}"}]}
    end
  end

  def step(state, %Proto.SerialProxyGetModemPinsRequest{} = req) do
    case ConnectionState.port_handle(state, req.instance) do
      {:ok, _h} ->
        {state, [{:serial_modem_pins_get, req.instance}]}

      :error ->
        response = %Proto.SerialProxyGetModemPinsResponse{instance: req.instance, rts: false, dtr: false}
        {state, [{:log, :warning, "get_modem_pins for unopened instance #{req.instance}"}, {:send, response}]}
    end
  end

  def step(state, %Proto.SerialProxyRequest{} = req) do
    {state, [{:log, :debug, "serial proxy request instance #{req.instance} type #{inspect(req.type)}"}]}
  end

  # -- Infrared Proxy --

  def step(state, %Proto.InfraredRFTransmitRawTimingsRequest{} = req) do
    if ConnectionState.adapter?(state, :infrared_proxy) do
      opts = [
        carrier_frequency: if(req.carrier_frequency > 0, do: req.carrier_frequency, else: 38_000),
        repeat_count: if(req.repeat_count > 0, do: req.repeat_count, else: 1)
      ]

      {sub_effects, state} =
        if state.infrared_subscribed do
          {[], state}
        else
          {[:infrared_subscribe], ConnectionState.put_infrared_subscribed(state, true)}
        end

      {state, sub_effects ++ [{:infrared_transmit, req.key, req.timings, opts}]}
    else
      {state, [{:log, :warning, "infrared transmit ignored — no adapter configured"}]}
    end
  end

  # -- Z-Wave Proxy --

  def step(state, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE}) do
    if ConnectionState.adapter?(state, :zwave_proxy) do
      {state, [:zwave_subscribe]}
    else
      {state, [{:log, :info, "Z-Wave subscribe ignored — no adapter configured"}]}
    end
  end

  def step(state, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE}) do
    if state.zwave_subscribed do
      {ConnectionState.put_zwave_subscribed(state, false), [:zwave_unsubscribe]}
    else
      {state, []}
    end
  end

  def step(state, %Proto.ZWaveProxyRequest{} = req) do
    {state, [{:log, :debug, "unhandled Z-Wave proxy request type: #{inspect(req.type)}"}]}
  end

  def step(state, %Proto.ZWaveProxyFrame{data: data}) do
    if ConnectionState.adapter?(state, :zwave_proxy) do
      {state, [{:zwave_send_frame, data}]}
    else
      {state, [{:log, :warning, "Z-Wave frame dropped — no adapter configured"}]}
    end
  end

  # -- Entity commands (routed to EntityProvider if configured) --

  def step(state, %type{} = message) when type in [
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
       ] do
    if ConnectionState.adapter?(state, :entity_provider) do
      {state, [{:entity_command, message}]}
    else
      {state, [{:log, :debug, "entity command #{inspect(type)} ignored — no adapter configured"}]}
    end
  end

  # -- Catch-all --

  def step(state, message) do
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
  # Response builders for effects that the handler resolves inline
  # (e.g. it performs an adapter call then needs to reply with a struct)
  # ---------------------------------------------------------------------------

  @doc """
  Build a `SerialProxyGetModemPinsResponse` from an adapter's return
  value. The handler calls this after resolving a
  `:serial_modem_pins_get` effect.
  """
  @spec modem_pins_response(non_neg_integer(), {:ok, %{rts: boolean(), dtr: boolean()}} | {:error, term()}) ::
          Proto.SerialProxyGetModemPinsResponse.t()
  def modem_pins_response(instance, {:ok, %{rts: rts, dtr: dtr}}) do
    %Proto.SerialProxyGetModemPinsResponse{instance: instance, rts: rts, dtr: dtr}
  end

  def modem_pins_response(instance, {:error, _reason}) do
    %Proto.SerialProxyGetModemPinsResponse{instance: instance, rts: false, dtr: false}
  end
end
