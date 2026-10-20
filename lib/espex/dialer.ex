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
  #   * :connecting — a dial task runs (TCP connect, up to 10 s, then the
  #     handoff).
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
  # Connections report their hellos by cast, so a connection never waits
  # on this process; their casts arrive before their :DOWN (same sender),
  # so a :DOWN knows whether the hello was seen.

  use GenServer

  require Logger

  alias Espex.{DeviceConfig, Server}
  alias Espex.Dialer.{Adopt, Backoff, Target}

  @connect_timeout_ms 10_000
  @precondition_retry_ms 5_000
  # The tree starts the dialer before its two supervisors; a tick that
  # beats them retries soon instead of waiting a precondition retry.
  @startup_retry_ms 100

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
      connection_supervisor: Keyword.fetch!(opts, :connection_supervisor),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      adopt_opts: [
        connection_supervisor: Keyword.fetch!(opts, :connection_supervisor),
        handler_options: Keyword.fetch!(opts, :handler_options),
        read_timeout: Keyword.fetch!(opts, :read_timeout),
        connect_timeout: Keyword.get(opts, :connect_timeout, @connect_timeout_ms)
      ],
      port: Keyword.fetch!(opts, :port),
      delay: Keyword.fetch!(opts, :delay),
      precondition_retry: Keyword.get(opts, :precondition_retry, @precondition_retry_ms),
      backoff_min: Keyword.get(opts, :backoff_min, Backoff.initial()),
      random: Keyword.get(opts, :random, &(:rand.uniform(&1) - 1)),
      learn?: host == nil,
      target: host || Keyword.get(opts, :target),
      # The target the store holds: a seed came from it.
      stored_target: Keyword.get(opts, :target),
      warned_no_store?: false,
      phase: :waiting,
      timer: nil,
      backoff: nil,
      dial: nil,
      live: %{}
    }

    {:ok, schedule(%{state | backoff: state.backoff_min}, state.delay)}
  end

  @impl GenServer
  def handle_info({:tick, token}, %{timer: {token, _ref}} = state) do
    {:noreply, try_dial(%{state | timer: nil})}
  end

  def handle_info({:tick, _stale}, state), do: {:noreply, state}

  def handle_info({:dial_result, ref, result}, %{dial: {ref, _pid, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    state = %{state | dial: nil}

    case result do
      {:ok, pid} ->
        {:noreply, %{track(state, pid, :dialed?) | phase: :idle}}

      {:error, :max_children} ->
        # The last dialed connection has not left its supervisor yet.
        {:noreply, schedule(state, state.precondition_retry)}

      {:error, reason} ->
        Logger.warning("Espex dial-back to #{target_label(state)} failed: #{inspect(reason)}")
        {:noreply, retry(state)}
    end
  end

  def handle_info({:dial_result, _stale, _result}, state), do: {:noreply, state}

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

  # A target client: stop any dial in flight, reset the backoff, and
  # learn where it came from. Tracked first: it may be the connection the
  # dial in flight just started, which cancel_dial/1 must not stop.
  def handle_cast({:hello, :target, pid, peer}, state) do
    state =
      state
      |> track(pid, :target?)
      |> mark_hello(pid)
      |> cancel_dial()
      |> cancel_timer()
      |> learn(peer)

    {:noreply, %{state | phase: :idle, backoff: state.backoff_min}}
  end

  # -- Dialing ---------------------------------------------------------------

  defp try_dial(state) do
    cond do
      connected?(state) -> %{state | phase: :idle}
      not tree_started?(state) -> schedule(state, @startup_retry_ms)
      state.target == nil -> schedule(state, state.precondition_retry)
      not psk?(state) -> schedule(state, state.precondition_retry)
      true -> start_dial(state)
    end
  end

  defp start_dial(state) do
    dialer = self()
    ref = make_ref()
    {address, port, opts} = {state.target, state.port, state.adopt_opts}

    case Task.Supervisor.start_child(
           state.task_supervisor,
           fn -> send(dialer, {:dial_result, ref, Adopt.dial(address, port, opts)}) end,
           shutdown: :brutal_kill
         ) do
      {:ok, pid} ->
        %{state | phase: :connecting, dial: {ref, pid, Process.monitor(pid)}}

      {:error, reason} ->
        Logger.debug("Espex dial-back not started: #{inspect(reason)}")
        schedule(state, state.precondition_retry)
    end
  end

  defp cancel_dial(%{dial: nil} = state), do: state

  # The task may already have started a connection that never got its
  # socket; anything under the supervisor that is not tracked goes too.
  defp cancel_dial(%{dial: {_ref, pid, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    _ = Task.Supervisor.terminate_child(state.task_supervisor, pid)

    for {_, child, _, _} <- DynamicSupervisor.which_children(state.connection_supervisor),
        is_pid(child) and not Map.has_key?(state.live, child) do
      DynamicSupervisor.terminate_child(state.connection_supervisor, child)
    end

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
        store(%{state | target: target}, target)

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
  rescue
    exception ->
      Logger.warning("Espex dial-back target store raised #{inspect(exception.__struct__)}, retried on the next hello")
      state
  end

  # -- Helpers -----------------------------------------------------------------

  # Read per use, so Espex.update_adapters/2 applies.
  defp store_adapter(state), do: Server.adapters(state.server).outgoing_target_store

  defp psk?(state), do: DeviceConfig.encrypted?(Server.device_config(state.server))

  defp tree_started?(state) do
    GenServer.whereis(state.task_supervisor) != nil and GenServer.whereis(state.connection_supervisor) != nil
  end

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
