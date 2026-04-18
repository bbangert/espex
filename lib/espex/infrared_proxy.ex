defmodule Espex.InfraredProxy do
  @moduledoc """
  Behaviour for infrared proxy adapters.

  Implement this to expose one or more IR devices as ESPHome entities.
  Subscribers receive IR reception events as:

      {:espex_ir_receive, key, timings}

  where `key` is the entity key (matching an `Espex.InfraredProxy.Entity`'s
  `:key` field) and `timings` is a list of pulse durations in microseconds.
  """

  alias Espex.InfraredProxy.Entity

  @typedoc """
  Options for `c:transmit_raw/3`:

    * `:carrier_frequency` — carrier frequency in Hz (defaults to 38_000)
    * `:repeat_count` — number of repeats (defaults to 1)
  """
  @type transmit_opts :: [carrier_frequency: non_neg_integer(), repeat_count: pos_integer()]

  @doc """
  Return the list of IR entities this adapter exposes.
  """
  @callback list_entities() :: [Entity.t()]

  @doc """
  Transmit a raw timing pattern on the device identified by `key`.
  """
  @callback transmit_raw(key :: non_neg_integer(), timings :: [integer()], transmit_opts()) ::
              :ok | {:error, term()}

  @doc """
  Subscribe the given pid to infrared receive events. Idempotent.
  """
  @callback subscribe(subscriber :: pid()) :: :ok

  @doc """
  Unsubscribe a previously subscribed pid. Idempotent.
  """
  @callback unsubscribe(subscriber :: pid()) :: :ok
end
