defmodule Espex.KeepaliveTest do
  # Device-initiated keepalive (Espex.Connection): after keepalive_idle_ms of
  # inbound silence the server sends a PingRequest; after keepalive_grace_ms
  # more it closes. Exercised over real TCP with short intervals.
  use ExUnit.Case, async: false

  alias Espex.{Frame, MessageTypes, Proto}

  # Generous relative to the 300 ms intervals below; absolute values stay
  # small so the suite remains fast.
  @recv_timeout 1_500

  setup context do
    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    opts = [
      name: sup_name,
      server_name: server_name,
      port: 0,
      keepalive_idle_ms: 300,
      keepalive_grace_ms: 300,
      device_config: [
        name: "test-device",
        friendly_name: "Test",
        project_name: "espex_test",
        project_version: "0.0.1"
      ]
    ]

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
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true, packet: :raw])

    socket
  end

  defp send_struct(socket, struct) do
    {:ok, frame} = MessageTypes.encode_message(struct)
    :ok = :gen_tcp.send(socket, frame)
  end

  defp recv_struct(socket, buffer \\ <<>>, timeout \\ @recv_timeout) do
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

  test "an idle client receives a device-initiated PingRequest", %{port: port} do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: "keepalive-test"})
    {:ok, %Proto.HelloResponse{}, rest} = recv_struct(socket)

    # Go silent: the server should ping us after keepalive_idle_ms.
    assert {:ok, %Proto.PingRequest{}, _rest} = recv_struct(socket, rest)
    :gen_tcp.close(socket)
  end

  test "answering the ping keeps the connection alive across cycles", %{port: port} do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: "keepalive-test"})
    {:ok, %Proto.HelloResponse{}, rest} = recv_struct(socket)

    {:ok, %Proto.PingRequest{}, rest} = recv_struct(socket, rest)
    send_struct(socket, %Proto.PingResponse{})

    # Still alive: a full idle period later the next ping arrives instead
    # of a close.
    assert {:ok, %Proto.PingRequest{}, _rest} = recv_struct(socket, rest)
    :gen_tcp.close(socket)
  end

  test "an unanswered ping closes the connection after the grace period", %{port: port} do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: "keepalive-test"})
    {:ok, %Proto.HelloResponse{}, rest} = recv_struct(socket)

    {:ok, %Proto.PingRequest{}, rest} = recv_struct(socket, rest)

    # Stay silent through the grace period: the server must close.
    assert {:error, :closed} = recv_struct(socket, rest)
  end

  test "inbound traffic resets the idle clock", %{port: port} do
    socket = connect(port)

    # Send a request every 100 ms (well inside the 300 ms idle window) and
    # drain its response: no PingRequest may interleave while we are active.
    rest =
      Enum.reduce(1..6, <<>>, fn _i, buffer ->
        send_struct(socket, %Proto.DeviceInfoRequest{})
        {:ok, response, rest} = recv_struct(socket, buffer)
        assert %Proto.DeviceInfoResponse{} = response
        Process.sleep(100)
        rest
      end)

    # Then go quiet: the ping shows up one idle period later.
    assert {:ok, %Proto.PingRequest{}, _rest} = recv_struct(socket, rest)
    :gen_tcp.close(socket)
  end
end
