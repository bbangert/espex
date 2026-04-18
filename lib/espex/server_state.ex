defmodule Espex.ServerState do
  @moduledoc """
  Pure state for `Espex.Server`.

  Holds the device config, the adapter registry, and a cached snapshot of
  the serial-proxy inventory. The cache lets `Espex.Connection` handlers
  grab the list once at accept time without round-tripping to the
  adapter on every `DeviceInfoRequest`.
  """

  alias Espex.{ConnectionState, DeviceConfig, SerialProxy}

  @type t :: %__MODULE__{
          device_config: DeviceConfig.t(),
          adapters: ConnectionState.adapters(),
          serial_proxies: [SerialProxy.Info.t()]
        }

  @enforce_keys [:device_config]
  defstruct [
    :device_config,
    adapters: %{
      serial_proxy: nil,
      zwave_proxy: nil,
      infrared_proxy: nil,
      entity_provider: nil
    },
    serial_proxies: []
  ]

  @doc """
  Build a new `%ServerState{}` from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Replace the configured adapters.

  Accepts a partial map — any key omitted keeps its current value. This
  lets callers update a single adapter without reconstructing the whole
  map.
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
  Replace the cached serial-proxy inventory.
  """
  @spec put_serial_proxies(t(), [SerialProxy.Info.t()]) :: t()
  def put_serial_proxies(%__MODULE__{} = state, list) when is_list(list) do
    %{state | serial_proxies: list}
  end

  @doc """
  Replace the device config.
  """
  @spec put_device_config(t(), DeviceConfig.t()) :: t()
  def put_device_config(%__MODULE__{} = state, %DeviceConfig{} = config) do
    %{state | device_config: config}
  end
end
