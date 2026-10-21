defmodule Espex.InfraredQueueTest do
  use ExUnit.Case, async: true

  import Espex.Test.TcpClient, only: [wait_until: 1]

  alias Espex.InfraredQueue
  alias Espex.Test.{BlockingInfraredProxy, OtherBlockingInfraredProxy}

  setup context do
    task_sup = :"ir_tasks_#{context.test}"
    queue = :"ir_queue_#{context.test}"

    start_supervised!({Task.Supervisor, name: task_sup, max_children: Map.get(context, :max_children, :infinity)})

    start_supervised!(
      {InfraredQueue, name: queue, task_supervisor: task_sup, grace_ms: Map.get(context, :grace_ms, 30_000)}
    )

    %{queue: queue}
  end

  # A request answered to this test process, or to `reply_to` when given.
  defp transmit(queue, key, tag, overrides \\ []) do
    request = %{
      key: key,
      device_id: Keyword.get(overrides, :device_id, 0),
      timings: Keyword.get(overrides, :timings, [9_000, -4_500]),
      opts: Keyword.get(overrides, :opts, []) ++ [repeat_count: 1, test: self(), tag: tag],
      adapter: Keyword.get(overrides, :adapter, BlockingInfraredProxy),
      reply_to: Keyword.get(overrides, :reply_to, self())
    }

    :ok = InfraredQueue.transmit(queue, request)
  end

  defp release(task, result \\ :ok), do: send(task, {:release, result})

  test "air time and deadline" do
    assert InfraredQueue.air_time_us([9_000, -4_500, 560], 2) == 28_120
    assert InfraredQueue.air_time_us([100], 0) == 100
    assert InfraredQueue.deadline_ms(28_120, 30_000) == 30_029
    # Air time counts up to 8 minutes.
    assert InfraredQueue.deadline_ms(3_600_000_000, 30_000) == 30_000 + 480_000
  end

  test "a transmit is answered with the adapter's result", %{queue: queue} do
    transmit(queue, 1, :a, device_id: 5)
    assert_receive {:started, :a, task}
    release(task)
    assert_receive {:espex_ir_transmit_complete, 1, 5, true}

    transmit(queue, 1, :b, device_id: 6)
    assert_receive {:started, :b, task}
    release(task, {:error, :jammed})
    assert_receive {:espex_ir_transmit_complete, 1, 6, false}
  end

  test "a newer request supersedes a running one: the old hears false at once", %{queue: queue} do
    transmit(queue, 1, :old, device_id: 1)
    assert_receive {:started, :old, old_task}

    transmit(queue, 1, :new, device_id: 2)
    assert_receive {:espex_ir_transmit_complete, 1, 1, false}
    # The lane runs one call at a time: the new frame waits for the old.
    refute_received {:started, :new, _}

    release(old_task)
    assert_receive {:started, :new, new_task}
    release(new_task)
    assert_receive {:espex_ir_transmit_complete, 1, 2, true}
    refute_received {:espex_ir_transmit_complete, 1, 1, true}
  end

  test "a newer request drops a queued one, which never transmits", %{queue: queue} do
    transmit(queue, 1, :running)
    assert_receive {:started, :running, running}

    transmit(queue, 2, :queued, device_id: 1)
    transmit(queue, 2, :newer, device_id: 2)
    assert_receive {:espex_ir_transmit_complete, 2, 1, false}

    release(running)
    assert_receive {:espex_ir_transmit_complete, 1, 0, true}
    assert_receive {:started, :newer, newer}
    refute_received {:started, :queued, _}
    release(newer)
    assert_receive {:espex_ir_transmit_complete, 2, 2, true}
  end

  test "a requester that dies loses its slot, but its frame still goes out", %{queue: queue} do
    transmit(queue, 1, :first)
    assert_receive {:started, :first, first}

    test_pid = self()

    {requester, ref} =
      spawn_monitor(fn ->
        transmit(queue, 2, :orphan, reply_to: self(), opts: [test: test_pid])
      end)

    assert_receive {:DOWN, ^ref, :process, ^requester, :normal}
    # The queue sees the requester's DOWN on its own schedule.
    wait_until(fn -> :sys.get_state(queue).slots == %{1 => 0} end)

    release(first)
    assert_receive {:started, :orphan, orphan}
    release(orphan)

    # Once the orphan settled, the queue holds nothing.
    transmit(queue, 3, :last)
    assert_receive {:started, :last, last}
    assert %{reqs: reqs} = :sys.get_state(queue)
    assert Map.keys(reqs) == [2]
    release(last)
  end

  @tag grace_ms: 50
  test "a call past its deadline is answered false and killed, and the lane moves on", %{queue: queue} do
    transmit(queue, 1, :wedged, device_id: 1)
    assert_receive {:started, :wedged, wedged}
    task_ref = Process.monitor(wedged)

    # Two seconds on air keeps the queued frame inside its own deadline.
    transmit(queue, 2, :next, device_id: 2, timings: [2_000_000])

    assert_receive {:espex_ir_transmit_complete, 1, 1, false}, 1_000
    assert_receive {:DOWN, ^task_ref, :process, ^wedged, :killed}
    assert_receive {:started, :next, next}
    release(next)
    assert_receive {:espex_ir_transmit_complete, 2, 2, true}
  end

  test "an adapter that raises is reported false", %{queue: queue} do
    transmit(queue, 1, :boom, device_id: 3, opts: [raise: true])
    assert_receive {:espex_ir_transmit_complete, 1, 3, false}
  end

  test "two adapter modules run in parallel lanes", %{queue: queue} do
    transmit(queue, 1, :a)
    transmit(queue, 2, :b, adapter: OtherBlockingInfraredProxy)

    assert_receive {:started, :a, a}
    assert_receive {:started, :b, b}

    release(b)
    assert_receive {:espex_ir_transmit_complete, 2, 0, true}
    release(a)
    assert_receive {:espex_ir_transmit_complete, 1, 0, true}
  end

  test "a request without reply_to is never answered and takes no slot", %{queue: queue} do
    transmit(queue, 1, :owner, device_id: 1)
    assert_receive {:started, :owner, owner}

    # A pre-1.18 request on the same key neither answers the owner nor
    # takes the key from it.
    transmit(queue, 1, :legacy, device_id: 2, reply_to: nil)
    refute_received {:espex_ir_transmit_complete, 1, 1, _}

    release(owner)
    assert_receive {:espex_ir_transmit_complete, 1, 1, true}
    assert_receive {:started, :legacy, legacy}
    release(legacy)

    # Settled without a reply: the next owner is not told about it either.
    transmit(queue, 1, :after, device_id: 3)
    assert_receive {:started, :after, after_task}
    refute_received {:espex_ir_transmit_complete, 1, 2, _}
    release(after_task)
    assert_receive {:espex_ir_transmit_complete, 1, 3, true}
  end

  @tag max_children: 1
  test "a transmit the task supervisor cannot start is reported false", %{queue: queue} do
    transmit(queue, 1, :a)
    assert_receive {:started, :a, a}

    transmit(queue, 2, :b, device_id: 2, adapter: OtherBlockingInfraredProxy)
    assert_receive {:espex_ir_transmit_complete, 2, 2, false}

    release(a)
    assert_receive {:espex_ir_transmit_complete, 1, 0, true}
  end

  test "an unanswered request drops a queued unanswered one for the same key", %{queue: queue} do
    transmit(queue, 1, :running, reply_to: nil)
    assert_receive {:started, :running, running}

    transmit(queue, 2, :first, reply_to: nil)
    transmit(queue, 2, :second, reply_to: nil)
    transmit(queue, 3, :other, reply_to: nil)

    release(running)
    assert_receive {:started, :second, second}
    release(second)
    assert_receive {:started, :other, other}
    release(other)
    refute_received {:started, :first, _}

    # Nothing is left queued.
    wait_until(fn -> :sys.get_state(queue).reqs == %{} end)
  end

  test "a requester with several pending transmits holds one monitor, released when they settle",
       %{queue: queue} do
    monitors = fn -> queue |> Process.whereis() |> Process.info(:monitors) |> elem(1) end

    transmit(queue, 1, :a)
    assert_receive {:started, :a, a}
    transmit(queue, 2, :b, device_id: 2)
    transmit(queue, 3, :c, device_id: 3)
    assert Enum.count(monitors.(), &(&1 == {:process, self()})) == 1

    release(a)
    assert_receive {:started, :b, b}
    release(b)
    assert_receive {:started, :c, c}
    release(c)
    assert_receive {:espex_ir_transmit_complete, 3, 3, true}

    refute {:process, self()} in monitors.()
  end
end
