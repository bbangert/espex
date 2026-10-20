defmodule Espex.DialerTest do
  # The dial-back state machine, driven through a real tree with short
  # timings. A random function that reports to the test shows each
  # backoff wait: for a backoff b it is called with 2 * div(b, 5) + 1.
  # PidTargetStore uses :persistent_term, so async: false.
  use ExUnit.Case, async: false

  import Espex.Test.TcpClient, only: [wait_until: 1]

  alias Espex.Dialer.Adopt
  alias Espex.Proto
  alias Espex.Test.{NoiseClient, PidTargetStore}

  @psk :crypto.hash(:sha256, "espex-dialer-psk")

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])
    {:ok, ha_port} = :inet.port(listener)
    PidTargetStore.put(self())
    on_exit(&PidTargetStore.reset/0)
    %{listener: listener, ha_port: ha_port}
  end

  defp start(context, outgoing, device_config \\ [psk: @psk]) do
    server_name = :"espex_server_#{context.test}"
    test = self()

    random = fn n ->
      send(test, {:jitter, n})
      0
    end

    outgoing = Keyword.merge([delay: 0, backoff_min: 10, precondition_retry: 10, random: random], outgoing)

    {:ok, sup_pid} =
      Espex.start_link(
        name: :"espex_sup_#{context.test}",
        server_name: server_name,
        port: 0,
        device_config: [name: "dialer"] ++ device_config,
        outgoing_target_store: PidTargetStore,
        outgoing_connection: outgoing
      )

    on_exit(fn ->
      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, port} = Espex.Supervisor.bound_port(sup_pid)
    %{server: server_name, port: port, dialer: Espex.Supervisor.dialer_name(server_name)}
  end

  defp hello(session, target?) do
    session =
      NoiseClient.send_struct(session, %Proto.HelloRequest{
        client_info: "dialer-test",
        api_version_major: 1,
        api_version_minor: 18,
        outgoing_connection_target: target?
      })

    {%Proto.HelloResponse{}, session} = NoiseClient.recv_struct(session)
    # The hello's cast to the dialer went out before this ping is answered.
    session = NoiseClient.send_struct(session, %Proto.PingRequest{})
    {%Proto.PingResponse{}, session} = NoiseClient.recv_struct(session)
    session
  end

  defp target_client(port), do: port |> NoiseClient.connect(@psk) |> hello(true)

  defp accept_dial(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    {:ok, _} = NoiseClient.recv_server_hello(socket)
    socket
  end

  defp close({socket, _tx, _rx}), do: :gen_tcp.close(socket)

  test "a refused connect escalates the backoff", context do
    {:ok, closed} = :gen_tcp.listen(0, [])
    {:ok, closed_port} = :inet.port(closed)
    :gen_tcp.close(closed)

    start(context, host: "127.0.0.1", port: closed_port)

    # Backoffs of 10, 20 and 40 ms.
    assert_receive {:jitter, 5}, 1_000
    assert_receive {:jitter, 9}, 1_000
    assert_receive {:jitter, 17}, 1_000
  end

  test "a missing key waits without escalating; a provisioned key starts the dial",
       %{listener: listener, ha_port: ha_port} = context do
    %{server: server} = start(context, [host: "127.0.0.1", port: ha_port], accepts_key_provisioning: true)

    assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
    refute_received {:jitter, _}

    :ok = Espex.update_device_config(server, psk: @psk)
    socket = accept_dial(listener)
    refute_received {:jitter, _}
    :gen_tcp.close(socket)
  end

  test "a target client stops the dialing, resets the backoff and becomes the target",
       %{listener: listener, ha_port: ha_port} = context do
    # The seed refuses (the listener is on 127.0.0.1 only), so the
    # backoff climbs until the target client says hello.
    %{port: port, dialer: dialer} = start(context, target: "127.0.0.2", port: ha_port)
    assert_receive {:jitter, 9}, 1_000

    client = target_client(port)
    assert_receive {:store_target, {127, 0, 0, 1}}, 1_000
    wait_until(fn -> match?(%{phase: :idle, backoff: 10, target: {127, 0, 0, 1}}, :sys.get_state(dialer)) end)

    # No dial while it is connected; once it leaves, dial what it taught.
    assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
    close(client)
    socket = accept_dial(listener)
    :gen_tcp.close(socket)
  end

  test "the target is stored once, and again after a failed write", %{ha_port: ha_port} = context do
    %{port: port} = start(context, port: ha_port)

    PidTargetStore.put(self(), {:error, :disk_full})
    port |> target_client() |> close()
    assert_receive {:store_target, {127, 0, 0, 1}}, 1_000

    PidTargetStore.put(self())
    port |> target_client() |> close()
    assert_receive {:store_target, {127, 0, 0, 1}}, 1_000

    port |> target_client() |> close()
    refute_receive {:store_target, _}, 100
  end

  test "a configured host is never learned", %{listener: listener, ha_port: ha_port} = context do
    %{port: port} = start(context, host: "127.0.0.1", port: ha_port, delay: 60_000)

    client = target_client(port)
    refute_receive {:store_target, _}, 100
    close(client)
    assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
  end

  test "a dialed connection that dies before its hello escalates; after it, the backoff resets",
       %{listener: listener, ha_port: ha_port} = context do
    %{dialer: dialer} = start(context, host: "127.0.0.1", port: ha_port)

    listener |> accept_dial() |> :gen_tcp.close()
    assert_receive {:jitter, 5}, 1_000

    socket = accept_dial(listener)
    session = socket |> NoiseClient.handshake(@psk) |> hello(false)
    wait_until(fn -> match?(%{phase: :idle, backoff: 20}, :sys.get_state(dialer)) end)

    close(session)
    socket = accept_dial(listener)
    assert %{backoff: 10} = :sys.get_state(dialer)
    refute_received {:jitter, _}
    :gen_tcp.close(socket)
  end

  describe "a dial that does not finish" do
    # A dial function that reports to the test, then does what the test
    # sends it: {:run, fun} runs fun.(address, port, opts) as the dial.
    defp driven_dial do
      test = self()

      fn address, port, opts ->
        send(test, {:dialing, self(), opts})

        receive do
          {:run, fun} -> fun.(address, port, opts)
        end
      end
    end

    # A connection under the dial supervisor that never gets a socket, as
    # when a dial dies mid-handoff.
    defp start_orphan(opts) do
      child = {Espex.Connection, {Keyword.fetch!(opts, :handler_options), []}}
      {:ok, pid} = DynamicSupervisor.start_child(Keyword.fetch!(opts, :connection_supervisor), child)
      pid
    end

    test "a target client's hello stops it, and the connection it started",
         %{ha_port: ha_port} = context do
      %{port: port} = start(context, target: "127.0.0.1", port: ha_port, dial: driven_dial())

      assert_receive {:dialing, task, opts}, 1_000
      orphan = start_orphan(opts)
      task_ref = Process.monitor(task)
      orphan_ref = Process.monitor(orphan)

      client = target_client(port)
      assert_receive {:DOWN, ^task_ref, :process, ^task, :killed}, 1_000
      assert_receive {:DOWN, ^orphan_ref, :process, ^orphan, _}, 1_000
      close(client)
    end

    test "a dial that dies mid-handoff does not hold the slot", %{listener: listener, ha_port: ha_port} = context do
      start(context, host: "127.0.0.1", port: ha_port, dial: driven_dial())

      assert_receive {:dialing, task, opts}, 1_000
      orphan = start_orphan(opts)
      orphan_ref = Process.monitor(orphan)
      send(task, {:run, fn _, _, _ -> exit(:handoff_failed) end})

      assert_receive {:DOWN, ^orphan_ref, :process, ^orphan, _}, 1_000
      assert_receive {:jitter, 5}, 1_000
      assert_receive {:dialing, task, _opts}, 1_000
      send(task, {:run, &Adopt.dial/3})
      listener |> accept_dial() |> :gen_tcp.close()
    end

    test "a full dial supervisor waits without escalating", %{listener: listener, ha_port: ha_port} = context do
      start(context, host: "127.0.0.1", port: ha_port, dial: driven_dial())

      assert_receive {:dialing, task, _opts}, 1_000
      send(task, {:run, fn _, _, _ -> {:error, :max_children} end})
      assert_receive {:dialing, task, _opts}, 1_000
      refute_received {:jitter, _}

      send(task, {:run, &Adopt.dial/3})
      listener |> accept_dial() |> :gen_tcp.close()
    end

    test "a dialed connection that dies before its dial's result keeps the delay",
         %{listener: listener, ha_port: ha_port} = context do
      %{dialer: dialer} = start(context, host: "127.0.0.1", port: ha_port, delay: 60_000, dial: driven_dial())
      # The first dial waits delay; start it now.
      send(dialer, {:tick, elem(:sys.get_state(dialer).timer, 0)})

      assert_receive {:dialing, task, _opts}, 1_000
      test = self()

      # Dial, then hold the result until the connection has said hello
      # and died.
      send(
        task,
        {:run,
         fn address, port, opts ->
           result = Adopt.dial(address, port, opts)
           send(test, {:dialed, result})

           receive do
             :report -> result
           end
         end}
      )

      assert_receive {:dialed, {:ok, conn}}, 1_000
      socket = accept_dial(listener)
      session = socket |> NoiseClient.handshake(@psk) |> hello(false)
      conn_ref = Process.monitor(conn)
      close(session)
      assert_receive {:DOWN, ^conn_ref, :process, ^conn, _}, 1_000
      wait_until(fn -> :sys.get_state(dialer).live == %{} end)

      send(task, :report)
      wait_until(fn -> :sys.get_state(dialer).dial == nil end)
      assert %{phase: :waiting, backoff: 10, live: live} = :sys.get_state(dialer)
      assert live == %{}
      refute_received {:jitter, _}
    end
  end

  describe "startup validation" do
    defp init(outgoing, device_config \\ [psk: @psk]) do
      Espex.Supervisor.init(device_config: [name: "x"] ++ device_config, outgoing_connection: outgoing)
    end

    test "accepts a bare block, an IP host and a learned seed" do
      assert {:ok, _} = init([])
      assert {:ok, _} = init(host: "192.168.1.10", port: 6054, delay: 0)
      assert {:ok, _} = init(host: {10, 0, 0, 1}, target: "::ffff:10.0.0.2")
      assert {:ok, _} = init([], psk: nil, accepts_key_provisioning: true)
    end

    test "refuses bad options" do
      for {outgoing, message} <- [
            {[host: "homeassistant.local"], "no DNS"},
            {[host: "fe80::1"], "link-local"},
            {[target: "nope"], ":target"},
            {[port: 0], ":port 0"},
            {[delay: -1], ":delay -1"},
            {[typo: 1], "unknown key :typo"},
            {:yes, "expected a keyword list"}
          ] do
        assert_raise ArgumentError, ~r/#{message}/, fn -> init(outgoing) end
      end
    end

    test "needs a key or key provisioning" do
      assert_raise ArgumentError, ~r/Noise only/, fn -> init([], psk: nil) end
    end
  end
end
