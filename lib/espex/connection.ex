defmodule Espex.Connection do
  @moduledoc """
  ThousandIsland handler for a single ESPHome Native API client connection.

  Each accepted TCP connection gets its own handler process. The handler
  is intentionally thin: it buffers incoming bytes, decodes frames via
  `Espex.Frame`, runs them through `Espex.Dispatch` (pure), and
  interprets the returned effects against this process's socket and the
  configured adapter modules.

  The handler captures a snapshot of the per-connection inventory
  (`serial_proxies`, `infrared_entities`, `entities`) at accept time and
  freezes it for the lifetime of the connection — ESPHome clients
  cache entity/proxy lists after the first `ListEntitiesRequest` /
  `DeviceInfoRequest` round, so silently changing them mid-connection
  would desync the client. A reconnect is required to pick up changes.
  """

  use ThousandIsland.Handler

  require Logger

  alias Espex.{ConnectionState, DeviceConfig, Dispatch, Frame, InfraredProxy, MessageTypes, Proto, Server, SerialProxy}

  @impl ThousandIsland.Handler
  def handle_connection(socket, handler_options) do
    server_name = Keyword.fetch!(handler_options, :server_name)
    registry_name = Keyword.fetch!(handler_options, :registry_name)
    server_state = Server.get_state(server_name)
    peer = peer_label(socket)
    adapters = server_state.adapters

    state =
      ConnectionState.new(
        device_config: device_config_for(server_state.device_config, adapters),
        peer: peer,
        adapters: adapters,
        serial_proxies: load_serial_proxies(adapters),
        infrared_entities: load_infrared_entities(adapters),
        entities: load_entities(adapters)
      )

    {:ok, _} = Registry.register(registry_name, :subscribers, nil)
    Logger.info("Espex client connected from #{peer}")
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    state = ConnectionState.append_buffer(state, data)

    case process_buffer(socket, state) do
      {:cont, state} ->
        {:continue, state}

      {:halt, _reason, state} ->
        cleanup(state)
        {:close, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    cleanup(state)
    Logger.info("Espex client #{state.peer} disconnected")
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    cleanup(state)
    Logger.warning("Espex client #{state.peer} connection error: #{inspect(reason)}")
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state) do
    cleanup(state)
    Logger.warning("Espex client #{state.peer} timed out")
    :ok
  end

  @impl GenServer
  def handle_info(event, {socket, state}) do
    {state, effects} = Dispatch.handle_event(state, event)

    case interpret_effects(socket, state, effects) do
      {:cont, state} ->
        {:noreply, {socket, state}}

      {:halt, reason, state} ->
        cleanup(state)
        {:stop, reason, {socket, state}}
    end
  end

  # --- Frame loop ---

  defp process_buffer(socket, state) do
    case Frame.decode_frame(state.buffer) do
      {:ok, type_id, payload, rest} ->
        state = ConnectionState.put_buffer(state, rest)
        handle_frame(socket, state, type_id, payload)

      {:incomplete, _} ->
        {:cont, state}

      {:error, reason} ->
        Logger.warning("Espex client #{state.peer} protocol error: #{inspect(reason)}")
        {:halt, {:protocol_error, reason}, state}
    end
  end

  defp handle_frame(socket, state, type_id, payload) do
    case MessageTypes.decode_message(type_id, payload) do
      {:ok, message} ->
        Logger.debug("Espex #{state.peer} recv #{inspect(message.__struct__)}")
        {state, effects} = Dispatch.step(state, message)

        case interpret_effects(socket, state, effects) do
          {:cont, state} -> process_buffer(socket, state)
          {:halt, _reason, _state} = halt -> halt
        end

      {:error, reason} ->
        Logger.warning("Espex client #{state.peer} decode error for type #{type_id}: #{inspect(reason)}")
        process_buffer(socket, state)
    end
  end

  # --- Effect interpreter ---

  defp interpret_effects(socket, state, effects) do
    Enum.reduce_while(effects, {:cont, state}, fn effect, {:cont, state} ->
      case interpret_effect(socket, state, effect) do
        {:cont, state} -> {:cont, {:cont, state}}
        {:halt, reason, state} -> {:halt, {:halt, reason, state}}
      end
    end)
  end

  defp interpret_effect(socket, state, {:send, message}) do
    send_message(socket, message)
    {:cont, state}
  end

  defp interpret_effect(_socket, state, {:close, reason}) do
    {:halt, reason, state}
  end

  defp interpret_effect(_socket, state, {:log, level, message}) do
    Logger.log(level, "Espex #{state.peer} #{message}")
    {:cont, state}
  end

  defp interpret_effect(_socket, state, {:serial_open, instance, opts}) do
    case state.adapters.serial_proxy.open(instance, opts, self()) do
      {:ok, handle} ->
        Logger.info("Espex #{state.peer} opened serial proxy instance #{instance}")
        {:cont, ConnectionState.put_port(state, instance, handle)}

      {:error, reason} ->
        Logger.warning("Espex #{state.peer} serial open instance #{instance} failed: #{inspect(reason)}")
        {:cont, state}
    end
  end

  defp interpret_effect(_socket, state, {:serial_write, instance, data}) do
    with {:ok, handle} <- ConnectionState.port_handle(state, instance),
         :ok <- state.adapters.serial_proxy.write(handle, data) do
      :ok
    else
      :error ->
        :ok

      {:error, reason} ->
        Logger.warning("Espex #{state.peer} serial write instance #{instance} failed: #{inspect(reason)}")
    end

    {:cont, state}
  end

  defp interpret_effect(_socket, state, {:serial_close, instance}) do
    case ConnectionState.drop_port(state, instance) do
      {new_state, nil} ->
        {:cont, new_state}

      {new_state, handle} ->
        state.adapters.serial_proxy.close(handle)
        {:cont, new_state}
    end
  end

  defp interpret_effect(_socket, state, {:serial_modem_pins_set, instance, rts, dtr}) do
    case ConnectionState.port_handle(state, instance) do
      {:ok, handle} -> state.adapters.serial_proxy.set_modem_pins(handle, rts, dtr)
      :error -> :ok
    end

    {:cont, state}
  end

  defp interpret_effect(socket, state, {:serial_modem_pins_get, instance}) do
    result =
      case ConnectionState.port_handle(state, instance) do
        {:ok, handle} -> state.adapters.serial_proxy.get_modem_pins(handle)
        :error -> {:error, :not_open}
      end

    send_message(socket, Dispatch.modem_pins_response(instance, result))
    {:cont, state}
  end

  defp interpret_effect(socket, state, :zwave_subscribe) do
    case state.adapters.zwave_proxy.subscribe(self()) do
      {:ok, home_id_bytes} ->
        state = ConnectionState.put_zwave_subscribed(state, true)
        maybe_send_initial_home_id(socket, home_id_bytes)
        {:cont, state}

      {:error, reason} ->
        Logger.warning("Espex #{state.peer} Z-Wave subscribe failed: #{inspect(reason)}")
        {:cont, state}
    end
  end

  defp interpret_effect(_socket, state, :zwave_unsubscribe) do
    if adapter = state.adapters.zwave_proxy, do: adapter.unsubscribe(self())
    {:cont, state}
  end

  defp interpret_effect(_socket, state, {:zwave_send_frame, data}) do
    case state.adapters.zwave_proxy.send_frame(data) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Espex #{state.peer} Z-Wave send_frame failed: #{inspect(reason)}")
    end

    {:cont, state}
  end

  defp interpret_effect(_socket, state, :infrared_subscribe) do
    state.adapters.infrared_proxy.subscribe(self())
    {:cont, state}
  end

  defp interpret_effect(_socket, state, :infrared_unsubscribe) do
    if adapter = state.adapters.infrared_proxy, do: adapter.unsubscribe(self())
    {:cont, state}
  end

  defp interpret_effect(_socket, state, {:infrared_transmit, key, timings, opts}) do
    case state.adapters.infrared_proxy.transmit_raw(key, timings, opts) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Espex #{state.peer} IR transmit failed: #{inspect(reason)}")
    end

    {:cont, state}
  end

  defp interpret_effect(_socket, state, {:entity_command, command}) do
    case state.adapters.entity_provider.handle_command(command) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Espex #{state.peer} entity command failed: #{inspect(reason)}")
    end

    {:cont, state}
  end

  # --- Helpers ---

  defp device_config_for(%DeviceConfig{} = base, adapters) do
    %{
      base
      | zwave_feature_flags: zwave_value(adapters, :feature_flags),
        zwave_home_id: zwave_value(adapters, :home_id)
    }
  end

  defp zwave_value(%{zwave_proxy: nil}, _fun), do: 0
  defp zwave_value(%{zwave_proxy: module}, fun), do: apply(module, fun, [])

  defp load_serial_proxies(%{serial_proxy: nil}), do: []
  defp load_serial_proxies(%{serial_proxy: module}), do: module.list_instances()

  defp load_infrared_entities(%{infrared_proxy: nil}), do: []
  defp load_infrared_entities(%{infrared_proxy: module}), do: module.list_entities()

  defp load_entities(%{entity_provider: nil}), do: []
  defp load_entities(%{entity_provider: module}), do: module.list_entities()

  defp send_message(socket, message) do
    Logger.debug("Espex send #{inspect(message.__struct__)}")

    case MessageTypes.encode_message(message) do
      {:ok, frame} ->
        ThousandIsland.Socket.send(socket, frame)

      {:error, reason} ->
        Logger.warning("Espex encode error: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_send_initial_home_id(_socket, <<0, 0, 0, 0>>), do: :ok

  defp maybe_send_initial_home_id(socket, home_id_bytes) do
    send_message(socket, %Proto.ZWaveProxyRequest{
      type: :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE,
      data: home_id_bytes
    })
  end

  defp cleanup(state) do
    if state.zwave_subscribed, do: interpret_effect(nil, state, :zwave_unsubscribe)
    if state.infrared_subscribed, do: interpret_effect(nil, state, :infrared_unsubscribe)

    if adapter = state.adapters.serial_proxy do
      Enum.each(state.opened_ports, fn {_instance, handle} -> adapter.close(handle) end)
    end

    :ok
  end

  defp peer_label(socket) do
    case ThousandIsland.Socket.peername(socket) do
      {:ok, {addr, port}} -> "#{:inet.ntoa(addr)}:#{port}"
      _ -> "unknown"
    end
  end

  @compile {:no_warn_undefined, [SerialProxy, InfraredProxy]}
end
