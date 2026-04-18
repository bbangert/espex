defmodule Espex.Test.FakeMdnsAdapter do
  @moduledoc false
  # Records every advertise/withdraw call into a per-test Agent so tests
  # can assert on what Espex.Mdns.Advertiser did. Start the Agent in
  # test setup and name it (e.g. via the test's `:test` tag) so parallel
  # tests don't collide.

  @behaviour Espex.Mdns

  @default_agent __MODULE__

  @impl Espex.Mdns
  def advertise(service) do
    record({:advertise, service})
  end

  @impl Espex.Mdns
  def withdraw(id) do
    record({:withdraw, id})
  end

  # Teardown-safe recorder: test on_exit may stop the supervisor before
  # the agent depending on registration order, and we don't want the
  # advertiser to crash-log during cleanup.
  defp record(entry) do
    try do
      Agent.update(@default_agent, fn log -> [entry | log] end)
    catch
      :exit, {:noproc, _} -> :ok
    end

    :ok
  end

  @doc "Start the recording Agent. Call in `setup`."
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: @default_agent)
  end

  @doc "Snapshot the call log (oldest first)."
  def log do
    Agent.get(@default_agent, &Enum.reverse/1)
  end
end
