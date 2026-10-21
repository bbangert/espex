defmodule Espex.Dialer.Supervisor do
  @moduledoc false

  # The dial-back dialer and the two supervisors it uses: one dialed
  # connection and one dial task at a time, as upstream. The dialer comes
  # after them, so they exist when it first dials and it stops before
  # them. :one_for_all with max_restarts: 0, so any fault takes the whole
  # subtree down and the parent restarts it together with the listener:
  # no connection outlives the dialer that knew of it.

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl Supervisor
  def init(opts) do
    dialer_opts = Keyword.fetch!(opts, :dialer)

    Supervisor.init(
      [
        {DynamicSupervisor, name: Keyword.fetch!(dialer_opts, :connection_supervisor), max_children: 1},
        {Task.Supervisor, name: Keyword.fetch!(dialer_opts, :task_supervisor), max_children: 1},
        {Espex.Dialer, dialer_opts}
      ],
      strategy: :one_for_all,
      max_restarts: 0
    )
  end
end
