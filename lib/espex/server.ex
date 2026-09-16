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
  Claim ownership of serial proxy `instance` for `pid` — the SUBSCRIBE
  step of the API 1.17 single-owner rule. Returns `:ok` when the instance
  is unowned, already owned by `pid`, or owned by a connection that has
  since died (the dead owner's entries are swept first, mirroring
  upstream's `is_connection_setup` takeover), and `{:busy, other_pid}`
  when another live connection holds it.

  Espex monitors `pid` so a sudden death (TCP crash before `cleanup/1`
  runs) still releases the instance. One monitor per pid covers both
  BLE and serial ownership.
  """
  @spec claim_serial_owner(GenServer.server(), non_neg_integer(), pid()) :: :ok | {:busy, pid()}
  def claim_serial_owner(server, instance, pid) when is_pid(pid) do
    GenServer.call(server, {:claim_serial_owner, instance, pid})
  end

  @doc """
  Release ownership of serial proxy `instance` iff `pid` is the current
  owner. Idempotent — a release for a not-owned instance is a no-op.
  """
  @spec release_serial_owner(GenServer.server(), non_neg_integer(), pid()) :: :ok
  def release_serial_owner(server, instance, pid) when is_pid(pid) do
    GenServer.call(server, {:release_serial_owner, instance, pid})
  end

  @doc """
  Release every serial instance owned by `pid` in one shot and return
  the released instances. Used by `Connection.cleanup/1` on TCP close.
  """
  @spec release_all_serial_owners(GenServer.server(), pid()) :: [non_neg_integer()]
  def release_all_serial_owners(server, pid) when is_pid(pid) do
    GenServer.call(server, {:release_all_serial_owners, pid})
  end

  @doc """
  Release everything `pid` owns, of both kinds, in one call and drop its
  monitor. Returns `{ble_addresses, serial_instances}`. Used by
  `Connection.cleanup/1` on TCP close so teardown costs one round trip.
  """
  @spec release_all_owners(GenServer.server(), pid()) :: {[non_neg_integer()], [non_neg_integer()]}
  def release_all_owners(server, pid) when is_pid(pid) do
    GenServer.call(server, {:release_all_owners, pid})
  end

  @doc """
  Return the pid currently owning serial proxy `instance`, or `nil`.
  """
  @spec serial_owner(GenServer.server(), non_neg_integer()) :: pid() | nil
  def serial_owner(server, instance) do
    GenServer.call(server, {:serial_owner, instance})
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

  @doc """
  Replace or merge the stored `device_config` at runtime.

  A `%DeviceConfig{}` replaces the config wholesale after
  `DeviceConfig.validate/1` normalises its PSK. A keyword list is merged
  onto the current config via `DeviceConfig.merge/2`, so any key omitted
  — notably a runtime-provisioned `:psk` — keeps its value. On either
  error the state is left untouched and the error returned.

  As with `update_psk/2`, the change applies to the *next* accepted
  connection only: each connection snapshots the config at accept time,
  so live connections keep advertising what they saw at connect. Call
  `Espex.disconnect_clients/1` afterwards to make clients re-read it.
  """
  @spec update_device_config(GenServer.server(), DeviceConfig.t() | keyword()) :: :ok | {:error, term()}
  def update_device_config(server \\ __MODULE__, config_or_opts)

  def update_device_config(server, %DeviceConfig{} = config) do
    GenServer.call(server, {:update_device_config, config})
  end

  def update_device_config(server, opts) when is_list(opts) do
    GenServer.call(server, {:update_device_config, opts})
  end

  @doc """
  Replace some or all of the configured adapter modules at runtime.

  `changes` is a keyword list or map of feature → module (or `nil` to
  disable the feature); keys omitted keep their current adapter. See
  `ServerState.merge_adapters/2` for the validation and error shapes.

  As with `update_device_config/2`, the change applies to the *next*
  accepted connection: each connection captures the adapter map, the
  entity lists it produces, and the `DeviceInfo` feature flags derived
  from it at accept time. Call `Espex.disconnect_clients/1` afterwards so
  clients re-read them.
  """
  @spec update_adapters(GenServer.server(), keyword() | map()) :: :ok | {:error, term()}
  def update_adapters(server \\ __MODULE__, changes) when is_list(changes) or is_non_struct_map(changes) do
    GenServer.call(server, {:update_adapters, changes})
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
        new_state =
          state
          |> ensure_monitor(pid)
          |> ServerState.put_ble_owner(address, pid)

        {:reply, :ok, new_state}

      ^pid ->
        {:reply, :ok, state}

      other ->
        {:reply, {:busy, other}, state}
    end
  end

  def handle_call({:release_ble_owner, address, pid}, _from, state) do
    {new_state, dropped?} = ServerState.drop_ble_owner(state, address, pid)
    {:reply, :ok, maybe_demonitor(new_state, pid, dropped?)}
  end

  def handle_call({:release_all_ble_owners, pid}, _from, state) do
    {new_state, addresses} = ServerState.drop_all_ble_owners(state, pid)
    {:reply, addresses, maybe_demonitor(new_state, pid, true)}
  end

  def handle_call({:ble_owner, address}, _from, state) do
    {:reply, ServerState.ble_owner(state, address), state}
  end

  def handle_call({:claim_serial_owner, instance, pid}, _from, state) do
    case ServerState.serial_owner(state, instance) do
      nil ->
        {:reply, :ok, claim_serial(state, instance, pid)}

      ^pid ->
        {:reply, :ok, state}

      other ->
        # The DOWN sweep is the durable release; this only covers the
        # window between the old owner's death and the Server processing
        # its DOWN, so a reconnecting client is not refused by a ghost.
        # The sweep drops everything the dead pid held (BLE addresses and
        # every serial instance), exactly what its DOWN would have done.
        if Process.alive?(other) do
          {:reply, {:busy, other}, state}
        else
          {:reply, :ok, state |> sweep_owner(other) |> claim_serial(instance, pid)}
        end
    end
  end

  def handle_call({:release_serial_owner, instance, pid}, _from, state) do
    {new_state, dropped?} = ServerState.drop_serial_owner(state, instance, pid)
    {:reply, :ok, maybe_demonitor(new_state, pid, dropped?)}
  end

  def handle_call({:release_all_serial_owners, pid}, _from, state) do
    {new_state, instances} = ServerState.drop_all_serial_owners(state, pid)
    {:reply, instances, maybe_demonitor(new_state, pid, true)}
  end

  def handle_call({:release_all_owners, pid}, _from, state) do
    {state, addresses} = ServerState.drop_all_ble_owners(state, pid)
    {state, instances} = ServerState.drop_all_serial_owners(state, pid)
    {:reply, {addresses, instances}, demonitor(state, pid)}
  end

  def handle_call({:serial_owner, instance}, _from, state) do
    {:reply, ServerState.serial_owner(state, instance), state}
  end

  def handle_call({:update_psk, key}, _from, state) do
    case DeviceConfig.put_psk(state.device_config, key) do
      {:ok, config} -> {:reply, :ok, ServerState.put_device_config(state, config)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:update_device_config, config_or_opts}, _from, state) do
    result =
      case config_or_opts do
        %DeviceConfig{} = config -> DeviceConfig.validate(config)
        opts when is_list(opts) -> DeviceConfig.merge(state.device_config, opts)
      end

    case result do
      {:ok, config} -> {:reply, :ok, ServerState.put_device_config(state, config)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:update_adapters, changes}, _from, state) do
    case ServerState.merge_adapters(state, changes) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Connection process died without releasing; sweep everything it
    # owned (BLE addresses and serial instances) so future claims succeed.
    {:noreply, sweep_owner(state, pid)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp claim_serial(state, instance, pid) do
    state
    |> ensure_monitor(pid)
    |> ServerState.put_serial_owner(instance, pid)
  end

  defp ensure_monitor(state, pid) do
    case ServerState.owner_monitor(state, pid) do
      nil -> ServerState.put_owner_monitor(state, pid, Process.monitor(pid))
      _ref -> state
    end
  end

  # Drop the shared monitor once the pid owns nothing of either kind.
  defp maybe_demonitor(state, pid, true = _released?) do
    if ServerState.pid_owns_any?(state, pid), do: state, else: demonitor(state, pid)
  end

  defp maybe_demonitor(state, _pid, false), do: state

  # Release everything `pid` owns, of both kinds, and forget its monitor.
  defp sweep_owner(state, pid) do
    {state, _addresses} = ServerState.drop_all_ble_owners(state, pid)
    {state, _instances} = ServerState.drop_all_serial_owners(state, pid)
    demonitor(state, pid)
  end

  defp demonitor(state, pid) do
    case ServerState.pop_owner_monitor(state, pid) do
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
