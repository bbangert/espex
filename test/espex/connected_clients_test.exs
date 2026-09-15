defmodule Espex.ConnectedClientsTest do
  use ExUnit.Case, async: false

  import Espex.Test.TcpClient

  alias Espex.{ClientInfo, Proto}
  alias Espex.Test.PidConnectionListener

  setup context do
    :persistent_term.put(:espex_listener_test_pid, self())
    on_exit(fn -> :persistent_term.erase(:espex_listener_test_pid) end)

    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    {:ok, sup_pid} =
      Espex.start_link(
        name: sup_name,
        server_name: server_name,
        port: 0,
        device_config: [name: "espex-clients", project_name: "espex.demo", project_version: "0.0.1"],
        connection_listener: PidConnectionListener
      )

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

  # Connect and complete a hello; returns the socket once the connect
  # notification has fired (the barrier guaranteeing the Registry snapshot
  # was refreshed from the hello).
  defp connect_and_hello(port, client_info, {major, minor}) do
    sock = connect(port)
    send_struct(sock, %Proto.HelloRequest{client_info: client_info, api_version_major: major, api_version_minor: minor})
    {:ok, %Proto.HelloResponse{}, _} = recv_struct(sock)
    assert_receive {:connections_changed}, 1_000
    sock
  end

  test "connected_clients/1 reflects connect/disconnect and populates hello fields", ctx do
    %{port: port, server_name: server_name} = ctx

    assert Espex.connected_clients(server_name) == []

    sock = connect_and_hello(port, "HA test 2026.1.0", {1, 9})

    assert [%ClientInfo{} = ci] = Espex.connected_clients(server_name)
    assert ci.client_info == "HA test 2026.1.0"
    assert ci.api_version == {1, 9}
    assert ci.encrypted? == false
    assert ci.peer =~ "127.0.0.1:"
    assert is_pid(ci.id)
    assert is_integer(ci.connected_at)
    assert is_integer(ci.last_activity_at)
    assert ci.last_activity_at >= ci.connected_at

    :gen_tcp.close(sock)
    assert_receive {:connections_changed}, 1_000
    wait_until(fn -> Espex.connected_clients(server_name) == [] end)
  end

  test "connections_changed fires once on connect and once on disconnect, not per frame", ctx do
    %{port: port} = ctx

    sock = connect_and_hello(port, "frame-counter", {1, 9})
    # connect notification consumed by connect_and_hello; nothing else yet.
    refute_receive {:connections_changed}, 200

    # Ordinary inbound frames refresh activity but must NOT notify.
    send_struct(sock, %Proto.DeviceInfoRequest{})
    {:ok, %Proto.DeviceInfoResponse{}, _} = recv_struct(sock)
    send_struct(sock, %Proto.PingRequest{})
    {:ok, %Proto.PingResponse{}, _} = recv_struct(sock)
    refute_receive {:connections_changed}, 200

    :gen_tcp.close(sock)
    assert_receive {:connections_changed}, 1_000
    # Disconnect fires exactly once.
    refute_receive {:connections_changed}, 200
  end

  test "a pre-hello connection appears with nil client_info/api_version", ctx do
    %{port: port, server_name: server_name} = ctx

    sock = connect(port)
    # No hello sent — the entry is registered at accept, so it should be
    # visible immediately with the identity fields still nil.
    wait_until(fn -> length(Espex.connected_clients(server_name)) == 1 end)

    assert [%ClientInfo{} = ci] = Espex.connected_clients(server_name)
    assert ci.client_info == nil
    assert ci.api_version == nil
    assert ci.encrypted? == false
    assert is_integer(ci.connected_at)

    # A bare open/close that never said hello must NOT notify the listener.
    :gen_tcp.close(sock)
    refute_receive {:connections_changed}, 200
    wait_until(fn -> Espex.connected_clients(server_name) == [] end)
  end

  test "two clients are both listed; disconnecting one leaves the other", ctx do
    %{port: port, server_name: server_name} = ctx

    a = connect_and_hello(port, "client-a", {1, 9})
    b = connect_and_hello(port, "client-b", {1, 9})

    infos = Espex.connected_clients(server_name)
    assert length(infos) == 2
    assert Enum.sort(Enum.map(infos, & &1.client_info)) == ["client-a", "client-b"]

    :gen_tcp.close(a)
    assert_receive {:connections_changed}, 1_000
    wait_until(fn -> Enum.map(Espex.connected_clients(server_name), & &1.client_info) == ["client-b"] end)

    :gen_tcp.close(b)
    assert_receive {:connections_changed}, 1_000
    wait_until(fn -> Espex.connected_clients(server_name) == [] end)
  end
end
