defmodule Espex.ServerState do
  @moduledoc """
  Pure state for `Espex.Server`.

  Holds the device config and the adapter registry. Kept deliberately
  small — the per-connection snapshot work (calling adapter
  `list_instances/0` / `list_entities/0`) happens in `Espex.Connection`
  at accept time so each connection sees fresh adapter state without
  any cache to invalidate.
  """

  alias Espex.{ConnectionState, DeviceConfig}

  @type t :: %__MODULE__{
          device_config: DeviceConfig.t(),
          adapters: ConnectionState.adapters()
        }

  @enforce_keys [:device_config]
  defstruct [
    :device_config,
    adapters: %{
      serial_proxy: nil,
      zwave_proxy: nil,
      infrared_proxy: nil,
      entity_provider: nil
    }
  ]

  @doc """
  Build a new `%ServerState{}` from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Replace the configured adapters.

  Accepts a partial map — any key omitted keeps its current value.
  """
  @spec put_adapters(t(), %{optional(ConnectionState.feature()) => module() | nil}) :: t()
  def put_adapters(%__MODULE__{} = state, new_adapters) when is_map(new_adapters) do
    %{state | adapters: Map.merge(state.adapters, new_adapters)}
  end

  @doc """
  Return the adapter module configured for `feature`, or `nil`.
  """
  @spec adapter(t(), ConnectionState.feature()) :: module() | nil
  def adapter(%__MODULE__{adapters: adapters}, feature) do
    Map.get(adapters, feature)
  end

  @doc """
  Replace the device config.
  """
  @spec put_device_config(t(), DeviceConfig.t()) :: t()
  def put_device_config(%__MODULE__{} = state, %DeviceConfig{} = config) do
    %{state | device_config: config}
  end
end
