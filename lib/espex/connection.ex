defmodule Espex.Connection do
  @moduledoc """
  ThousandIsland handler for a single ESPHome Native API client connection.

  Each accepted TCP connection gets its own handler process. The handler
  is intentionally thin: it buffers incoming bytes, decodes frames via
  `Espex.Frame` or `Espex.Noise.Frame`, runs them through
  `Espex.Dispatch` (pure), and interprets the returned actions against
  this process's socket and the configured adapter modules.

  The handler captures a snapshot of the per-connection inventory
  (`serial_proxies`, `infrared_entities`, `entities`) at accept time and
  freezes it for the lifetime of the connection — ESPHome clients
  cache entity/proxy lists after the first `ListEntitiesRequest` /
  `DeviceInfoRequest` round, so silently changing them mid-connection
  would desync the client. A reconnect is required to pick up changes.

  ## Transport

  If `DeviceConfig.psk` is set, the handler expects the Noise-encrypted
  transport (`Noise_NNpsk0_25519_ChaChaPoly_SHA256`, ESPHome-framed per
  `Espex.Noise.Frame`). The handshake runs at connection start; if it
  fails or the client sends plaintext bytes, the connection is dropped.
  If no PSK is configured the handler operates in plaintext (preamble
  byte `0x00` + varint framing via `Espex.Frame`).
  """

  use ThousandIsland.Handler

  require Logger

  alias Espex.{
    ConnectionState,
    DeviceConfig,
    Dispatch,
    Frame,
    InfraredProxy,
    MessageTypes,
    Noise,
    Proto,
    Server,
    SerialProxy
  }

  @noise_prologue "NoiseAPIInit" <> <<0, 0>>
  @noise_proto_selector 0x01
  @noise_preamble 0x01
  @plaintext_indicator 0x00
  @handshake_status_ok 0x00
  @handshake_status_error 0x01

  @impl ThousandIsland.Handler
  def handle_connection(socket, handler_options) do
    server_name = Keyword.fetch!(handler_options, :server_name)
    registry_name = Keyword.fetch!(handler_options, :registry_name)
    server_state = Server.get_state(server_name)
    peer = peer_label(socket)
    adapters = server_state.adapters

    device_config = device_config_for(server_state.device_config, adapters)

    encryption =
      if DeviceConfig.encrypted?(device_config), do: :awaiting_hello, else: :disabled

    state =
      ConnectionState.new(
        device_config: device_config,
        peer: peer,
        adapters: adapters,
        serial_proxies: load_serial_proxies(adapters),
        infrared_entities: load_infrared_entities(adapters),
        entities: load_entities(adapters),
        encryption: encryption
      )

    {:ok, _} = Registry.register(registry_name, :subscribers, nil)
    Logger.info("Espex client connected from #{peer} (encryption=#{inspect(encryption)})")
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
    {state, actions} = Dispatch.handle_event(state, event)

    case interpret_actions(socket, state, actions) do
      {:cont, state} ->
        {:noreply, {socket, state}}

      {:halt, reason, state} ->
        cleanup(state)
        {:stop, reason, {socket, state}}
    end
  end

  # ---------------------------------------------------------------------------
  # process_buffer — per-encryption-state frame decoding
  # ---------------------------------------------------------------------------

  defp process_buffer(socket, %{encryption: :disabled} = state) do
    case Frame.decode_frame(state.buffer) do
      {:ok, type_id, payload, rest} ->
        state = ConnectionState.put_buffer(state, rest)
        handle_protobuf(socket, state, type_id, payload)

      other ->
        halt_on_frame_error(other, state, :protocol_error)
    end
  end

  # Plaintext client probing an encrypted server. Send a handshake
  # rejection frame (first byte 0x01) so aioesphomeapi raises
  # RequiresEncryptionAPIError — that's how Home Assistant's config
  # flow discovers it needs to prompt the user for the PSK.
  defp process_buffer(socket, %{encryption: :awaiting_hello, buffer: <<0x00, _::binary>>} = state) do
    send_handshake_rejection(socket, "Encryption required")
    Logger.info("Espex #{state.peer} plaintext probe on encrypted server — signalled encryption required")
    {:halt, :encryption_required, state}
  end

  defp process_buffer(socket, %{encryption: :awaiting_hello} = state) do
    case Noise.Frame.decode_outer(state.buffer) do
      {:ok, _hello_body, rest} ->
        state = ConnectionState.put_buffer(state, rest)
        on_server_hello(send_server_hello(socket, state), socket, state)

      other ->
        halt_on_frame_error(other, state, :noise_preamble)
    end
  end

  defp process_buffer(socket, %{encryption: {:awaiting_init, noise}} = state) do
    case Noise.Frame.decode_outer(state.buffer) do
      {:ok, body, rest} ->
        on_handshake_init(body, rest, socket, state, noise)

      other ->
        halt_on_frame_error(other, state, :noise_init)
    end
  end

  defp process_buffer(socket, %{encryption: {:active, _tx, rx}} = state) do
    case Noise.Frame.decode_outer(state.buffer) do
      {:ok, ciphertext, rest} ->
        state = ConnectionState.put_buffer(state, rest)

        rx
        |> Noise.decrypt(<<>>, ciphertext)
        |> on_decrypted(socket, state)

      other ->
        halt_on_frame_error(other, state, :noise_frame)
    end
  end

  defp halt_on_frame_error({:incomplete, _}, state, _tag), do: {:cont, state}

  defp halt_on_frame_error({:error, reason}, state, tag) do
    Logger.warning("Espex client #{state.peer} #{frame_error_label(tag)}: #{inspect(reason)}")
    {:halt, {tag, reason}, state}
  end

  defp frame_error_label(:protocol_error), do: "protocol error"
  defp frame_error_label(:noise_preamble), do: "Noise preamble error"
  defp frame_error_label(:noise_init), do: "Noise init decode error"
  defp frame_error_label(:noise_frame), do: "encrypted frame decode error"

  defp on_server_hello({:ok, noise}, socket, state) do
    state = ConnectionState.put_encryption(state, {:awaiting_init, noise})
    process_buffer(socket, state)
  end

  defp on_server_hello({:error, reason}, _socket, state) do
    {:halt, reason, state}
  end

  defp on_handshake_init(<<@handshake_status_ok, noise_msg::binary>>, rest, socket, state, noise) do
    state = ConnectionState.put_buffer(state, rest)
    complete_handshake(socket, state, noise, noise_msg)
  end

  defp on_handshake_init(<<>>, _rest, _socket, state, _noise) do
    Logger.warning("Espex client #{state.peer} empty handshake init frame")
    {:halt, :noise_empty_init, state}
  end

  defp on_handshake_init(<<other, _::binary>>, _rest, _socket, state, _noise) do
    Logger.warning("Espex client #{state.peer} unexpected handshake status byte #{other}")
    {:halt, {:noise_bad_status, other}, state}
  end

  defp on_decrypted({:ok, new_rx, inner}, socket, state) do
    state = advance_rx(state, new_rx)
    inner |> Noise.Frame.decode_inner() |> dispatch_inner(socket, state)
  end

  defp on_decrypted({:error, reason}, _socket, state) do
    Logger.warning("Espex client #{state.peer} noise decrypt failed: #{inspect(reason)}")
    {:halt, {:noise_decrypt, reason}, state}
  end

  defp dispatch_inner({:ok, type_id, payload}, socket, state) do
    handle_protobuf(socket, state, type_id, payload)
  end

  defp dispatch_inner({:error, reason}, socket, state) do
    Logger.warning("Espex client #{state.peer} inner frame decode error: #{inspect(reason)}")
    process_buffer(socket, state)
  end

  defp handle_protobuf(socket, state, type_id, payload) do
    case MessageTypes.decode_message(type_id, payload) do
      {:ok, message} ->
        Logger.debug("Espex #{state.peer} recv #{inspect(message.__struct__)}")
        {state, actions} = Dispatch.handle_request(state, message)

        case interpret_actions(socket, state, actions) do
          {:cont, state} -> process_buffer(socket, state)
          {:halt, _reason, _state} = halt -> halt
        end

      {:error, reason} ->
        Logger.warning("Espex client #{state.peer} decode error for type #{type_id}: #{inspect(reason)}")
        process_buffer(socket, state)
    end
  end

  # ---------------------------------------------------------------------------
  # Handshake helpers
  # ---------------------------------------------------------------------------

  defp send_server_hello(socket, state) do
    config = state.device_config
    body = <<@noise_proto_selector, config.name::binary, 0, config.mac_address::binary, 0>>
    :ok = ThousandIsland.Socket.send(socket, Noise.Frame.encode_outer(body))
    Noise.init(:responder, config.psk, @noise_prologue)
  end

  defp complete_handshake(socket, state, noise, client_msg) do
    with {:ok, noise, _payload} <- Noise.read_message(noise, client_msg),
         {:ok, noise, server_msg} <- Noise.write_message(noise, <<>>),
         {:ok, tx, rx} <- Noise.split(noise) do
      response = <<@handshake_status_ok, server_msg::binary>>
      :ok = ThousandIsland.Socket.send(socket, Noise.Frame.encode_outer(response))
      state = ConnectionState.put_encryption(state, {:active, tx, rx})
      Logger.info("Espex client #{state.peer} Noise handshake complete")
      process_buffer(socket, state)
    else
      {:error, reason} ->
        Logger.warning("Espex client #{state.peer} handshake failed: #{inspect(reason)}")
        send_handshake_rejection(socket, rejection_message(reason))
        {:halt, {:noise_handshake, reason}, state}
    end
  end

  # Send a handshake rejection frame, matching
  # https://developers.esphome.io/architecture/api/protocol_details/#handshake-rejection-format
  # Body: <0x01 error_flag><error_message_bytes>
  # Wrapped in the standard outer frame (preamble 0x01 + big-endian size).
  defp send_handshake_rejection(socket, message) when is_binary(message) do
    body = <<@handshake_status_error, message::binary>>
    _ = ThousandIsland.Socket.send(socket, Noise.Frame.encode_outer(body))
    :ok
  end

  defp rejection_message(:auth_failed), do: "Handshake MAC failure"
  defp rejection_message(:wrong_step_or_bad_message), do: "Bad handshake packet len"
  defp rejection_message(:handshake_incomplete), do: "Handshake error"
  defp rejection_message(reason), do: "Handshake error: #{inspect(reason)}"

  # ---------------------------------------------------------------------------
  # Effect interpreter
  # ---------------------------------------------------------------------------

  defp interpret_actions(socket, state, actions) do
    Enum.reduce_while(actions, {:cont, state}, fn action, {:cont, state} ->
      case interpret_action(socket, state, action) do
        {:cont, state} -> {:cont, {:cont, state}}
        {:halt, reason, state} -> {:halt, {:halt, reason, state}}
      end
    end)
  end

  defp interpret_action(socket, state, {:send, message}) do
    case send_protobuf(socket, state, message) do
      {:ok, state} -> {:cont, state}
      {:error, reason} -> {:halt, reason, state}
    end
  end

  defp interpret_action(_socket, state, {:close, reason}) do
    {:halt, reason, state}
  end

  defp interpret_action(_socket, state, {:log, level, message}) do
    Logger.log(level, "Espex #{state.peer} #{message}")
    {:cont, state}
  end

  defp interpret_action(_socket, state, {:serial_open, instance, opts}) do
    case state.adapters.serial_proxy.open(instance, opts, self()) do
      {:ok, handle} ->
        Logger.info("Espex #{state.peer} opened serial proxy instance #{instance}")
        {:cont, ConnectionState.put_port(state, instance, handle)}

      {:error, reason} ->
        Logger.warning("Espex #{state.peer} serial open instance #{instance} failed: #{inspect(reason)}")
        {:cont, state}
    end
  end

  defp interpret_action(_socket, state, {:serial_write, instance, data}) do
    state
    |> ConnectionState.port_handle(instance)
    |> write_port(state.adapters.serial_proxy, data)
    |> log_adapter_error(state.peer, "serial write instance #{instance}")

    {:cont, state}
  end

  defp interpret_action(_socket, state, {:serial_close, instance}) do
    case ConnectionState.drop_port(state, instance) do
      {new_state, nil} ->
        {:cont, new_state}

      {new_state, handle} ->
        state.adapters.serial_proxy.close(handle)
        {:cont, new_state}
    end
  end

  defp interpret_action(_socket, state, {:serial_modem_pins_set, instance, rts, dtr}) do
    state
    |> ConnectionState.port_handle(instance)
    |> set_modem_pins(state.adapters.serial_proxy, rts, dtr)

    {:cont, state}
  end

  defp interpret_action(socket, state, {:serial_modem_pins_get, instance}) do
    result =
      state
      |> ConnectionState.port_handle(instance)
      |> get_modem_pins(state.adapters.serial_proxy)

    case send_protobuf(socket, state, Dispatch.modem_pins_response(instance, result)) do
      {:ok, state} -> {:cont, state}
      {:error, reason} -> {:halt, reason, state}
    end
  end

  defp interpret_action(socket, state, {:serial_request, instance, type}) do
    result =
      state
      |> ConnectionState.port_handle(instance)
      |> serial_request(state.adapters.serial_proxy, type)

    case send_protobuf(socket, state, Dispatch.serial_request_response(instance, type, result)) do
      {:ok, state} -> {:cont, state}
      {:error, reason} -> {:halt, reason, state}
    end
  end

  defp interpret_action(socket, state, :zwave_subscribe) do
    case state.adapters.zwave_proxy.subscribe(self()) do
      {:ok, home_id_bytes} ->
        state = ConnectionState.put_zwave_subscribed(state, true)
        maybe_send_initial_home_id(socket, state, home_id_bytes)

      {:error, reason} ->
        Logger.warning("Espex #{state.peer} Z-Wave subscribe failed: #{inspect(reason)}")
        {:cont, state}
    end
  end

  defp interpret_action(_socket, state, :zwave_unsubscribe) do
    if adapter = state.adapters.zwave_proxy, do: adapter.unsubscribe(self())
    {:cont, state}
  end

  defp interpret_action(_socket, state, {:zwave_send_frame, data}) do
    state.adapters.zwave_proxy.send_frame(data)
    |> log_adapter_error(state.peer, "Z-Wave send_frame")

    {:cont, state}
  end

  defp interpret_action(_socket, state, :infrared_subscribe) do
    state.adapters.infrared_proxy.subscribe(self())
    {:cont, state}
  end

  defp interpret_action(_socket, state, :infrared_unsubscribe) do
    if adapter = state.adapters.infrared_proxy, do: adapter.unsubscribe(self())
    {:cont, state}
  end

  defp interpret_action(_socket, state, {:infrared_transmit, key, timings, opts}) do
    state.adapters.infrared_proxy.transmit_raw(key, timings, opts)
    |> log_adapter_error(state.peer, "IR transmit")

    {:cont, state}
  end

  defp interpret_action(_socket, state, {:entity_command, command}) do
    state.adapters.entity_provider.handle_command(command)
    |> log_adapter_error(state.peer, "entity command")

    {:cont, state}
  end

  # ---------------------------------------------------------------------------
  # Sending
  # ---------------------------------------------------------------------------

  defp send_protobuf(socket, %{encryption: :disabled} = state, message) do
    Logger.debug("Espex send #{inspect(message.__struct__)}")

    case MessageTypes.encode_parts(message) do
      {:ok, type_id, payload} ->
        # Build the plaintext frame as an iolist so gen_tcp.send sees all
        # four segments without a preceding concat of (indicator + varints +
        # payload) into a single binary.
        frame = [
          <<@plaintext_indicator>>,
          Frame.encode_varint(byte_size(payload)),
          Frame.encode_varint(type_id),
          payload
        ]

        :ok = ThousandIsland.Socket.send(socket, frame)
        {:ok, state}

      {:error, reason} ->
        Logger.warning("Espex encode error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_protobuf(socket, %{encryption: {:active, tx, rx}} = state, message) do
    Logger.debug("Espex send #{inspect(message.__struct__)} (encrypted)")

    case MessageTypes.encode_parts(message) do
      {:ok, type_id, payload} ->
        # The AEAD "plaintext" is the ESPHome inner frame (type + length +
        # protobuf). Hand it to Noise.encrypt as an iolist — crypto_one_time_aead
        # accepts iodata, so we skip concatenating the inner frame header
        # to the protobuf payload.
        inner = [
          <<type_id::unsigned-big-16, byte_size(payload)::unsigned-big-16>>,
          payload
        ]

        {:ok, new_tx, ciphertext} = Noise.encrypt(tx, <<>>, inner)

        # Outer frame as iolist: 3-byte header references the ciphertext
        # without copying. gen_tcp.send walks the iolist directly.
        frame = [<<@noise_preamble, byte_size(ciphertext)::unsigned-big-16>>, ciphertext]

        :ok = ThousandIsland.Socket.send(socket, frame)
        {:ok, ConnectionState.put_encryption(state, {:active, new_tx, rx})}

      {:error, reason} ->
        Logger.warning("Espex encode error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_protobuf(_socket, state, message) do
    Logger.warning(
      "Espex send attempted in wrong state: #{inspect(state.encryption)}; dropped #{inspect(message.__struct__)}"
    )

    {:ok, state}
  end

  defp maybe_send_initial_home_id(_socket, state, <<0, 0, 0, 0>>), do: {:cont, state}

  defp maybe_send_initial_home_id(socket, state, home_id_bytes) do
    case send_protobuf(socket, state, %Proto.ZWaveProxyRequest{
           type: :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE,
           data: home_id_bytes
         }) do
      {:ok, state} -> {:cont, state}
      {:error, reason} -> {:halt, reason, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp advance_rx(%{encryption: {:active, tx, _}} = state, new_rx) do
    ConnectionState.put_encryption(state, {:active, tx, new_rx})
  end

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

  defp cleanup(state) do
    if state.zwave_subscribed, do: interpret_action(nil, state, :zwave_unsubscribe)
    if state.infrared_subscribed, do: interpret_action(nil, state, :infrared_unsubscribe)

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

  # Pattern-matched helpers used by interpret_action/3 above.

  defp log_adapter_error(:ok, _peer, _what), do: :ok

  defp log_adapter_error({:error, reason}, peer, what) do
    Logger.warning("Espex #{peer} #{what} failed: #{inspect(reason)}")
  end

  defp write_port({:ok, handle}, adapter, data), do: adapter.write(handle, data)
  defp write_port(:error, _adapter, _data), do: :ok

  defp set_modem_pins({:ok, handle}, adapter, rts, dtr), do: adapter.set_modem_pins(handle, rts, dtr)
  defp set_modem_pins(:error, _adapter, _rts, _dtr), do: :ok

  defp get_modem_pins({:ok, handle}, adapter), do: adapter.get_modem_pins(handle)
  defp get_modem_pins(:error, _adapter), do: {:error, :not_open}

  defp serial_request({:ok, handle}, adapter, type) do
    if function_exported?(adapter, :request, 2) do
      adapter.request(handle, type)
    else
      {:ok, :not_supported}
    end
  end

  defp serial_request(:error, _adapter, _type), do: {:error, :not_open}

  @compile {:no_warn_undefined, [SerialProxy, InfraredProxy]}
end
