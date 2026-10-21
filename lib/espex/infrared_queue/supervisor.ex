defmodule Espex.InfraredQueue.Supervisor do
  @moduledoc false

  # The IR/RF queue and the Task.Supervisor its transmits run under.
  # :one_for_all, so a new queue never overlaps a frame an old one
  # started; the tasks' supervisor comes first, so on a stop the queue
  # goes before its tasks. Connections reach the queue by name and answer
  # `false` while it is gone, so an IR fault restarts only this subtree.

  use Supervisor

  # Upper bound on concurrent IR/RF transmits: one per adapter module.
  @max_tasks 8

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl Supervisor
  def init(opts) do
    queue = Keyword.fetch!(opts, :queue)
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)

    Supervisor.init(
      [
        {Task.Supervisor, name: task_supervisor, max_children: @max_tasks},
        {Espex.InfraredQueue, name: queue, task_supervisor: task_supervisor}
      ],
      strategy: :one_for_all
    )
  end
end
