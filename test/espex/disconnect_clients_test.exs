defmodule Espex.DisconnectClientsTest do
  # Server-initiated disconnect (Espex.disconnect_clients/1) over real TCP,
  # paired with Espex.update_device_config/2 to show the "update, then
  # disconnect, and the reconnecting client sees the new world" story.
  use ExUnit.Case, async: false

  import Espex.Test.TcpClient, except: [recv_struct: 1, recv_struct: 2]

  alias Espex.{DeviceConfig, Proto}
  alias Espex.Test.{PidConnectionListener, SwappableEntityProvider}

  # Short so the silent-client test stays fast; tests that must observe the
  # old connection *still open* while unanswered override it via @tag.
  @grace_ms 300
  @recv_timeout 1_500

  setup context do
    :persistent_term.put(:espex_listener_test_pid, self())

    on_exit(fn ->
      :persistent_term.erase(:espex_listener_test_pid)
      SwappableEntityProvider.reset()
    end)

    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    {:ok, sup_pid} =
      Espex.start_link(
        name: sup_name,
        server_name: server_name,
        port: 0,
        disconnect_grace_ms: Map.get(context, :grace_ms, @grace_ms),
        keepalive_idle_ms: Map.get(context, :keepalive_ms, 60_000),
        keepalive_grace_ms: Map.get(context, :keepalive_ms, 60_000),
        device_config: [name: "before", friendly_name: "Before", project_name: "espex_test", project_version: "0.0.1"],
        entity_provider: SwappableEntityProvider,
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

  defp recv_struct(socket, buffer \\ <<>>), do: Espex.Test.TcpClient.recv_struct(socket, buffer, @recv_timeout)

  # Connect and complete hello. The hello response proves the connection
  # is registered and past hello; the listener notification it consumes
  # is that connect's (or, with an earlier connection mid-disconnect, that
  # one's disconnect — either way one notification per event).
  defp connect_and_hello(port, client_info) do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: client_info, api_version_major: 1, api_version_minor: 10})
    {:ok, %Proto.HelloResponse{} = hello, rest} = recv_struct(socket)
    assert_receive {:connections_changed}, 1_000
    {socket, hello, rest}
  end

  defp device_name(socket, buffer) do
    send_struct(socket, %Proto.DeviceInfoRequest{})
    {:ok, %Proto.DeviceInfoResponse{name: name}, rest} = recv_struct(socket, buffer)
    {name, rest}
  end

  # Drain a ListEntities round: returns the entity structs before Done.
  defp list_entities(socket, buffer) do
    send_struct(socket, %Proto.ListEntitiesRequest{})
    collect_entities(socket, buffer, [])
  end

  defp collect_entities(socket, buffer, acc) do
    case recv_struct(socket, buffer) do
      {:ok, %Proto.ListEntitiesDoneResponse{}, rest} -> {Enum.reverse(acc), rest}
      {:ok, entity, rest} -> collect_entities(socket, rest, [entity | acc])
    end
  end

  @tag grace_ms: 5_000
  test "a client that answers DisconnectResponse is closed at once, not at the grace deadline", ctx do
    {socket, _hello, rest} = connect_and_hello(ctx.port, "acks")

    :ok = Espex.disconnect_clients(ctx.server_name)

    assert {:ok, %Proto.DisconnectRequest{}, rest} = recv_struct(socket, rest)
    send_struct(socket, %Proto.DisconnectResponse{})
    # Grace is 5 s; the close must arrive well inside @recv_timeout.
    assert {:error, :closed} = recv_struct(socket, rest)
  end

  test "a client that never answers is closed after the grace period", ctx do
    {socket, _hello, rest} = connect_and_hello(ctx.port, "silent")

    :ok = Espex.disconnect_clients(ctx.server_name)

    assert {:ok, %Proto.DisconnectRequest{}, rest} = recv_struct(socket, rest)
    assert {:error, :closed} = recv_struct(socket, rest)
  end

  test "a connection that never said hello is closed without a frame", ctx do
    socket = connect(ctx.port)
    wait_until(fn -> length(Espex.connected_clients(ctx.server_name)) == 1 end)

    :ok = Espex.disconnect_clients(ctx.server_name)

    # No DisconnectRequest — the very next thing on the socket is the close.
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, @recv_timeout)
    # And no disconnect notification either: the client never counted.
    refute_receive {:connections_changed}, 200
  end

  test "every connected client receives the request", ctx do
    {a, _, a_rest} = connect_and_hello(ctx.port, "a")
    {b, _, b_rest} = connect_and_hello(ctx.port, "b")

    :ok = Espex.disconnect_clients(ctx.server_name)

    assert {:ok, %Proto.DisconnectRequest{}, _} = recv_struct(a, a_rest)
    assert {:ok, %Proto.DisconnectRequest{}, _} = recv_struct(b, b_rest)
    :gen_tcp.close(a)
    :gen_tcp.close(b)
  end

  @tag grace_ms: 5_000, keepalive_ms: 300
  test "the keepalive still runs while a disconnect is pending", ctx do
    {socket, _hello, rest} = connect_and_hello(ctx.port, "quiet")

    :ok = Espex.disconnect_clients(ctx.server_name)
    {:ok, %Proto.DisconnectRequest{}, rest} = recv_struct(socket, rest)

    # Silent client: the keepalive ping arrives, and its own grace closes
    # the socket long before the 5 s disconnect grace would.
    assert {:ok, %Proto.PingRequest{}, rest} = recv_struct(socket, rest)
    assert {:error, :closed} = recv_struct(socket, rest)
  end

  test "the struct form of update_device_config/2 is seen by the next connection", ctx do
    replacement = %DeviceConfig{name: "struct", friendly_name: "Struct"}
    assert Espex.update_device_config(ctx.server_name, replacement) == :ok

    {socket, hello, rest} = connect_and_hello(ctx.port, "next")
    assert hello.name == "struct"
    {"struct", _rest} = device_name(socket, rest)
    :gen_tcp.close(socket)
  end

  test "the listener sees a server-initiated disconnect exactly once", ctx do
    {socket, _hello, rest} = connect_and_hello(ctx.port, "listened")

    :ok = Espex.disconnect_clients(ctx.server_name)
    {:ok, %Proto.DisconnectRequest{}, _} = recv_struct(socket, rest)
    send_struct(socket, %Proto.DisconnectResponse{})

    assert_receive {:connections_changed}, 1_000
    refute_receive {:connections_changed}, 200
    wait_until(fn -> Espex.connected_clients(ctx.server_name) == [] end)
  end

  @tag grace_ms: 5_000
  test "update_device_config/2 then disconnect: the reconnect sees the new identity, the old socket its snapshot",
       ctx do
    {old, hello, rest} = connect_and_hello(ctx.port, "old")
    assert hello.name == "before"
    {"before", rest} = device_name(old, rest)

    assert Espex.update_device_config(ctx.server_name, name: "after", friendly_name: "After") == :ok
    :ok = Espex.disconnect_clients(ctx.server_name)
    {:ok, %Proto.DisconnectRequest{}, rest} = recv_struct(old, rest)

    # Home Assistant's side: reconnect and re-read.
    {new, hello, new_rest} = connect_and_hello(ctx.port, "new")
    assert hello.name == "after"
    send_struct(new, %Proto.DeviceInfoRequest{})
    {:ok, %Proto.DeviceInfoResponse{} = info, _} = recv_struct(new, new_rest)
    assert info.name == "after"
    assert info.friendly_name == "After"

    # The old connection is still open (grace is 5 s, unanswered) and still
    # reports the identity it snapshotted at accept.
    {"before", rest} = device_name(old, rest)

    send_struct(old, %Proto.DisconnectResponse{})
    assert {:error, :closed} = recv_struct(old, rest)
    :gen_tcp.close(new)
  end

  test "a changed entity list is picked up on reconnect", ctx do
    {old, _hello, rest} = connect_and_hello(ctx.port, "old")
    {[%Proto.ListEntitiesBinarySensorResponse{key: 1}], rest} = list_entities(old, rest)

    SwappableEntityProvider.put_entities([
      %Proto.ListEntitiesBinarySensorResponse{object_id: "one", key: 1, name: "One"},
      %Proto.ListEntitiesSensorResponse{object_id: "two", key: 2, name: "Two"}
    ])

    :ok = Espex.disconnect_clients(ctx.server_name)
    {:ok, %Proto.DisconnectRequest{}, rest} = recv_struct(old, rest)
    send_struct(old, %Proto.DisconnectResponse{})
    assert {:error, :closed} = recv_struct(old, rest)

    {new, _hello, new_rest} = connect_and_hello(ctx.port, "new")
    {entities, _} = list_entities(new, new_rest)
    assert Enum.map(entities, & &1.key) == [1, 2]
    :gen_tcp.close(new)
  end
end
