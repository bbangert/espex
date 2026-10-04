defmodule Espex.KeepaliveTest do
  # Device-initiated keepalive (Espex.Connection): after keepalive_idle_ms of
  # inbound silence the server sends a PingRequest; after keepalive_grace_ms
  # more it closes. Exercised over real TCP with short intervals.
  use ExUnit.Case, async: false

  import Espex.Test.TcpClient, except: [recv_struct: 1, recv_struct: 2]

  alias Espex.Proto

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
      keepalive_idle_ms: context[:keepalive_idle_ms] || 300,
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

    %{port: port, server_name: server_name}
  end

  defp recv_struct(socket, buffer \\ <<>>), do: Espex.Test.TcpClient.recv_struct(socket, buffer, @recv_timeout)

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
    send_struct(socket, %Proto.HelloRequest{client_info: "keepalive-test"})
    {:ok, %Proto.HelloResponse{}, hello_rest} = recv_struct(socket)

    # Send a request every 100 ms (well inside the 300 ms idle window) and
    # drain its response: no PingRequest may interleave while we are active.
    rest =
      Enum.reduce(1..6, hello_rest, fn _i, buffer ->
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

  defp keepalive_timer(conn_pid) do
    {_socket, state} = :sys.get_state(conn_pid)
    state.keepalive_timer
  end

  # A long idle window keeps real timers out of the way, so only the tick
  # each test delivers by hand can produce a PingRequest.
  @tag keepalive_idle_ms: 5_000
  test "a tick for the armed keepalive timer is acted on", %{port: port, server_name: server_name} do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: "keepalive-test"})
    {:ok, %Proto.HelloResponse{}, rest} = recv_struct(socket)
    [%Espex.ClientInfo{id: conn_pid}] = Espex.connected_clients(server_name)

    # Deliver exactly what the armed timer delivers when it fires.
    send(conn_pid, {:timeout, keepalive_timer(conn_pid), :espex_keepalive})

    assert {:ok, %Proto.PingRequest{}, _rest} = recv_struct(socket, rest)
    :gen_tcp.close(socket)
  end

  @tag keepalive_idle_ms: 5_000
  test "a tick from a timer cancelled by a reset is ignored", %{port: port, server_name: server_name} do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: "keepalive-test"})
    {:ok, %Proto.HelloResponse{}, rest} = recv_struct(socket)
    [%Espex.ClientInfo{id: conn_pid}] = Espex.connected_clients(server_name)
    cancelled = keepalive_timer(conn_pid)

    # Inbound traffic resets the keepalive: `cancelled` is cancelled and a
    # new timer armed. The response proves the reset has been processed.
    send_struct(socket, %Proto.DeviceInfoRequest{})
    {:ok, %Proto.DeviceInfoResponse{}, rest} = recv_struct(socket, rest)
    refute keepalive_timer(conn_pid) == cancelled

    # The tick `cancelled` would have left in the mailbox had it fired just
    # before the cancel. Acting on it would ping ~5 s early.
    send(conn_pid, {:timeout, cancelled, :espex_keepalive})

    assert {:error, :timeout} = Espex.Test.TcpClient.recv_struct(socket, rest, 500)
    assert Process.alive?(conn_pid)
    :gen_tcp.close(socket)
  end
end
