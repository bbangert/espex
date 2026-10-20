defmodule Espex.Dialer.Backoff do
  @moduledoc false

  # The dial-back retry schedule of ESPHome's OutgoingConnectionManager
  # (schedule_retry_): wait the backoff ±20 %, then double it, from 5 s
  # up to 300 s. About 5, 10, 20, 40, 80, 160, 300, 300 ... seconds.

  @min_ms 5_000
  @max_ms 300_000

  @typedoc "Returns a uniform integer in `0..(n - 1)`."
  @type random :: (pos_integer() -> non_neg_integer())

  @spec initial() :: pos_integer()
  def initial, do: @min_ms

  @spec next(pos_integer()) :: pos_integer()
  def next(backoff), do: min(backoff * 2, @max_ms)

  @doc "The wait for `backoff`: uniform within ±20 %."
  @spec jittered(pos_integer(), random()) :: non_neg_integer()
  def jittered(backoff, random \\ &default_random/1) do
    spread = div(backoff, 5)
    backoff - spread + random.(2 * spread + 1)
  end

  defp default_random(n), do: :rand.uniform(n) - 1
end
