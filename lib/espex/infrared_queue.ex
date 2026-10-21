defmodule Espex.InfraredQueue do
  @moduledoc false

  # Runs IR/RF transmits off the connection processes, with the reply
  # rules of ESPHome's infrared_rf component (API 1.18):
  #
  #   * Slot — one pending reply per entity key. A newer request on the
  #     key, from any connection, answers the older one `false` at once.
  #     A queued older request is dropped; a running one keeps going and
  #     its completion is ignored.
  #   * Lane — the adapter module. A lane runs one transmit_raw/3 at a
  #     time, in a task under its own Task.Supervisor, so a blocking or
  #     wedged adapter call never stalls a connection or this process.
  #   * Deadline — grace + min(air time, 8 min) from enqueue. The owner
  #     then gets `false`, and a running task is killed so the lane moves
  #     on.
  #
  # A request without `reply_to` (a client below 1.18) takes no slot and
  # is never answered, but still transmits in its lane; a newer one for
  # the same key drops it while it is queued. A requester that
  # dies loses its slots without a reply; its queued frames still go out.
  #
  # Each request carries the adapter the connection captured at accept,
  # so a transmit finishes on the adapter it started on, and a swapped
  # adapter starts a fresh lane.

  use GenServer

  require Logger

  @default_grace_ms 30_000
  @max_air_ms 8 * 60 * 1_000

  @type request :: %{
          required(:key) => non_neg_integer(),
          required(:device_id) => non_neg_integer(),
          required(:timings) => [integer()],
          required(:opts) => Espex.InfraredProxy.transmit_opts(),
          required(:adapter) => module(),
          required(:reply_to) => pid() | nil
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec transmit(GenServer.server(), request()) :: :ok
  def transmit(queue, request), do: GenServer.call(queue, {:transmit, request})

  @doc false
  @spec air_time_us([integer()], non_neg_integer()) :: non_neg_integer()
  def air_time_us(timings, repeat_count) when is_integer(repeat_count) do
    sum_abs(timings, 0) * max(repeat_count, 1)
  end

  defp sum_abs([], total), do: total
  defp sum_abs([timing | rest], total) when is_integer(timing), do: sum_abs(rest, total + abs(timing))

  @doc false
  @spec deadline_ms(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def deadline_ms(air_time_us, grace_ms) when is_integer(air_time_us) and is_integer(grace_ms) do
    grace_ms + min(div(air_time_us + 999, 1_000), @max_air_ms)
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       task_supervisor: Keyword.fetch!(opts, :task_supervisor),
       grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
       next_id: 0,
       slots: %{},
       reqs: %{},
       lanes: %{},
       monitors: %{}
     }}
  end

  @impl GenServer
  def handle_call({:transmit, request}, _from, state) do
    id = state.next_id
    air_us = air_time_us(request.timings, Keyword.get(request.opts, :repeat_count, 1))
    timer = Process.send_after(self(), {:deadline, id}, deadline_ms(air_us, state.grace_ms))
    req = Map.merge(request, %{id: id, status: :queued, timer: timer, task: nil})

    state =
      %{state | next_id: id + 1}
      |> supersede(req)
      |> claim_slot(req)
      |> enqueue(req)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:transmit_done, id, result}, state) do
    case state.reqs do
      %{^id => %{status: :running} = req} ->
        Process.demonitor(elem(req.task, 0), [:flush])
        log_result(result, req)
        {:noreply, finish(state, req, result == :ok)}

      _settled ->
        {:noreply, state}
    end
  end

  def handle_info({:deadline, id}, state) do
    case state.reqs do
      %{^id => req} ->
        outcome = if req.reply_to, do: "reported failed", else: "stopped"
        Logger.warning("Espex IR transmit for key #{req.key} overdue — #{outcome}")
        {:noreply, expire(state, req)}

      _settled ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.reqs, fn {_id, req} -> match?({^ref, _}, req.task) end) do
      {_id, req} ->
        Logger.warning("Espex IR transmit for key #{req.key} exited: #{inspect(reason)}")
        {:noreply, finish(state, req, false)}

      nil ->
        {:noreply, requester_down(state, pid)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- Slots ------------------------------------------------------------------

  # The older owner of the key hears `false` now. Queued, it never
  # transmitted, so it is dropped; running, it finishes unanswered.
  #
  # A request nobody waits on (a client below 1.18) takes no slot, but a
  # newer one for the key still drops a queued one, so such a client
  # cannot queue more than one frame per entity.
  defp supersede(state, %{reply_to: nil} = new) do
    queued_unowned? = fn {_id, req} ->
      req.key == new.key and req.adapter == new.adapter and req.reply_to == nil and req.status == :queued
    end

    case Enum.find(state.reqs, queued_unowned?) do
      {_id, old} -> drop_queued(state, old)
      nil -> state
    end
  end

  defp supersede(state, %{key: key}) do
    case state.slots do
      %{^key => old_id} ->
        old = Map.fetch!(state.reqs, old_id)
        state = reply(state, old, false)

        case old.status do
          :queued -> drop_queued(state, old)
          :running -> state
        end

      _free ->
        state
    end
  end

  defp claim_slot(state, %{reply_to: nil}), do: state

  defp claim_slot(state, %{reply_to: pid} = req) do
    %{state | slots: Map.put(state.slots, req.key, req.id), monitors: monitor(state.monitors, pid)}
  end

  # Answer the request's owner, if it still has one, and release its slot.
  defp reply(state, %{reply_to: nil}, _success?), do: state

  defp reply(state, %{reply_to: pid} = req, success?) do
    send(pid, {:espex_ir_transmit_complete, req.key, req.device_id, success?})
    release_owner(state, req)
  end

  defp release_owner(state, %{reply_to: pid} = req) do
    %{disown(state, req) | monitors: demonitor(state.monitors, pid)}
  end

  # The requester is gone: its slots are freed with no reply, and its
  # requests carry on unanswered.
  defp requester_down(state, pid) do
    case Map.pop(state.monitors, pid) do
      {nil, _monitors} ->
        state

      {_ref_count, monitors} ->
        state.reqs
        |> Enum.filter(fn {_id, req} -> req.reply_to == pid end)
        |> Enum.reduce(%{state | monitors: monitors}, fn {_id, req}, acc -> disown(acc, req) end)
    end
  end

  # Free the request's slot and leave it without anyone to answer.
  defp disown(state, req) do
    slots = if state.slots[req.key] == req.id, do: Map.delete(state.slots, req.key), else: state.slots

    reqs =
      if Map.has_key?(state.reqs, req.id), do: Map.put(state.reqs, req.id, %{req | reply_to: nil}), else: state.reqs

    %{state | slots: slots, reqs: reqs}
  end

  # One monitor per requester, counted per request it owns.
  defp monitor(monitors, pid) do
    case monitors do
      %{^pid => {ref, count}} -> Map.put(monitors, pid, {ref, count + 1})
      _ -> Map.put(monitors, pid, {Process.monitor(pid), 1})
    end
  end

  defp demonitor(monitors, pid) do
    case monitors do
      %{^pid => {ref, 1}} ->
        Process.demonitor(ref, [:flush])
        Map.delete(monitors, pid)

      %{^pid => {ref, count}} ->
        Map.put(monitors, pid, {ref, count - 1})

      _ ->
        monitors
    end
  end

  # -- Lanes ------------------------------------------------------------------

  defp enqueue(state, req) do
    lane = Map.get(state.lanes, req.adapter, %{queue: :queue.new(), running: nil})
    lane = %{lane | queue: :queue.in(req.id, lane.queue)}

    %{state | reqs: Map.put(state.reqs, req.id, req), lanes: Map.put(state.lanes, req.adapter, lane)}
    |> advance(req.adapter)
  end

  defp drop_queued(state, req) do
    Process.cancel_timer(req.timer)
    lane = Map.fetch!(state.lanes, req.adapter)
    lane = %{lane | queue: :queue.delete(req.id, lane.queue)}
    %{state | reqs: Map.delete(state.reqs, req.id), lanes: Map.put(state.lanes, req.adapter, lane)}
  end

  # The request is settled: answer its owner, forget it, and start the
  # next frame on its lane.
  defp finish(state, req, success?) do
    Process.cancel_timer(req.timer)
    state = reply(state, req, success?)
    lane = %{Map.fetch!(state.lanes, req.adapter) | running: nil}

    %{state | reqs: Map.delete(state.reqs, req.id), lanes: Map.put(state.lanes, req.adapter, lane)}
    |> advance(req.adapter)
  end

  defp expire(state, %{status: :queued} = req) do
    state |> reply(req, false) |> drop_queued(req)
  end

  defp expire(state, %{status: :running, task: {ref, pid}} = req) do
    Process.demonitor(ref, [:flush])
    _ = Task.Supervisor.terminate_child(state.task_supervisor, pid)
    finish(state, req, false)
  end

  defp advance(state, adapter) do
    lane = Map.fetch!(state.lanes, adapter)

    case {lane.running, :queue.out(lane.queue)} do
      {nil, {:empty, _}} ->
        %{state | lanes: Map.delete(state.lanes, adapter)}

      {nil, {{:value, id}, queue}} ->
        state = %{state | lanes: Map.put(state.lanes, adapter, %{lane | queue: queue})}
        start(state, Map.fetch!(state.reqs, id))

      {_running, _queue} ->
        state
    end
  end

  defp start(state, req) do
    queue = self()

    task = fn ->
      send(queue, {:transmit_done, req.id, call_adapter(req)})
    end

    case Task.Supervisor.start_child(state.task_supervisor, task, shutdown: :brutal_kill) do
      {:ok, pid} ->
        req = %{req | status: :running, task: {Process.monitor(pid), pid}}
        lane = %{Map.fetch!(state.lanes, req.adapter) | running: req.id}
        %{state | reqs: Map.put(state.reqs, req.id, req), lanes: Map.put(state.lanes, req.adapter, lane)}

      {:error, reason} ->
        Logger.warning("Espex IR transmit for key #{req.key} not started: #{inspect(reason)}")
        finish(state, req, false)
    end
  end

  # Host code: a raise is a failed transmit, not a task crash.
  defp call_adapter(req) do
    req.adapter.transmit_raw(req.key, req.timings, req.opts)
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp log_result(:ok, _req), do: :ok

  defp log_result({:error, reason}, req) do
    Logger.warning("Espex IR transmit for key #{req.key} failed: #{inspect(reason)}")
  end

  defp log_result(other, req) do
    Logger.warning("Espex IR transmit for key #{req.key} returned an unexpected value: #{inspect(other)}")
  end
end
