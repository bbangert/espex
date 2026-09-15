defmodule Espex.ServerState do
  @moduledoc false

  alias Espex.{ConnectionState, DeviceConfig}

  @type t :: %__MODULE__{
          device_config: DeviceConfig.t(),
          adapters: ConnectionState.adapters(),
          ble_owners: %{non_neg_integer() => pid()},
          ble_monitors: %{pid() => reference()}
        }

  @enforce_keys [:device_config]
  defstruct [
    :device_config,
    adapters: %{
      serial_proxy: nil,
      zwave_proxy: nil,
      infrared_proxy: nil,
      bluetooth_scanner: nil,
      bluetooth_proxy: nil,
      entity_provider: nil,
      psk_store: nil,
      connection_listener: nil
    },
    ble_owners: %{},
    ble_monitors: %{}
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
  Merge runtime-supplied adapter changes, returning a tagged result.

  Unlike `put_adapters/2` this checks the input: every key must be a
  known feature and every value `nil` or a loadable module. The first
  offending entry is `{:error, {:unknown_adapter, key}}` or
  `{:error, {:invalid_adapter, key, value}}` and nothing is applied.
  Structs are not accepted as `changes` (the guard rejects them).
  """
  @spec merge_adapters(t(), keyword() | map()) ::
          {:ok, t()} | {:error, {:unknown_adapter, term()} | {:invalid_adapter, atom(), term()}}
  def merge_adapters(%__MODULE__{} = state, changes) when is_list(changes) or is_non_struct_map(changes) do
    Enum.reduce_while(changes, {:ok, state}, fn
      {key, value}, {:ok, acc} when is_map_key(acc.adapters, key) ->
        if valid_adapter?(value) do
          {:cont, {:ok, %{acc | adapters: Map.put(acc.adapters, key, value)}}}
        else
          {:halt, {:error, {:invalid_adapter, key, value}}}
        end

      {key, _value}, _acc ->
        {:halt, {:error, {:unknown_adapter, key}}}
    end)
  end

  # nil disables the feature. Anything else must be a module the VM can
  # load: the adapter is first called at the next accept, so a bare atom
  # (false, a typo) would crash that connection instead of this call.
  defp valid_adapter?(nil), do: true
  defp valid_adapter?(value), do: is_atom(value) and value not in [true, false] and Code.ensure_loaded?(value)

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

  @doc """
  Return the pid that currently owns `address`, or `nil`.
  """
  @spec ble_owner(t(), non_neg_integer()) :: pid() | nil
  def ble_owner(%__MODULE__{ble_owners: owners}, address) do
    Map.get(owners, address)
  end

  @doc """
  Record `pid` as the owner of `address` and remember the monitor ref
  so a later `DOWN` sweep can fire. Caller (`Espex.Server`) is
  responsible for calling `Process.monitor/1`.
  """
  @spec put_ble_owner(t(), non_neg_integer(), pid(), reference()) :: t()
  def put_ble_owner(%__MODULE__{} = state, address, pid, monitor_ref) when is_pid(pid) do
    %{
      state
      | ble_owners: Map.put(state.ble_owners, address, pid),
        ble_monitors: Map.put_new(state.ble_monitors, pid, monitor_ref)
    }
  end

  @doc """
  Drop `address` from the ownership map iff `pid` is the current owner.
  Returns `{state, dropped?}` so the caller can decide whether to
  demonitor when this was the pid's last owned address.
  """
  @spec drop_ble_owner(t(), non_neg_integer(), pid()) :: {t(), boolean()}
  def drop_ble_owner(%__MODULE__{} = state, address, pid) do
    case Map.get(state.ble_owners, address) do
      ^pid ->
        new_owners = Map.delete(state.ble_owners, address)
        {%{state | ble_owners: new_owners}, true}

      _other ->
        {state, false}
    end
  end

  @doc """
  Drop every address owned by `pid` and remove its monitor entry.
  Returns `{state, [addresses]}` so the caller can fire adapter
  disconnects.
  """
  @spec drop_all_ble_owners(t(), pid()) :: {t(), [non_neg_integer()]}
  def drop_all_ble_owners(%__MODULE__{} = state, pid) do
    {owned, kept} =
      Map.split_with(state.ble_owners, fn {_addr, owner} -> owner == pid end)

    addresses = Map.keys(owned)
    monitors = Map.delete(state.ble_monitors, pid)

    {%{state | ble_owners: kept, ble_monitors: monitors}, addresses}
  end

  @doc """
  Pop the monitor ref for `pid`, returning `{ref, new_state}` (or
  `{nil, state}` when none registered).
  """
  @spec pop_ble_monitor(t(), pid()) :: {reference() | nil, t()}
  def pop_ble_monitor(%__MODULE__{} = state, pid) do
    {ref, monitors} = Map.pop(state.ble_monitors, pid)
    {ref, %{state | ble_monitors: monitors}}
  end

  @doc """
  Look up the monitor ref for `pid`, or `nil`.
  """
  @spec ble_monitor(t(), pid()) :: reference() | nil
  def ble_monitor(%__MODULE__{ble_monitors: monitors}, pid), do: Map.get(monitors, pid)
end
