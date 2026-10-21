defmodule Espex.Dialer do
  @moduledoc false

  # Dial-back (API 1.18 outgoing connection), after ESPHome's
  # OutgoingConnectionManager. When no dial-back client is connected the
  # node dials the target itself, and the dialed socket runs through
  # Espex.Connection like an accepted one (Espex.Dialer.Adopt).
  #
  # "A dial-back client is connected" = a connection whose hello set
  # outgoing_connection_target is alive, or the connection this process
  # dialed is alive. No dial happens while either holds.
  #
  # Phases (upstream DialState):
  #
  #   * :waiting — a timer is armed; on its tick, dial. The first wait,
  #     from boot, is `delay`.
  #   * :connecting — a dial task runs the TCP connect (up to 10 s) and
  #     hands the socket here; this process starts the connection on it.
  #   * :idle — a dial-back client is connected. When it goes, wait
  #     `delay` for it to come back before dialing.
  #
  # A dial that fails — connect error or timeout, or a dialed connection
  # that dies before its hello — waits the backoff (5 s doubling to
  # 300 s, ±20 %). A dialed connection that dies after its hello resets
  # the backoff. A missing precondition (no target, no Noise key) waits
  # 5 s without escalating.
  #
  # The target is the configured host, or else learned from the peer
  # address of the newest target client and written through the
  # :outgoing_target_store adapter. Only the address is kept; the dial
  # always goes to the configured port.
  #
  # This process owns the handoff: it starts the dialed connection, gives
  # it the socket and monitors it in one callback, so there is never a
  # connection it does not know of, and nothing from that connection can
  # reach it first. Connections report their hellos by cast, so a
  # connection never waits on this process; their casts arrive before
  # their :DOWN (same sender), so a :DOWN knows whether the hello was seen.

  use GenServer

  require Logger

  alias Espex.{DeviceConfig, Server}
  alias Espex.Dialer.{Adopt, Backoff, Target}

  @connect_timeout_ms 10_000
  @precondition_retry_ms 5_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl GenServer
  def init(opts) do
    host = Keyword.get(opts, :host)

    state = %{
      server: Keyword.fetch!(opts, :server),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      connect: Keyword.get(opts, :connect, &Adopt.connect/3),
      connect_timeout: Keyword.get(opts, :connect_timeout, @connect_timeout_ms),
      adopt_opts: [
        connection_supervisor: Keyword.fetch!(opts, :connection_supervisor),
        handler_options: Keyword.fetch!(opts, :handler_options),
        read_timeout: Keyword.fetch!(opts, :read_timeout)
      ],
      port: Keyword.fetch!(opts, :port),
      delay: Keyword.fetch!(opts, :delay),
      precondition_retry: Keyword.get(opts, :precondition_retry, @precondition_retry_ms),
      backoff_min: Keyword.get(opts, :backoff_min, Backoff.initial()),
      random: Keyword.get(opts, :random, &(:rand.uniform(&1) - 1)),
      learn?: host == nil,
      target: host,
      stored_target: nil,
      warned_no_store?: false,
      phase: :waiting,
      timer: nil,
      backoff: nil,
      dial: nil,
      live: %{}
    }

    {:ok,
     state
     |> restore_target(Keyword.get(opts, :target))
     |> Map.put(:backoff, state.backoff_min)
     |> schedule(state.delay)}
  end

  # A configured host is the target. Otherwise start from what an earlier
  # dialer learned (kept by Espex.Server, so a restart of this subtree
  # keeps it), or else the boot seed, which came from the store.
  defp restore_target(%{learn?: false} = state, _seed), do: state

  defp restore_target(state, seed) do
    case Server.dial_back_target(state.server) do
      {target, stored_target} -> %{state | target: target, stored_target: stored_target}
      nil -> %{state | target: seed, stored_target: seed}
    end
  end

  @impl GenServer
  def handle_info({:tick, token}, %{timer: {token, _ref}} = state) do
    {:noreply, try_dial(%{state | timer: nil})}
  end

  def handle_info({:tick, _stale}, state), do: {:noreply, state}

  def handle_info({:dial_result, ref, result}, %{dial: {ref, _pid, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    state = %{state | dial: nil}

    with {:ok, socket} <- result,
         {:ok, pid} <- Adopt.start_connection(socket, state.adopt_opts) do
      {:noreply, %{track(state, pid, :dialed?) | phase: :idle}}
    else
      {:error, :max_children} ->
        # The last dialed connection has not left its supervisor yet.
        {:noreply, schedule(state, state.precondition_retry)}

      {:error, reason} ->
        Logger.warning("Espex dial-back to #{target_label(state)} failed: #{inspect(reason)}")
        {:noreply, retry(state)}
    end
  end

  # A dial dropped while it was connecting: nobody wants its socket.
  def handle_info({:dial_result, _stale, result}, state) do
    with {:ok, socket} <- result, do: :gen_tcp.close(socket)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, %{dial: {_ref, pid, monitor}} = state) do
    Logger.warning("Espex dial-back to #{target_label(state)} crashed: #{inspect(reason)}")
    {:noreply, retry(%{state | dial: nil})}
  end

  def handle_info({:DOWN, _monitor, :process, pid, _reason}, state) do
    case Map.pop(state.live, pid) do
      {nil, _live} -> {:noreply, state}
      {conn, live} -> {:noreply, connection_down(%{state | live: live}, conn)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast({:hello, :dialed, pid, _peer}, state) do
    {:noreply, state |> track(pid, :dialed?) |> mark_hello(pid)}
  end

  # A target client: drop any dial in flight, reset the backoff, and
  # learn where it came from.
  def handle_cast({:hello, :target, pid, peer}, state) do
    state =
      state
      |> track(pid, :target?)
      |> mark_hello(pid)
      |> drop_dial()
      |> cancel_timer()
      |> learn(peer)

    {:noreply, %{state | phase: :idle, backoff: state.backoff_min}}
  end

  # -- Dialing ---------------------------------------------------------------

  defp try_dial(state) do
    cond do
      connected?(state) -> %{state | phase: :idle}
      state.target == nil -> schedule(state, state.precondition_retry)
      not psk?(state) -> schedule(state, state.precondition_retry)
      true -> start_dial(state)
    end
  end

  # The task only connects, then gives the socket to this process.
  defp start_dial(state) do
    dialer = self()
    ref = make_ref()
    {connect, address, port, timeout} = {state.connect, state.target, state.port, state.connect_timeout}

    case Task.Supervisor.start_child(
           state.task_supervisor,
           fn -> send(dialer, {:dial_result, ref, connect_for(dialer, connect, address, port, timeout)}) end,
           shutdown: :brutal_kill
         ) do
      {:ok, pid} ->
        %{state | phase: :connecting, dial: {ref, pid, Process.monitor(pid)}}

      {:error, reason} ->
        # Also a dropped dial still connecting: it ends within the timeout.
        Logger.debug("Espex dial-back not started: #{inspect(reason)}")
        schedule(state, state.precondition_retry)
    end
  end

  # Runs in the dial task.
  defp connect_for(dialer, connect, address, port, timeout) do
    with {:ok, socket} <- connect.(address, port, timeout) do
      case :gen_tcp.controlling_process(socket, dialer) do
        :ok ->
          {:ok, socket}

        {:error, _reason} = error ->
          :gen_tcp.close(socket)
          error
      end
    end
  end

  # The connect is not interrupted: it ends within its timeout, and its
  # result, no longer awaited, is closed on arrival.
  defp drop_dial(%{dial: nil} = state), do: state

  defp drop_dial(%{dial: {_ref, _pid, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    %{state | dial: nil}
  end

  defp connection_down(state, conn) do
    cond do
      connected?(state) ->
        state

      conn.dialed? and not conn.hello? ->
        retry(state)

      conn.dialed? ->
        schedule(%{state | backoff: state.backoff_min}, state.delay)

      true ->
        schedule(state, state.delay)
    end
  end

  # -- Connections -------------------------------------------------------------

  defp track(state, pid, flag) do
    conn =
      case state.live do
        %{^pid => conn} -> conn
        _ -> %{monitor: Process.monitor(pid), dialed?: false, target?: false, hello?: false}
      end

    %{state | live: Map.put(state.live, pid, Map.put(conn, flag, true))}
  end

  defp mark_hello(state, pid), do: %{state | live: Map.update!(state.live, pid, &%{&1 | hello?: true})}

  defp connected?(state), do: map_size(state.live) > 0

  # -- Target ------------------------------------------------------------------

  defp learn(%{learn?: false} = state, _peer), do: state

  defp learn(state, peer) do
    case Target.from_peer(peer) do
      {:ok, target} ->
        learned = store(%{state | target: target}, target)
        :ok = Server.put_dial_back_target(learned.server, learned.target, learned.stored_target)
        learned

      {:error, reason} ->
        Logger.warning("Espex dial-back target not remembered: #{reason}")
        state
    end
  end

  defp store(%{stored_target: target} = state, target), do: state

  defp store(state, target) do
    case store_adapter(state) do
      nil ->
        if not state.warned_no_store? do
          Logger.warning(
            "Espex dial-back target #{:inet.ntoa(target)} learned with no :outgoing_target_store configured — lost on restart"
          )
        end

        %{state | warned_no_store?: true}

      adapter ->
        case adapter.store_target(target) do
          :ok ->
            %{state | stored_target: target}

          other ->
            Logger.warning("Espex dial-back target not stored, retried on the next hello: #{inspect(other)}")
            state
        end
    end
  catch
    kind, reason ->
      Logger.warning("Espex dial-back target store #{crash_label(kind, reason)}, retried on the next hello")
      state
  end

  defp crash_label(:error, exception) when is_exception(exception), do: "raised #{inspect(exception.__struct__)}"
  defp crash_label(kind, reason), do: "#{kind}: #{inspect(reason)}"

  # -- Helpers -----------------------------------------------------------------

  # Read per use, so Espex.update_adapters/2 applies.
  defp store_adapter(state), do: Server.adapters(state.server).outgoing_target_store

  defp psk?(state), do: DeviceConfig.encrypted?(Server.device_config(state.server))

  defp retry(state) do
    wait = Backoff.jittered(state.backoff, state.random)
    schedule(%{state | backoff: Backoff.next(state.backoff)}, wait)
  end

  defp schedule(state, ms) do
    state = cancel_timer(state)
    token = make_ref()
    %{state | phase: :waiting, timer: {token, Process.send_after(self(), {:tick, token}, ms)}}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: {_token, ref}} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp target_label(%{target: nil}), do: "no target"
  defp target_label(state), do: "#{:inet.ntoa(state.target)}:#{state.port}"
end
