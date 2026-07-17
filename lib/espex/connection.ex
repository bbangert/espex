defmodule Espex.Connection do
  @moduledoc false

  use ThousandIsland.Handler

  require Logger

  alias Espex.{
    BluetoothProxy,
    ClientInfo,
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
    client_registry = Keyword.fetch!(handler_options, :client_registry)
    server_state = Server.get_state(server_name)
    peer = peer_label(socket)
    adapters = server_state.adapters

    device_config = device_config_for(server_state.device_config, adapters)

    encryption =
      if DeviceConfig.encrypted?(device_config), do: :awaiting_hello, else: :disabled

    now = now()

    state =
      ConnectionState.new(
        device_config: device_config,
        peer: peer,
        server_name: server_name,
        client_registry: client_registry,
        adapters: adapters,
        serial_proxies: load_serial_proxies(adapters),
        infrared_entities: load_infrared_entities(adapters),
        entities: load_entities(adapters),
        encryption: encryption,
        connected_at: now,
        last_activity_at: now,
        keepalive_idle_ms: Keyword.get(handler_options, :keepalive_idle_ms, 60_000),
        keepalive_grace_ms: Keyword.get(handler_options, :keepalive_grace_ms, 60_000)
      )

    # Duplicate-key entry for push_state/2 fan-out (value unused).
    {:ok, _} = Registry.register(registry_name, :subscribers, nil)

    # Unique-key entry holding this connection's ClientInfo snapshot so
    # connected_clients/1 is a plain Registry read. The connect-time
    # snapshot has no client_info yet; the :client_connected action
    # refreshes it after hello, and each inbound frame refreshes activity.
    {:ok, _} = Registry.register(client_registry, self(), ClientInfo.new(self(), state))
    Logger.info("Espex client connected from #{peer} (encryption=#{inspect(encryption)})")
    {:continue, reset_keepalive(state)}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    # Any inbound bytes prove the client is alive — restart the keepalive
    # idle clock, forget an outstanding ping, and stamp the activity time.
    prev_activity = state.last_activity_at

    state =
      state
      |> reset_keepalive()
      |> ConnectionState.touch_activity(now())
      |> ConnectionState.append_buffer(data)

    case process_buffer(socket, state) do
      {:cont, state} ->
        # Refresh the Registry snapshot only when the (second-resolution)
        # activity stamp actually advanced — within the same second the
        # snapshot is identical, so skip the write. A post-hello
        # client_info refresh happens in the :client_connected action
        # regardless. Activity alone never notifies the listener.
        if state.last_activity_at != prev_activity, do: sync_client_info(state)
        {:continue, state}

      {:halt, _reason, state} ->
        cleanup(state)
        {:close, state}
    end
  end

  # ThousandIsland's terminate/2 dispatches to exactly ONE of these per
  # connection, so notifying the connection_listener here fires exactly
  # once on disconnect. (cleanup/1 can run twice on the {:close} path, so
  # the notify must NOT live there.)
  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    cleanup(state)
    notify_disconnected(state)
    Logger.info("Espex client #{state.peer} disconnected")
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    cleanup(state)
    notify_disconnected(state)
    Logger.warning("Espex client #{state.peer} connection error: #{inspect(reason)}")
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state) do
    cleanup(state)
    notify_disconnected(state)
    Logger.warning("Espex client #{state.peer} timed out")
    :ok
  end

  # Graceful shutdown of the connection process (terminate reason
  # `:shutdown`) routes here, not to handle_close — so notify here too,
  # keeping disconnect notification exactly-once across every teardown
  # path. (Typically the whole tree is stopping and the listener is going
  # down too; reconcile-on-boot covers that, but completeness is cheap.)
  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state) do
    cleanup(state)
    notify_disconnected(state)
    :ok
  end

  # Device-initiated keepalive tick. aioesphomeapi only sends its own pings
  # when it is NOT receiving data, so on a busy device (BLE advert stream)
  # the inbound side of a healthy connection is permanently silent — without
  # this, any inbound read timeout kills perfectly good connections (observed
  # as Home Assistant reconnecting on an exact 60 s cycle). Mirror real
  # ESPHome firmware instead: ping the client after `keepalive_idle_ms` of
  # inbound silence, and close only if `keepalive_grace_ms` more passes
  # without any inbound bytes (clients answer PingRequest immediately).
  @impl GenServer
  def handle_info(:espex_keepalive, {socket, state}) do
    cond do
      state.keepalive_outstanding ->
        cleanup(state)
        Logger.warning("Espex client #{state.peer} keepalive ping unanswered — closing")
        {:stop, {:shutdown, :keepalive_timeout}, {socket, state}}

      # Mid-handshake (:awaiting_hello / {:awaiting_init, _}) send_protobuf
      # drops the frame but still reports {:ok, state}; marking it "outstanding"
      # would close the connection a grace period later for a ping the client
      # never received. Re-arm the idle clock and let read_timeout backstop a
      # stalled handshake instead.
      not keepalive_sendable?(state) ->
        {:noreply, {socket, reset_keepalive(state)}}

      true ->
        case send_protobuf(socket, state, %Proto.PingRequest{}) do
          {:ok, state} ->
            state = arm_keepalive(%{state | keepalive_outstanding: true}, state.keepalive_grace_ms)
            {:noreply, {socket, state}}

          {:error, reason} ->
            cleanup(state)
            {:stop, {:shutdown, {:keepalive_send_failed, reason}}, {socket, state}}
        end
    end
  end

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

  # Restart the idle clock: cancel any pending tick, clear an outstanding
  # ping, and arm a fresh idle timer. A cancel/fire race only yields a
  # premature ping (benign — the client answers and the clock resets).
  defp reset_keepalive(state) do
    arm_keepalive(%{state | keepalive_outstanding: false}, state.keepalive_idle_ms)
  end

  defp arm_keepalive(state, ms) do
    if state.keepalive_timer, do: Process.cancel_timer(state.keepalive_timer)
    %{state | keepalive_timer: Process.send_after(self(), :espex_keepalive, ms)}
  end

  # A PingRequest can only be transmitted once the channel is established;
  # these mirror the two send_protobuf/3 clauses that actually emit a frame.
  defp keepalive_sendable?(%{encryption: :disabled}), do: true
  defp keepalive_sendable?(%{encryption: {:active, _, _}}), do: true
  defp keepalive_sendable?(_), do: false

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
    adapter = state.adapters.serial_proxy
    resolved_opts = resolve_open_opts(adapter, instance, opts)

    case adapter.open(instance, resolved_opts, self()) do
      {:ok, handle} ->
        Logger.info("Espex #{state.peer} opened serial proxy instance #{instance}")
        state = ConnectionState.put_port(state, instance, handle)

        if ConnectionState.serial_subscribed?(state, instance) do
          case serial_request({:ok, handle}, adapter, :subscribe) do
            {:error, reason} ->
              Logger.warning("Espex #{state.peer} serial resubscribe instance #{instance} failed: #{inspect(reason)}")

            _ ->
              :ok
          end
        end

        {:cont, state}

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

  defp interpret_action(_socket, state, :ble_scanner_subscribe) do
    state.adapters.bluetooth_scanner.subscribe(self())
    |> log_adapter_error(state.peer, "BLE scanner subscribe")

    {:cont, state}
  end

  defp interpret_action(_socket, state, :ble_scanner_unsubscribe) do
    if adapter = state.adapters.bluetooth_scanner, do: adapter.unsubscribe(self())
    {:cont, state}
  end

  defp interpret_action(_socket, state, {:ble_scanner_set_mode, mode}) do
    adapter = state.adapters.bluetooth_scanner

    if function_exported?(adapter, :set_scanner_mode, 1) do
      adapter.set_scanner_mode(mode)
      |> log_adapter_error(state.peer, "BLE scanner set_scanner_mode")
    else
      Logger.debug(
        "Espex #{state.peer} BLE scanner set_scanner_mode #{inspect(mode)} ignored — not supported by adapter"
      )
    end

    {:cont, state}
  end

  defp interpret_action(socket, state, {:ble_connect, address, opts}) do
    case Server.claim_ble_owner(state.server_name, address, self()) do
      :ok ->
        ble_connect_after_claim(socket, state, address, opts)

      {:busy, _other_pid} ->
        response = %Proto.BluetoothDeviceConnectionResponse{
          address: address,
          connected: false,
          mtu: 0,
          error: BluetoothProxy.ErrorCodes.busy()
        }

        send_or_halt(socket, state, response)
    end
  end

  defp interpret_action(socket, state, {:ble_disconnect, address}) do
    if ConnectionState.bluetooth_owns?(state, address) do
      adapter = state.adapters.bluetooth_proxy
      adapter.disconnect(address) |> log_adapter_error(state.peer, "BLE disconnect")
      state = ConnectionState.drop_bluetooth_owned(state, address)
      _ = Server.release_ble_owner(state.server_name, address, self())
      maybe_push_connections_free(socket, state)
    else
      Logger.debug("Espex #{state.peer} BLE disconnect #{inspect(address)} ignored — not owner")
      {:cont, state}
    end
  end

  defp interpret_action(_socket, state, {:ble_release_ownership, address}) do
    # Emitted by Dispatch on a failed-connect event so the Server side
    # of the ownership record matches the per-connection state, which
    # has already dropped the address. Without this, a failed CONNECT
    # would leave the address permanently busy for other clients.
    _ = Server.release_ble_owner(state.server_name, address, self())
    {:cont, state}
  end

  defp interpret_action(socket, state, {:ble_pair, address}) do
    adapter = state.adapters.bluetooth_proxy

    if ble_optional?(adapter, :pair, 1) do
      adapter.pair(address) |> log_adapter_error(state.peer, "BLE pair")
      {:cont, state}
    else
      send_or_halt(socket, state, %Proto.BluetoothDevicePairingResponse{
        address: address,
        paired: false,
        error: BluetoothProxy.ErrorCodes.not_supported()
      })
    end
  end

  defp interpret_action(socket, state, {:ble_unpair, address}) do
    adapter = state.adapters.bluetooth_proxy

    if ble_optional?(adapter, :unpair, 1) do
      adapter.unpair(address) |> log_adapter_error(state.peer, "BLE unpair")
      {:cont, state}
    else
      send_or_halt(socket, state, %Proto.BluetoothDeviceUnpairingResponse{
        address: address,
        success: false,
        error: BluetoothProxy.ErrorCodes.not_supported()
      })
    end
  end

  defp interpret_action(socket, state, {:ble_clear_cache, address}) do
    adapter = state.adapters.bluetooth_proxy

    if ble_optional?(adapter, :clear_cache, 1) do
      adapter.clear_cache(address) |> log_adapter_error(state.peer, "BLE clear_cache")
      {:cont, state}
    else
      send_or_halt(socket, state, %Proto.BluetoothDeviceClearCacheResponse{
        address: address,
        success: false,
        error: BluetoothProxy.ErrorCodes.not_supported()
      })
    end
  end

  defp interpret_action(socket, state, {:ble_set_connection_params, address, params}) do
    adapter = state.adapters.bluetooth_proxy

    if ble_optional?(adapter, :set_connection_params, 2) do
      adapter.set_connection_params(address, params)
      |> log_adapter_error(state.peer, "BLE set_connection_params")

      {:cont, state}
    else
      send_or_halt(socket, state, %Proto.BluetoothSetConnectionParamsResponse{
        address: address,
        error: BluetoothProxy.ErrorCodes.not_supported()
      })
    end
  end

  defp interpret_action(socket, state, :ble_push_connections_free) do
    push_connections_free(socket, state)
  end

  defp interpret_action(socket, state, {:ble_gatt_get_services, address}) do
    if ConnectionState.bluetooth_owns?(state, address) do
      state.adapters.bluetooth_proxy.gatt_get_services(address)
      |> log_adapter_error(state.peer, "BLE gatt_get_services")

      {:cont, state}
    else
      gatt_not_connected(socket, state, address, 0)
    end
  end

  defp interpret_action(socket, state, {:ble_gatt_read, address, handle}) do
    if ConnectionState.bluetooth_owns?(state, address) do
      state.adapters.bluetooth_proxy.gatt_read(address, handle)
      |> log_adapter_error(state.peer, "BLE gatt_read")

      {:cont, state}
    else
      gatt_not_connected(socket, state, address, handle)
    end
  end

  defp interpret_action(socket, state, {:ble_gatt_write, address, handle, data, response?}) do
    if ConnectionState.bluetooth_owns?(state, address) do
      state.adapters.bluetooth_proxy.gatt_write(address, handle, data, response?)
      |> log_adapter_error(state.peer, "BLE gatt_write")

      {:cont, state}
    else
      gatt_not_connected(socket, state, address, handle)
    end
  end

  defp interpret_action(socket, state, {:ble_gatt_read_descriptor, address, handle}) do
    if ConnectionState.bluetooth_owns?(state, address) do
      state.adapters.bluetooth_proxy.gatt_read_descriptor(address, handle)
      |> log_adapter_error(state.peer, "BLE gatt_read_descriptor")

      {:cont, state}
    else
      gatt_not_connected(socket, state, address, handle)
    end
  end

  defp interpret_action(socket, state, {:ble_gatt_write_descriptor, address, handle, data}) do
    if ConnectionState.bluetooth_owns?(state, address) do
      state.adapters.bluetooth_proxy.gatt_write_descriptor(address, handle, data)
      |> log_adapter_error(state.peer, "BLE gatt_write_descriptor")

      {:cont, state}
    else
      gatt_not_connected(socket, state, address, handle)
    end
  end

  defp interpret_action(socket, state, {:ble_gatt_notify, address, handle, enable?}) do
    if ConnectionState.bluetooth_owns?(state, address) do
      state.adapters.bluetooth_proxy.gatt_notify(address, handle, enable?)
      |> log_adapter_error(state.peer, "BLE gatt_notify")

      {:cont, state}
    else
      gatt_not_connected(socket, state, address, handle)
    end
  end

  defp interpret_action(_socket, state, {:entity_command, command}) do
    state.adapters.entity_provider.handle_command(command)
    |> log_adapter_error(state.peer, "entity command")

    {:cont, state}
  end

  defp interpret_action(socket, state, {:set_psk, key}) do
    # Persist first (if a store is configured), then apply to the running
    # server. A store failure aborts the update and reports success:
    # false so a key is never applied that we couldn't durably record.
    # The new key takes effect on the NEXT connection; this live one is
    # untouched.
    with :ok <- store_psk(state, key),
         :ok <- Server.update_psk(state.server_name, key) do
      Logger.info("Espex #{state.peer} Noise PSK provisioned — effective on next connection")
      send_or_halt(socket, state, %Proto.NoiseEncryptionSetKeyResponse{success: true})
    else
      {:error, reason} ->
        Logger.warning("Espex #{state.peer} SetKey failed: #{inspect(reason)}")
        send_or_halt(socket, state, %Proto.NoiseEncryptionSetKeyResponse{success: false})
    end
  end

  defp interpret_action(socket, state, :client_connected) do
    # Hello completed — refresh the Registry snapshot (now carries
    # client_info/api_version) and tell the listener the set changed.
    sync_client_info(state)
    notify_connections_changed(state)
    # Mirror ESPHome's api_connection_authenticated: push the current
    # home ID to every client as it comes up, subscribed or not, so a
    # controller already present at connect is discovered without
    # waiting for a change event. Zero (no controller) is skipped by
    # maybe_send_initial_home_id.
    maybe_send_initial_home_id(socket, state, <<zwave_value(state.adapters, :home_id)::32>>)
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
        zwave_home_id: zwave_value(adapters, :home_id),
        bluetooth_feature_flags: compute_bluetooth_feature_flags(adapters)
    }
  end

  defp zwave_value(%{zwave_proxy: nil}, _fun), do: 0
  defp zwave_value(%{zwave_proxy: module}, fun), do: apply(module, fun, [])

  # ESPHome bluetooth_proxy_feature_flags bitfield.
  @bluetooth_passive_scan 0x01
  @bluetooth_active_connections 0x02
  @bluetooth_remote_caching 0x04
  @bluetooth_pairing 0x08
  @bluetooth_cache_clearing 0x10
  @bluetooth_raw_advertisements 0x20
  @bluetooth_state_and_mode 0x40

  defp compute_bluetooth_feature_flags(adapters) do
    Bitwise.bor(
      scanner_bits(adapters[:bluetooth_scanner]),
      active_bits(adapters[:bluetooth_proxy])
    )
  end

  defp scanner_bits(nil), do: 0

  defp scanner_bits(adapter) do
    base = Bitwise.bor(@bluetooth_passive_scan, @bluetooth_raw_advertisements)

    # `Code.ensure_loaded?/1` precedes `function_exported?/3` because
    # this check fires at TCP-accept time, before any adapter call has
    # auto-loaded the module. Without it, CI's fresh BEAM reports the
    # optional callback as missing even when it's defined.
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :set_scanner_mode, 1) do
      Bitwise.bor(base, @bluetooth_state_and_mode)
    else
      base
    end
  end

  defp active_bits(nil), do: 0

  defp active_bits(adapter) do
    loaded? = Code.ensure_loaded?(adapter)

    base = Bitwise.bor(@bluetooth_active_connections, @bluetooth_remote_caching)

    base
    |> maybe_set_bit(loaded? and pairing_exported?(adapter), @bluetooth_pairing)
    |> maybe_set_bit(
      loaded? and function_exported?(adapter, :clear_cache, 1),
      @bluetooth_cache_clearing
    )
  end

  defp pairing_exported?(adapter) do
    function_exported?(adapter, :pair, 1) and function_exported?(adapter, :unpair, 1)
  end

  defp maybe_set_bit(acc, true, bit), do: Bitwise.bor(acc, bit)
  defp maybe_set_bit(acc, false, _bit), do: acc

  defp load_serial_proxies(%{serial_proxy: nil}), do: []
  defp load_serial_proxies(%{serial_proxy: module}), do: module.list_instances()

  defp load_infrared_entities(%{infrared_proxy: nil}), do: []
  defp load_infrared_entities(%{infrared_proxy: module}), do: module.list_entities()

  defp load_entities(%{entity_provider: nil}), do: []
  defp load_entities(%{entity_provider: module}), do: module.list_entities()

  defp cleanup(state) do
    if state.zwave_subscribed, do: interpret_action(nil, state, :zwave_unsubscribe)
    if state.infrared_subscribed, do: interpret_action(nil, state, :infrared_unsubscribe)
    if state.bluetooth_scanner_subscribed, do: interpret_action(nil, state, :ble_scanner_unsubscribe)

    cleanup_bluetooth_owners(state)

    if adapter = state.adapters.serial_proxy do
      Enum.each(state.opened_ports, fn {_instance, handle} -> adapter.close(handle) end)
    end

    :ok
  end

  defp cleanup_bluetooth_owners(%{server_name: nil}), do: :ok

  defp cleanup_bluetooth_owners(state) do
    case state.adapters.bluetooth_proxy do
      nil ->
        :ok

      adapter ->
        # Release everything we own atomically on the Server, then ask
        # the adapter to disconnect. `release_all_ble_owners/2` returns
        # the addresses so we can disconnect even if the per-connection
        # MapSet has drifted (defence in depth — server is the truth).
        addresses = Server.release_all_ble_owners(state.server_name, self())

        Enum.each(addresses, fn address ->
          adapter.disconnect(address) |> log_adapter_error(state.peer, "BLE cleanup disconnect")
        end)

        :ok
    end
  end

  defp peer_label(socket) do
    case ThousandIsland.Socket.peername(socket) do
      {:ok, {addr, port}} -> "#{:inet.ntoa(addr)}:#{port}"
      _ -> "unknown"
    end
  end

  # Pattern-matched helpers used by interpret_action/3 above.

  # Persist a provisioned PSK through the configured store. With no
  # store, apply it anyway but warn — it won't survive a restart.
  defp store_psk(%{adapters: %{psk_store: nil}} = state, _key) do
    Logger.warning(
      "Espex #{state.peer} PSK provisioned with no :psk_store configured — applied to the running server only, lost on restart"
    )

    :ok
  end

  defp store_psk(%{adapters: %{psk_store: module}}, key) do
    module.store_psk(key)
  end

  defp now, do: System.system_time(:second)

  # Write this connection's current ClientInfo snapshot into its unique
  # Registry entry so connected_clients/1 reads fresh data. No-op when
  # there's no registry (pure-state paths / tests).
  defp sync_client_info(%{client_registry: nil}), do: :ok

  defp sync_client_info(%{client_registry: registry} = state) do
    case Registry.update_value(registry, self(), fn _ -> ClientInfo.new(self(), state) end) do
      {_new, _old} ->
        :ok

      :error ->
        # Entry already gone (shutdown race) — nothing to refresh.
        Logger.debug("Espex #{state.peer} client-info snapshot update skipped — registry entry gone")
        :ok
    end
  end

  # Disconnect notification — only for connections that completed hello
  # (api_version is set then), so connect/disconnect notifications stay
  # paired and a bare TCP open/close that never said hello is ignored.
  defp notify_disconnected(%{api_version: nil}), do: :ok
  defp notify_disconnected(state), do: notify_connections_changed(state)

  # Best-effort: a missing/slow/crashing listener must never stall or tear
  # down a live client connection, and we never retry — connected_clients/1
  # is the source of truth a listener reconciles against on its own boot.
  defp notify_connections_changed(%{adapters: %{connection_listener: nil}}), do: :ok

  defp notify_connections_changed(%{adapters: %{connection_listener: module}, peer: peer}) do
    # Run detached so a slow/blocking callback can't stall frame
    # processing, and catch every failure kind (error/exit/throw) so a
    # misbehaving listener can't bring the connection down. Notifications
    # are therefore unordered — fine, since each is only a "re-query" hint
    # and connected_clients/1 is authoritative.
    _ =
      spawn(fn ->
        try do
          module.connections_changed()
        catch
          kind, reason ->
            Logger.warning("Espex #{peer} connection_listener #{kind}: #{inspect(reason)}")
        end
      end)

    :ok
  end

  defp log_adapter_error(:ok, _peer, _what), do: :ok

  defp log_adapter_error({:error, reason}, peer, what) do
    Logger.warning("Espex #{peer} #{what} failed: #{inspect(reason)}")
  end

  defp write_port({:ok, handle}, adapter, data), do: adapter.write(handle, data)
  defp write_port(:error, _adapter, _data), do: :ok

  defp set_modem_pins({:ok, handle}, adapter, rts, dtr) do
    if function_exported?(adapter, :set_modem_pins, 3) do
      adapter.set_modem_pins(handle, rts, dtr)
    else
      :ok
    end
  end

  defp set_modem_pins(:error, _adapter, _rts, _dtr), do: :ok

  defp get_modem_pins({:ok, handle}, adapter) do
    if function_exported?(adapter, :get_modem_pins, 1) do
      adapter.get_modem_pins(handle)
    else
      {:error, :not_supported}
    end
  end

  defp get_modem_pins(:error, _adapter), do: {:error, :not_open}

  defp serial_request({:ok, handle}, adapter, type) do
    if function_exported?(adapter, :request, 2) do
      adapter.request(handle, type)
    else
      {:ok, :not_supported}
    end
  end

  defp serial_request(:error, _adapter, _type), do: {:error, :not_open}

  # Resolve a lazy :serial_open's :default_opts placeholder against the
  # adapter's own preferred settings, falling back to SerialProxy's
  # 9600-8-N-1 default when the adapter doesn't export
  # `default_open_opts/1`. A configure-driven open already carries
  # concrete opts and passes straight through.
  defp resolve_open_opts(adapter, instance, :default_opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :default_open_opts, 1) do
      adapter.default_open_opts(instance)
    else
      SerialProxy.default_open_opts()
    end
  end

  defp resolve_open_opts(_adapter, _instance, opts), do: opts

  # Optional-callback check. Pairs `Code.ensure_loaded?/1` with
  # `function_exported?/3` because BLE interpreter clauses can fire on
  # an adapter the BEAM hasn't auto-loaded yet (e.g. PAIR before any
  # CONNECT) — see scratchpad note from PR 3.
  defp ble_optional?(adapter, fun, arity) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, fun, arity)
  end

  # Non-owner GATT request — send the proto's error envelope rather
  # than calling the adapter. Used by every interpret_action GATT
  # clause when the address isn't in this connection's
  # `bluetooth_owned` set (i.e. a stale request, or a client
  # mis-routing).
  defp gatt_not_connected(socket, state, address, handle) do
    Logger.debug(
      "Espex #{state.peer} GATT request for unowned address #{inspect(address)} (handle #{handle}) — sending error envelope"
    )

    response = %Proto.BluetoothGATTErrorResponse{
      address: address,
      handle: handle,
      error: BluetoothProxy.ErrorCodes.not_connected()
    }

    send_or_halt(socket, state, response)
  end

  defp ble_connect_after_claim(socket, state, address, opts) do
    adapter = state.adapters.bluetooth_proxy
    state = ConnectionState.add_bluetooth_owned(state, address)

    case adapter.connect(address, opts, self()) do
      :ok ->
        # Async path. The eventual `{:espex_ble_connection, ...}` event
        # carries the success/failure reply; Dispatch.handle_event
        # appends :ble_push_connections_free when subscribed.
        {:cont, state}

      {:error, reason} ->
        # Adapter rejected the call synchronously — no event will come
        # back, so release ownership now and tell the client.
        Logger.warning("Espex #{state.peer} BLE connect failed sync: #{inspect(reason)}")
        state = ConnectionState.drop_bluetooth_owned(state, address)
        _ = Server.release_ble_owner(state.server_name, address, self())

        send_or_halt(socket, state, %Proto.BluetoothDeviceConnectionResponse{
          address: address,
          connected: false,
          mtu: 0,
          error: BluetoothProxy.ErrorCodes.generic_error()
        })
    end
  end

  # Send a protobuf and thread the encryption-advanced state forward.
  # On encode failure, halt so the connection is torn down — silently
  # dropping the result would leave the Noise tx counter ahead of the
  # wire and break every subsequent encrypted send. (Transport errors
  # bubble through `:ok = ThousandIsland.Socket.send/2` in
  # `send_protobuf/3` as a match failure; the handler crashes and
  # `terminate/2` runs `cleanup/1`. That's fine — the connection is
  # already dead.)
  defp send_or_halt(socket, state, message) do
    case send_protobuf(socket, state, message) do
      {:ok, state} -> {:cont, state}
      {:error, reason} -> {:halt, reason, state}
    end
  end

  defp push_connections_free(socket, state) do
    {free, limit} = state.adapters.bluetooth_proxy.connections_free()

    response = %Proto.BluetoothConnectionsFreeResponse{
      free: free,
      limit: limit,
      allocated: state.bluetooth_owned |> MapSet.to_list() |> Enum.sort()
    }

    send_or_halt(socket, state, response)
  end

  defp maybe_push_connections_free(socket, %{bluetooth_connections_free_subscribed: true} = state) do
    push_connections_free(socket, state)
  end

  defp maybe_push_connections_free(_socket, state), do: {:cont, state}

  @compile {:no_warn_undefined, [SerialProxy, InfraredProxy]}
end
