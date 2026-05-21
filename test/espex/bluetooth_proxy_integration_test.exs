defmodule Espex.BluetoothProxyIntegrationTest do
  use ExUnit.Case, async: false

  alias Espex.{Frame, MessageTypes, Proto, Server}
  alias Espex.Test.{MinimalBluetoothProxy, TrackingBluetoothProxy}

  setup context do
    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    listener_key = {TrackingBluetoothProxy, context.test}
    :persistent_term.put(listener_key, self())

    opts =
      [
        name: sup_name,
        server_name: server_name,
        port: 0,
        device_config: [
          name: "ble-proxy-test",
          friendly_name: "BLE Proxy Test",
          project_name: "espex_test",
          project_version: "0.0.1"
        ]
      ] ++ Map.to_list(context[:adapters] || %{bluetooth_proxy: TrackingBluetoothProxy})

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

    %{port: port, server_name: server_name}
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

  defp issue_connect(socket, address) do
    send_struct(socket, %Proto.BluetoothDeviceRequest{
      request_type: :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT,
      address: address
    })
  end

  defp wait_until(check, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_until(check, deadline)
  end

  defp do_wait_until(check, deadline) do
    if check.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(5)
        do_wait_until(check, deadline)
      end
    end
  end

  describe "feature flags" do
    test "TrackingBluetoothProxy exports every optional → all four active bits set", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{} = info, _} = recv_struct(socket)

      # ACTIVE_CONNECTIONS (0x02) | REMOTE_CACHING (0x04) | PAIRING (0x08) | CACHE_CLEARING (0x10) = 0x1E
      assert info.bluetooth_proxy_feature_flags == 0x1E
      :gen_tcp.close(socket)
    end

    @tag adapters: %{bluetooth_proxy: MinimalBluetoothProxy}
    test "MinimalBluetoothProxy exports no optionals → only ACTIVE_CONNECTIONS | REMOTE_CACHING", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{} = info, _} = recv_struct(socket)

      assert info.bluetooth_proxy_feature_flags == 0x06
      :gen_tcp.close(socket)
    end
  end

  describe "connect lifecycle" do
    test "CONNECT claims ownership and forwards to adapter", %{port: port, server_name: server_name} do
      socket = connect(port)
      issue_connect(socket, 0xAABB)

      assert_receive {:connect, 0xAABB, _opts, handler_pid}, 1_000
      assert Server.ble_owner(server_name, 0xAABB) == handler_pid

      :gen_tcp.close(socket)
    end

    test "second client CONNECT on the same address returns busy without invoking adapter", %{port: port} do
      socket_a = connect(port)
      issue_connect(socket_a, 0xAABB)
      assert_receive {:connect, 0xAABB, _, _handler_a}, 1_000

      socket_b = connect(port)
      issue_connect(socket_b, 0xAABB)

      {:ok, response, _} = recv_struct(socket_b)

      assert %Proto.BluetoothDeviceConnectionResponse{
               address: 0xAABB,
               connected: false,
               error: -3
             } = response

      # Adapter must NOT see a second :connect call for the same address.
      refute_receive {:connect, 0xAABB, _, _}, 100

      :gen_tcp.close(socket_a)
      :gen_tcp.close(socket_b)
    end

    test "adapter success event {:espex_ble_connection, address, {:ok, mtu}} reaches client", %{port: port} do
      socket = connect(port)
      issue_connect(socket, 0xAABB)
      assert_receive {:connect, 0xAABB, _, handler_pid}, 1_000

      send(handler_pid, {:espex_ble_connection, 0xAABB, {:ok, 247}})
      {:ok, response, _} = recv_struct(socket)

      assert %Proto.BluetoothDeviceConnectionResponse{
               address: 0xAABB,
               connected: true,
               mtu: 247,
               error: 0
             } = response

      :gen_tcp.close(socket)
    end

    test "sync {:error, _} from adapter.connect releases ownership inline", %{
      port: port,
      server_name: server_name
    } do
      :persistent_term.put({TrackingBluetoothProxy, :fail_next_connect}, true)
      on_exit(fn -> :persistent_term.erase({TrackingBluetoothProxy, :fail_next_connect}) end)

      socket = connect(port)
      issue_connect(socket, 0xAABB)

      # Adapter notified, then rejected synchronously.
      assert_receive {:connect, 0xAABB, _, _handler}, 1_000

      {:ok, %Proto.BluetoothDeviceConnectionResponse{connected: false, error: -1}, _} =
        recv_struct(socket)

      # The handler's interpreter writes the wire response BEFORE calling
      # Server.release_ble_owner, so recv_struct can complete a hair
      # before the release lands. Poll for ownership to clear.
      wait_until(fn -> Server.ble_owner(server_name, 0xAABB) == nil end)
      :gen_tcp.close(socket)
    end

    test "failed connect releases ownership so a second client can claim the address", %{
      port: port,
      server_name: server_name
    } do
      socket_a = connect(port)
      issue_connect(socket_a, 0xAABB)
      assert_receive {:connect, 0xAABB, _, handler_a}, 1_000
      assert Server.ble_owner(server_name, 0xAABB) == handler_a

      # Adapter reports failure — espex must release the address so
      # another client isn't permanently locked out.
      send(handler_a, {:espex_ble_connection, 0xAABB, {:error, -1}})

      {:ok, %Proto.BluetoothDeviceConnectionResponse{connected: false, error: -1}, _} =
        recv_struct(socket_a)

      # Wait for handler_a to finish processing the action list
      # (send_response → release_ownership → maybe_push) before the
      # second client races on Server.claim_ble_owner.
      wait_until(fn -> Server.ble_owner(server_name, 0xAABB) == nil end)

      socket_b = connect(port)
      issue_connect(socket_b, 0xAABB)
      assert_receive {:connect, 0xAABB, _, handler_b}, 1_000
      refute handler_a == handler_b
      assert Server.ble_owner(server_name, 0xAABB) == handler_b

      :gen_tcp.close(socket_a)
      :gen_tcp.close(socket_b)
    end

    test "DISCONNECT releases ownership and forwards to adapter", %{port: port, server_name: server_name} do
      socket = connect(port)
      issue_connect(socket, 0xAABB)
      assert_receive {:connect, 0xAABB, _, _handler}, 1_000

      send_struct(socket, %Proto.BluetoothDeviceRequest{
        request_type: :BLUETOOTH_DEVICE_REQUEST_TYPE_DISCONNECT,
        address: 0xAABB
      })

      assert_receive {:disconnect, 0xAABB}, 1_000
      # Server.ble_owner is a sync call so by the time it returns, the
      # release has been processed.
      assert Server.ble_owner(server_name, 0xAABB) == nil

      :gen_tcp.close(socket)
    end
  end

  describe "cleanup on TCP close" do
    test "closing the socket disconnects owned addresses and releases ownership", %{
      port: port,
      server_name: server_name
    } do
      socket = connect(port)
      issue_connect(socket, 0xAABB)
      issue_connect(socket, 0xCCDD)
      assert_receive {:connect, 0xAABB, _, _handler}, 1_000
      assert_receive {:connect, 0xCCDD, _, _}, 1_000

      :gen_tcp.close(socket)

      # cleanup_bluetooth_owners/1 calls Server.release_all_ble_owners
      # BEFORE firing adapter.disconnect/1, so receiving both
      # :disconnect notifications already implies the release has
      # completed — no Process.sleep needed.
      assert_receive {:disconnect, 0xAABB}, 1_000
      assert_receive {:disconnect, 0xCCDD}, 1_000
      assert Server.ble_owner(server_name, 0xAABB) == nil
      assert Server.ble_owner(server_name, 0xCCDD) == nil
    end
  end

  describe "connections_free" do
    test "Subscribe pushes initial BluetoothConnectionsFreeResponse with adapter's {free, limit}", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.SubscribeBluetoothConnectionsFreeRequest{})

      {:ok, response, _} = recv_struct(socket)

      assert %Proto.BluetoothConnectionsFreeResponse{free: 3, limit: 3, allocated: []} = response
      :gen_tcp.close(socket)
    end

    test "Successful connect re-pushes connections_free with the new allocation", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.SubscribeBluetoothConnectionsFreeRequest{})
      {:ok, %Proto.BluetoothConnectionsFreeResponse{allocated: []}, buf} = recv_struct(socket)

      issue_connect(socket, 0xAABB)
      assert_receive {:connect, 0xAABB, _, handler_pid}, 1_000

      # Now simulate the adapter completing the connect — espex emits
      # BluetoothDeviceConnectionResponse + a refreshed
      # BluetoothConnectionsFreeResponse.
      send(handler_pid, {:espex_ble_connection, 0xAABB, {:ok, 247}})

      {:ok, %Proto.BluetoothDeviceConnectionResponse{}, buf} = recv_struct(socket, buf)
      {:ok, %Proto.BluetoothConnectionsFreeResponse{allocated: [0xAABB]}, _} = recv_struct(socket, buf)

      :gen_tcp.close(socket)
    end
  end

  describe "optional callback :not_supported paths" do
    @tag adapters: %{bluetooth_proxy: MinimalBluetoothProxy}
    test "PAIR on adapter without pair/1 sends paired: false, error: -1", %{port: port} do
      socket = connect(port)

      send_struct(socket, %Proto.BluetoothDeviceRequest{
        request_type: :BLUETOOTH_DEVICE_REQUEST_TYPE_PAIR,
        address: 0xAABB
      })

      {:ok, response, _} = recv_struct(socket)

      assert %Proto.BluetoothDevicePairingResponse{
               address: 0xAABB,
               paired: false,
               error: -1
             } = response

      :gen_tcp.close(socket)
    end

    @tag adapters: %{bluetooth_proxy: MinimalBluetoothProxy}
    test "UNPAIR on adapter without unpair/1 sends success: false, error: -1", %{port: port} do
      socket = connect(port)

      send_struct(socket, %Proto.BluetoothDeviceRequest{
        request_type: :BLUETOOTH_DEVICE_REQUEST_TYPE_UNPAIR,
        address: 0xAABB
      })

      {:ok, response, _} = recv_struct(socket)

      assert %Proto.BluetoothDeviceUnpairingResponse{
               address: 0xAABB,
               success: false,
               error: -1
             } = response

      :gen_tcp.close(socket)
    end

    @tag adapters: %{bluetooth_proxy: MinimalBluetoothProxy}
    test "CLEAR_CACHE on adapter without clear_cache/1 sends success: false, error: -1", %{port: port} do
      socket = connect(port)

      send_struct(socket, %Proto.BluetoothDeviceRequest{
        request_type: :BLUETOOTH_DEVICE_REQUEST_TYPE_CLEAR_CACHE,
        address: 0xAABB
      })

      {:ok, response, _} = recv_struct(socket)

      assert %Proto.BluetoothDeviceClearCacheResponse{
               address: 0xAABB,
               success: false,
               error: -1
             } = response

      :gen_tcp.close(socket)
    end

    @tag adapters: %{bluetooth_proxy: MinimalBluetoothProxy}
    test "BluetoothSetConnectionParamsRequest on adapter without set_connection_params/2 sends error: -1", %{
      port: port
    } do
      socket = connect(port)

      send_struct(socket, %Proto.BluetoothSetConnectionParamsRequest{
        address: 0xAABB,
        min_interval: 6,
        max_interval: 16,
        latency: 0,
        timeout: 400
      })

      {:ok, response, _} = recv_struct(socket)

      assert %Proto.BluetoothSetConnectionParamsResponse{address: 0xAABB, error: -1} = response

      :gen_tcp.close(socket)
    end
  end
end
