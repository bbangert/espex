defmodule Espex.BluetoothScannerIntegrationTest do
  use ExUnit.Case, async: false

  alias Espex.{Frame, MessageTypes, Proto}
  alias Espex.Test.{MinimalBluetoothScanner, TrackingBluetoothScanner}

  setup context do
    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    listener_key = {TrackingBluetoothScanner, context.test}
    :persistent_term.put(listener_key, self())

    opts =
      [
        name: sup_name,
        server_name: server_name,
        port: 0,
        device_config: [
          name: "ble-test",
          friendly_name: "BLE Test",
          project_name: "espex_test",
          project_version: "0.0.1"
        ]
      ] ++ Map.to_list(context[:adapters] || %{bluetooth_scanner: TrackingBluetoothScanner})

    {:ok, sup_pid} = Espex.start_link(opts)
    {:ok, port} = Espex.Supervisor.bound_port(sup_pid)

    on_exit(fn ->
      :persistent_term.erase(listener_key)

      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{port: port}
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true, packet: :raw])
    socket
  end

  defp send_struct(socket, struct) do
    {:ok, frame} = MessageTypes.encode_message(struct)
    :ok = :gen_tcp.send(socket, frame)
  end

  defp recv_struct(socket, buffer \\ <<>>, timeout \\ 1_000) do
    case Frame.decode_frame(buffer) do
      {:ok, type_id, payload, rest} ->
        {:ok, module} = MessageTypes.module_for_id(type_id)
        {:ok, module.decode(payload), rest}

      _ ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, data} -> recv_struct(socket, buffer <> data, timeout)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Hand-shake to get the per-connection handler pid: subscribe to ads,
  # wait for the adapter's `{:subscribe, pid}` notification.
  defp subscribe_and_capture_handler(socket) do
    send_struct(socket, %Proto.SubscribeBluetoothLEAdvertisementsRequest{})

    receive do
      {:subscribe, handler_pid} -> handler_pid
    after
      1_000 -> flunk("scanner adapter never received :subscribe — handler never invoked subscribe/1")
    end
  end

  describe "feature flags" do
    test "TrackingBluetoothScanner exports set_scanner_mode → STATE_AND_MODE bit set", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{} = info, _} = recv_struct(socket)

      # PASSIVE_SCAN (0x01) | RAW_ADVERTISEMENTS (0x20) | STATE_AND_MODE (0x40)
      assert info.bluetooth_proxy_feature_flags == 0x61
      :gen_tcp.close(socket)
    end

    @tag adapters: %{bluetooth_scanner: MinimalBluetoothScanner}
    test "MinimalBluetoothScanner has no set_scanner_mode → STATE_AND_MODE bit cleared", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{} = info, _} = recv_struct(socket)

      # PASSIVE_SCAN (0x01) | RAW_ADVERTISEMENTS (0x20), no STATE_AND_MODE
      assert info.bluetooth_proxy_feature_flags == 0x21
      :gen_tcp.close(socket)
    end

    @tag adapters: %{}
    test "no adapter configured → flags == 0", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{} = info, _} = recv_struct(socket)

      assert info.bluetooth_proxy_feature_flags == 0
      :gen_tcp.close(socket)
    end
  end

  describe "subscribe → advertisement → wire" do
    test "raw advertisement reaches client one-per-response", %{port: port} do
      socket = connect(port)
      handler_pid = subscribe_and_capture_handler(socket)

      # Adapter pushes an advertisement into the handler pid as it would
      # in production.
      send(
        handler_pid,
        {:espex_ble_advertisement, 0x1122_3344_5566, -42, 1, <<0x02, 0x01, 0x06>>}
      )

      {:ok, response, _} = recv_struct(socket)

      assert %Proto.BluetoothLERawAdvertisementsResponse{
               advertisements: [
                 %Proto.BluetoothLERawAdvertisement{
                   address: 0x1122_3344_5566,
                   rssi: -42,
                   address_type: 1,
                   data: <<0x02, 0x01, 0x06>>
                 }
               ]
             } = response

      :gen_tcp.close(socket)
    end
  end

  describe "scanner state events" do
    test "scanner_state push from adapter reaches client as BluetoothScannerStateResponse", %{
      port: port
    } do
      socket = connect(port)
      handler_pid = subscribe_and_capture_handler(socket)

      # Consume any prior responses (subscribe path emits none, but
      # be defensive).
      send(handler_pid, {:espex_ble_scanner_state, :running, :passive, :passive})
      {:ok, response, _} = recv_struct(socket)

      assert %Proto.BluetoothScannerStateResponse{
               state: :BLUETOOTH_SCANNER_STATE_RUNNING,
               mode: :BLUETOOTH_SCANNER_MODE_PASSIVE,
               configured_mode: :BLUETOOTH_SCANNER_MODE_PASSIVE
             } = response

      :gen_tcp.close(socket)
    end
  end

  describe "set_scanner_mode round-trip" do
    test "client BluetoothScannerSetModeRequest reaches adapter", %{port: port} do
      socket = connect(port)
      # Force one subscribe so we know the handler is running; not strictly
      # needed for set_scanner_mode but keeps the flow consistent.
      _handler_pid = subscribe_and_capture_handler(socket)

      send_struct(socket, %Proto.BluetoothScannerSetModeRequest{
        mode: :BLUETOOTH_SCANNER_MODE_ACTIVE
      })

      assert_receive {:set_scanner_mode, :active}, 1_000
      :gen_tcp.close(socket)
    end
  end

  describe "cleanup on TCP close" do
    test "closing the socket triggers adapter.unsubscribe/1", %{port: port} do
      socket = connect(port)
      handler_pid = subscribe_and_capture_handler(socket)

      :gen_tcp.close(socket)

      assert_receive {:unsubscribe, ^handler_pid}, 1_000
    end
  end
end
