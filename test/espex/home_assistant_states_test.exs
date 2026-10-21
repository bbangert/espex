defmodule Espex.HomeAssistantStatesTest do
  # Home Assistant state subscriptions (messages 38/39/40) over real TCP.
  # FakeHomeAssistantStates uses :persistent_term, so this file stays
  # async: false.
  use ExUnit.Case, async: false

  import Espex.Test.TcpClient

  alias Espex.HomeAssistantStates.Subscription
  alias Espex.Proto
  alias Espex.Test.{FakeHomeAssistantStates, OtherHomeAssistantStates}

  setup context do
    FakeHomeAssistantStates.put_test_pid(self())

    FakeHomeAssistantStates.put_subscriptions([
      Subscription.new!(entity_id: "sun.sun", attribute: "elevation"),
      Subscription.new!(entity_id: "sun.sun")
    ])

    on_exit(&FakeHomeAssistantStates.reset/0)

    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"
    adapter = Map.get(context, :adapter, FakeHomeAssistantStates)

    {:ok, sup_pid} =
      Espex.start_link(
        name: sup_name,
        server_name: server_name,
        port: 0,
        device_config: [name: "ha-states"],
        home_assistant_states: adapter
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

    %{port: port, server: server_name}
  end

  defp hello(port) do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: "ha-states-test", api_version_major: 1, api_version_minor: 18})
    {:ok, %Proto.HelloResponse{}, rest} = recv_struct(socket)
    {socket, rest}
  end

  # Receive `count` SubscribeHomeAssistantStateResponses as
  # {entity_id, attribute, once}.
  defp recv_subscriptions(socket, rest, count) do
    Enum.map_reduce(1..count//1, rest, fn _, rest ->
      {:ok, %Proto.SubscribeHomeAssistantStateResponse{} = msg, rest} = recv_struct(socket, rest)
      {{msg.entity_id, msg.attribute, msg.once}, rest}
    end)
  end

  defp subscribe_states(socket, rest, count) do
    send_struct(socket, %Proto.SubscribeHomeAssistantStatesRequest{})
    recv_subscriptions(socket, rest, count)
  end

  defp send_state(socket, entity_id, attribute, state) do
    send_struct(socket, %Proto.HomeAssistantStateResponse{entity_id: entity_id, attribute: attribute, state: state})
  end

  # A ping round trip orders every earlier frame's handling before it.
  defp sync(socket, rest) do
    send_struct(socket, %Proto.PingRequest{})
    {:ok, %Proto.PingResponse{}, rest} = recv_struct(socket, rest)
    rest
  end

  test "request 38 walks the table in order, and a second request walks it again", %{port: port} do
    {socket, rest} = hello(port)

    {first, rest} = subscribe_states(socket, rest, 2)
    assert first == [{"sun.sun", "", false}, {"sun.sun", "elevation", false}]

    {again, rest} = subscribe_states(socket, rest, 2)
    assert again == first
    assert_nothing_sent(socket, rest)
    :gen_tcp.close(socket)
  end

  test "a state matches on entity id and attribute; the rest are dropped", %{port: port} do
    {socket, rest} = hello(port)
    {_, rest} = subscribe_states(socket, rest, 2)

    send_state(socket, "sun.sun", "", "above_horizon")
    send_state(socket, "sun.sun", "elevation", "12.5")
    send_state(socket, "sun.sun", "azimuth", "180")
    send_state(socket, "moon.moon", "", "full")
    send_state(socket, "", "", "nothing")
    _rest = sync(socket, rest)

    assert_received {:ha_state, "sun.sun", nil, "above_horizon"}
    assert_received {:ha_state, "sun.sun", "elevation", "12.5"}
    refute_received {:ha_state, _, _, _}
    :gen_tcp.close(socket)
  end

  test "a runtime entry goes at once to subscribed clients only, and only when new",
       %{port: port, server: server} do
    {subscribed, rest_s} = hello(port)
    {_, rest_s} = subscribe_states(subscribed, rest_s, 2)
    {other, rest_o} = hello(port)

    assert :ok = Espex.subscribe_home_assistant_state(server, entity_id: "light.kitchen", once: true)
    assert {[{"light.kitchen", "", true}], rest_s} = recv_subscriptions(subscribed, rest_s, 1)

    # Already in the table from the adapter: nothing to send.
    assert :ok = Espex.subscribe_home_assistant_state(server, "sun.sun")
    assert_nothing_sent(subscribed, rest_s)
    assert_nothing_sent(other, rest_o)

    # The client that subscribes later walks the whole table, once each.
    {walk, rest_o} = subscribe_states(other, rest_o, 3)
    assert walk == [{"light.kitchen", "", true}, {"sun.sun", "", false}, {"sun.sun", "elevation", false}]
    assert_nothing_sent(other, rest_o)

    :gen_tcp.close(subscribed)
    :gen_tcp.close(other)
  end

  test "an unsubscribed runtime entry sends nothing and stops matching", %{port: port, server: server} do
    {socket, rest} = hello(port)
    {_, rest} = subscribe_states(socket, rest, 2)

    :ok = Espex.subscribe_home_assistant_state(server, "light.kitchen")
    {_, rest} = recv_subscriptions(socket, rest, 1)
    :ok = Espex.unsubscribe_home_assistant_state(server, "light.kitchen")
    # The adapter's entry stays.
    :ok = Espex.unsubscribe_home_assistant_state(server, "sun.sun")

    send_state(socket, "light.kitchen", "", "on")
    send_state(socket, "sun.sun", "", "below_horizon")
    rest = sync(socket, rest)

    refute_received {:ha_state, "light.kitchen", _, _}
    assert_received {:ha_state, "sun.sun", nil, "below_horizon"}
    assert_nothing_sent(socket, rest)
    :gen_tcp.close(socket)
  end

  test "an invalid runtime entry is refused", %{server: server} do
    assert {:error, :invalid_subscription} = Espex.subscribe_home_assistant_state(server, "no-dot")
    assert {:error, :invalid_subscription} = Espex.subscribe_home_assistant_state(server, entity_id: "a.b", bad: 1)
    assert {:error, :invalid_subscription} = Espex.unsubscribe_home_assistant_state(server, attribute: "x")
  end

  test "a raising handle_state keeps the connection", %{port: port, server: server} do
    {socket, rest} = hello(port)
    :ok = Espex.subscribe_home_assistant_state(server, "boom.raise")

    send_state(socket, "boom.raise", "", "on")
    _rest = sync(socket, rest)
    :gen_tcp.close(socket)
  end

  test "a new adapter replaces the adapter's entries", %{port: port, server: server} do
    {socket, rest} = hello(port)
    {_, rest} = subscribe_states(socket, rest, 2)

    :ok = Espex.update_adapters(server, home_assistant_states: OtherHomeAssistantStates)
    assert {[{"weather.home", "", false}], rest} = recv_subscriptions(socket, rest, 1)

    send_state(socket, "sun.sun", "", "above_horizon")
    send_state(socket, "weather.home", "", "sunny")
    _rest = sync(socket, rest)

    # The live connection keeps the adapter it accepted with.
    assert_received {:ha_state, "weather.home", nil, "sunny"}
    refute_received {:ha_state, "sun.sun", _, _}
    :gen_tcp.close(socket)

    # A client that subscribes after the swap walks the new entries only.
    {later, rest} = hello(port)
    assert {[{"weather.home", "", false}], rest} = subscribe_states(later, rest, 1)
    assert_nothing_sent(later, rest)
    :gen_tcp.close(later)
  end

  test "setting the same adapter again does not re-read its entries", %{port: port, server: server} do
    FakeHomeAssistantStates.put_subscriptions([Subscription.new!(entity_id: "moon.moon")])
    :ok = Espex.update_adapters(server, home_assistant_states: FakeHomeAssistantStates)

    {socket, rest} = hello(port)
    {walk, rest} = subscribe_states(socket, rest, 2)
    assert walk == [{"sun.sun", "", false}, {"sun.sun", "elevation", false}]
    assert_nothing_sent(socket, rest)
    :gen_tcp.close(socket)
  end

  test "a throw from subscriptions/0 counts as no entries", context do
    assert :ok = Espex.update_adapters(context.server, home_assistant_states: Espex.Test.ThrowingHomeAssistantStates)
    {socket, rest} = hello(context.port)
    assert {[], rest} = subscribe_states(socket, rest, 0)
    assert_nothing_sent(socket, rest)
    :gen_tcp.close(socket)
  end

  @tag adapter: nil
  test "without an adapter the table still works and states are dropped", %{port: port, server: server} do
    {socket, rest} = hello(port)
    {[], rest} = subscribe_states(socket, rest, 0)

    :ok = Espex.subscribe_home_assistant_state(server, "light.kitchen")
    assert {[{"light.kitchen", "", false}], rest} = recv_subscriptions(socket, rest, 1)

    send_state(socket, "light.kitchen", "", "on")
    _rest = sync(socket, rest)
    refute_received {:ha_state, _, _, _}
    :gen_tcp.close(socket)
  end
end
