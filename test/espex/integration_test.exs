defmodule Espex.IntegrationTest do
  use ExUnit.Case, async: false

  alias Espex.{Frame, MessageTypes, Proto}

  setup context do
    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    opts =
      [
        name: sup_name,
        server_name: server_name,
        port: 0,
        device_config: [
          name: "test-device",
          friendly_name: "Test",
          project_name: "espex_test",
          project_version: "0.0.1"
        ]
      ] ++ Map.to_list(context[:adapters] || %{})

    {:ok, sup_pid} = Espex.start_link(opts)
    {:ok, port} = Espex.Supervisor.bound_port(sup_pid)

    on_exit(fn ->
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

  # Read one decoded message from the socket. Returns {:ok, message, leftover_buffer}
  # — pass `leftover_buffer` into the next call to continue reading.
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

  describe "hello round-trip" do
    test "HelloRequest → HelloResponse", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.HelloRequest{client_info: "integration-test"})
      {:ok, response, _} = recv_struct(socket)

      assert %Proto.HelloResponse{name: "test-device", server_info: info} = response
      assert info =~ "espex_test"
      :gen_tcp.close(socket)
    end
  end

  describe "device info" do
    test "DeviceInfoRequest returns the configured device fields", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{} = info, _} = recv_struct(socket)

      assert info.name == "test-device"
      assert info.friendly_name == "Test"
      assert info.project_name == "espex_test"
      assert info.project_version == "0.0.1"
      assert info.serial_proxies == []
      assert info.zwave_proxy_feature_flags == 0
      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.FakeSerialProxyWithOne}
    test "DeviceInfoResponse includes serial proxies from the adapter", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{serial_proxies: proxies}, _} = recv_struct(socket)

      assert [%Proto.SerialProxyInfo{name: "zigbee", port_type: :SERIAL_PROXY_PORT_TYPE_TTL}] = proxies
      :gen_tcp.close(socket)
    end
  end

  describe "list entities" do
    test "with no adapters, returns only Done", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.ListEntitiesRequest{})
      {:ok, %Proto.ListEntitiesDoneResponse{}, _} = recv_struct(socket)
      :gen_tcp.close(socket)
    end

    @tag adapters: %{entity_provider: Espex.Test.FakeEntityProvider}
    test "with EntityProvider, returns custom entities then Done", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.ListEntitiesRequest{})

      {:ok, %Proto.ListEntitiesBinarySensorResponse{name: "Fake"}, rest} = recv_struct(socket)
      {:ok, %Proto.ListEntitiesDoneResponse{}, _} = recv_struct(socket, rest)
      :gen_tcp.close(socket)
    end
  end

  describe "disconnect" do
    test "DisconnectRequest gets a response and the server closes the socket", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DisconnectRequest{})
      {:ok, %Proto.DisconnectResponse{}, _rest} = recv_struct(socket)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    end
  end

  describe "push_state/2" do
    test "broadcasts a StateResponse struct to every connected client", context do
      server_name = :"espex_server_#{context.test}"
      socket1 = connect(context.port)
      socket2 = connect(context.port)

      # Both clients must be registered before broadcast.
      # Force each through the handshake so we know their Connection process has
      # finished handle_connection (and therefore Registry.register).
      for sock <- [socket1, socket2] do
        send_struct(sock, %Proto.HelloRequest{})
        {:ok, %Proto.HelloResponse{}, _} = recv_struct(sock)
      end

      :ok = Espex.push_state(server_name, %Proto.SensorStateResponse{key: 99, state: 42.5})

      for sock <- [socket1, socket2] do
        {:ok, %Proto.SensorStateResponse{key: 99, state: state}, _} = recv_struct(sock)
        assert_in_delta state, 42.5, 0.01
      end

      :gen_tcp.close(socket1)
      :gen_tcp.close(socket2)
    end
  end
end
