defmodule Espex.Server do
  @moduledoc false

  use GenServer

  alias Espex.{ConnectionState, DeviceConfig, ServerState}

  @type start_opts :: [
          name: GenServer.name(),
          device_config: DeviceConfig.t() | keyword(),
          adapters: map()
        ]

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Return a snapshot of the current `%ServerState{}`.
  """
  @spec get_state(GenServer.server()) :: ServerState.t()
  def get_state(server \\ __MODULE__), do: GenServer.call(server, :get_state)

  @doc """
  Return the configured `%DeviceConfig{}`.
  """
  @spec device_config(GenServer.server()) :: DeviceConfig.t()
  def device_config(server \\ __MODULE__), do: GenServer.call(server, :device_config)

  @doc """
  Return the full adapter registry.
  """
  @spec adapters(GenServer.server()) :: ConnectionState.adapters()
  def adapters(server \\ __MODULE__), do: GenServer.call(server, :adapters)

  @doc """
  Claim ownership of `address` for `pid`. Returns `:ok` when the
  address is unowned and `{:busy, other_pid}` when another connection
  already owns it.

  Espex monitors `pid` so a sudden death (TCP crash before
  `cleanup/1` runs) still releases the address — defence in depth.
  """
  @spec claim_ble_owner(GenServer.server(), non_neg_integer(), pid()) :: :ok | {:busy, pid()}
  def claim_ble_owner(server, address, pid) when is_pid(pid) do
    GenServer.call(server, {:claim_ble_owner, address, pid})
  end

  @doc """
  Release ownership of `address` iff `pid` is the current owner.
  Idempotent — a release for a not-owned address is a no-op.
  """
  @spec release_ble_owner(GenServer.server(), non_neg_integer(), pid()) :: :ok
  def release_ble_owner(server, address, pid) when is_pid(pid) do
    GenServer.call(server, {:release_ble_owner, address, pid})
  end

  @doc """
  Release every address owned by `pid` in one shot. Returns the list
  of released addresses so the caller can fire `disconnect/1` on the
  adapter for each. Used by `Connection.cleanup/1` on TCP close.
  """
  @spec release_all_ble_owners(GenServer.server(), pid()) :: [non_neg_integer()]
  def release_all_ble_owners(server, pid) when is_pid(pid) do
    GenServer.call(server, {:release_all_ble_owners, pid})
  end

  @doc """
  Return the pid currently owning `address`, or `nil`.
  """
  @spec ble_owner(GenServer.server(), non_neg_integer()) :: pid() | nil
  def ble_owner(server, address) do
    GenServer.call(server, {:ble_owner, address})
  end

  @doc """
  Replace the Noise PSK in the stored `device_config` from a
  runtime-provisioned key (e.g. a `NoiseEncryptionSetKeyRequest`).

  Validates via `DeviceConfig.put_psk/2`: on a valid 32-byte key the
  config is updated and `:ok` returned; on an invalid length the state
  is left untouched and `{:error, :invalid_psk_length}` returned. The
  new key takes effect on the *next* connection — each connection copies
  the PSK at accept time, so live connections are unaffected.
  """
  @spec update_psk(GenServer.server(), binary()) :: :ok | {:error, term()}
  def update_psk(server \\ __MODULE__, key) when is_binary(key) do
    GenServer.call(server, {:update_psk, key})
  end

  @impl GenServer
  def init(opts) do
    device_config = normalise_device_config(opts[:device_config])
    adapters = opts[:adapters] || %{}

    state =
      ServerState.new(device_config: device_config)
      |> ServerState.put_adapters(Map.new(adapters))

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state), do: {:reply, state, state}
  def handle_call(:device_config, _from, state), do: {:reply, state.device_config, state}
  def handle_call(:adapters, _from, state), do: {:reply, state.adapters, state}

  def handle_call({:claim_ble_owner, address, pid}, _from, state) do
    case ServerState.ble_owner(state, address) do
      nil ->
        ref = ensure_monitor(state, pid)
        new_state = ServerState.put_ble_owner(state, address, pid, ref)
        {:reply, :ok, new_state}

      ^pid ->
        {:reply, :ok, state}

      other ->
        {:reply, {:busy, other}, state}
    end
  end

  def handle_call({:release_ble_owner, address, pid}, _from, state) do
    {new_state, dropped?} = ServerState.drop_ble_owner(state, address, pid)

    new_state =
      if dropped? and not pid_owns_any?(new_state, pid) do
        demonitor(new_state, pid)
      else
        new_state
      end

    {:reply, :ok, new_state}
  end

  def handle_call({:release_all_ble_owners, pid}, _from, state) do
    {new_state, addresses} = ServerState.drop_all_ble_owners(state, pid)
    new_state = demonitor(new_state, pid)
    {:reply, addresses, new_state}
  end

  def handle_call({:ble_owner, address}, _from, state) do
    {:reply, ServerState.ble_owner(state, address), state}
  end

  def handle_call({:update_psk, key}, _from, state) do
    case DeviceConfig.put_psk(state.device_config, key) do
      {:ok, config} -> {:reply, :ok, ServerState.put_device_config(state, config)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Connection process died without calling release_all_ble_owners/2;
    # sweep its addresses so future claims succeed.
    {new_state, _addresses} = ServerState.drop_all_ble_owners(state, pid)
    {:noreply, new_state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp ensure_monitor(state, pid) do
    case ServerState.ble_monitor(state, pid) do
      nil -> Process.monitor(pid)
      ref -> ref
    end
  end

  defp pid_owns_any?(state, pid) do
    Enum.any?(state.ble_owners, fn {_addr, owner} -> owner == pid end)
  end

  defp demonitor(state, pid) do
    case ServerState.pop_ble_monitor(state, pid) do
      {nil, state} ->
        state

      {ref, state} ->
        Process.demonitor(ref, [:flush])
        state
    end
  end

  defp normalise_device_config(%DeviceConfig{} = config), do: config
  defp normalise_device_config(opts) when is_list(opts), do: DeviceConfig.new(opts)
  defp normalise_device_config(nil), do: DeviceConfig.new()
end
