defmodule Espex do
  @moduledoc """
  ESPHome Native API server library.

  Espex implements the [ESPHome Native API](https://esphome.io/components/api.html)
  protocol over TCP, letting an Elixir application expose itself as an
  ESPHome device to clients such as Home Assistant. The wire protocol,
  connection lifecycle, and optional Noise-encrypted transport all live
  here; hardware is plugged in through behaviours.

  ## Documentation map

    * [Architecture](architecture.html) — supervision tree, the
      connection/dispatch split, wire protocol, encryption, and the
      `push_state/2` broadcast path
    * [Entity types](entity_types.html) — per-type cookbook for the
      common ESPHome entities (Switch, BinarySensor, Sensor, Button,
      Light, Cover, Climate) with proto structs and example snippets
    * `Espex.SerialProxy`, `Espex.ZWaveProxy`, `Espex.InfraredProxy`,
      `Espex.BluetoothScanner`, `Espex.BluetoothProxy`,
      `Espex.EntityProvider`, `Espex.Mdns` — the seven behaviours,
      each with callback reference and a complete example adapter

  ## Quick start

  Start under your own supervision tree:

      children = [
        {Espex,
         device_config: [name: "my-device", friendly_name: "My Device"],
         serial_proxy: MyApp.MySerialAdapter,
         zwave_proxy: MyApp.MyZWaveAdapter,
         infrared_proxy: MyApp.MyInfraredAdapter,
         entity_provider: MyApp.MyEntities}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Any adapter key you omit disables that feature. For encrypted
  transport, set `:psk` on `:device_config`:

      device_config: [
        name: "my-device",
        psk: "foIclFXDcBlfzi9oQNegJz/uRG/sgdIc956pX+GrC+A="
      ]

  For the full start option list see `Espex.Supervisor`.

  ## Pushing state

  Call `push_state/2` from anywhere in your application to broadcast
  an entity state update to every currently-connected client:

      Espex.push_state(%Espex.Proto.SensorStateResponse{
        key: 1003,
        state: 21.3,
        missing_state: false
      })

  ## Connected clients

  Enumerate the live native-API connections with `connected_clients/1`,
  and subscribe to changes by configuring an `Espex.ConnectionListener`:

      Espex.connected_clients(MyApp.EspexServer)
      #=> [%Espex.ClientInfo{peer: "192.168.1.5:54312", encrypted?: true, ...}]

  ## Runtime reconfiguration

  Change the advertised device identity, or the entity set your
  `Espex.EntityProvider` returns, without restarting the server:

      :ok = Espex.update_device_config(MyApp.EspexServer, friendly_name: "Garage Bridge")
      :ok = Espex.disconnect_clients(MyApp.EspexServer)

  `update_device_config/2` applies to the next accepted connection;
  `disconnect_clients/1` asks the current clients to leave, and Home
  Assistant reconnects a few seconds later and re-reads everything.
  """

  alias Espex.{ClientInfo, DeviceConfig, Server}
  alias Espex.Supervisor, as: EspexSupervisor

  @doc """
  `child_spec/1` — makes `{Espex, opts}` usable as a child spec.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: opts[:name] || __MODULE__,
      start: {Espex.Supervisor, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Start the full Espex supervision tree with the given options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(opts), to: Espex.Supervisor

  @doc """
  Return the running server's `%DeviceConfig{}`. Accepts an optional
  server name for non-default supervisor setups.
  """
  @spec device_config(GenServer.server()) :: DeviceConfig.t()
  def device_config(server \\ Server), do: Server.device_config(server)

  @doc """
  Replace or merge the running server's `%DeviceConfig{}`.

  Pass a keyword list to **merge** onto the current config — every key
  omitted keeps its value, so a Noise PSK that Home Assistant provisioned
  at runtime is never clobbered by a rename — or a full `%DeviceConfig{}`
  to **replace** it wholesale. Both forms validate the PSK
  (`{:error, :invalid_psk_length}`); the keyword form also refuses an
  unknown key (`{:error, {:unknown_key, key}}`) and `:port`
  (`{:error, {:immutable_key, :port}}`). Any error leaves the config
  untouched.

  The change takes effect on the **next** accepted connection. Each
  connection snapshots the config at accept time, so clients already
  connected keep the identity they saw at connect; call
  `disconnect_clients/1` afterwards — in that order — to have Home
  Assistant reconnect and re-read `DeviceInfo`.

  Two things do not follow the config at runtime: the TCP listener keeps
  the `:port` it was bound with, and an mDNS advertiser started with
  `:mdns` keeps advertising the `name` / `mac_address` it was given at
  start. Restart the supervisor to change either. Prefer changing
  `:friendly_name` over `:name`: Home Assistant identifies an ESPHome
  device by `name` and may refuse a reconnect whose name differs from the
  one it paired with.

  `server` defaults to `Espex.Server` — pass your custom name if you
  started the supervisor with `:server_name`.
  """
  @spec update_device_config(GenServer.server(), DeviceConfig.t() | keyword()) :: :ok | {:error, term()}
  def update_device_config(server \\ Server, config_or_opts) do
    Server.update_device_config(server, config_or_opts)
  end

  @doc """
  Ask every currently-connected client to disconnect.

  Each connection sends a `DisconnectRequest` — the same message ESPHome
  firmware sends before it reboots — and closes its socket once the
  client answers with `DisconnectResponse`, or after `disconnect_grace_ms`
  (see `Espex.Supervisor`) if it never does. A connection that has not
  finished its hello or Noise handshake is closed outright.

  Home Assistant treats this as an *expected* disconnect: it reconnects
  about five seconds later without backoff, sends a fresh `DeviceInfoRequest`
  and `ListEntitiesRequest`, and reconciles its entity registry against
  the answer — entities added *and* removed since the last connection
  show up. Call it after `update_device_config/2`, after the list your
  `Espex.EntityProvider.list_entities/0` returns has changed, or after
  your serial-proxy instances changed.

  Fire-and-forget: this returns `:ok` as soon as the request has been
  handed to each connection process, and nothing is sent to a client
  that is already being disconnected. Use an `Espex.ConnectionListener`
  or `connected_clients/1` to observe the drop and the return.

  `server_name` defaults to `Espex.Server`.
  """
  @spec disconnect_clients(atom()) :: :ok
  def disconnect_clients(server_name \\ Server) do
    registry = EspexSupervisor.registry_name(server_name)

    Registry.dispatch(registry, :subscribers, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, :espex_disconnect) end)
    end)
  end

  @doc """
  Broadcast an entity-state struct to every currently-connected client.

  Pass any `%Espex.Proto.*StateResponse{}` (e.g.
  `%Espex.Proto.SensorStateResponse{key: k, state: 21.3}`). Clients that
  subscribed via `SubscribeStatesRequest` will receive the frame over
  their socket.

  `server_name` defaults to `Espex.Server` — pass your custom name if
  you started the supervisor with `:server_name`.
  """
  @spec push_state(atom(), struct()) :: :ok
  def push_state(server_name \\ Server, %_{} = struct) do
    registry = EspexSupervisor.registry_name(server_name)

    Registry.dispatch(registry, :subscribers, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, {:espex_state_update, struct}) end)
    end)
  end

  @doc """
  Broadcast a Z-Wave home-ID change to **every** connected client.

  Mirrors ESPHome's `APIServer::on_zwave_proxy_request`, which sends
  `HOME_ID_CHANGE` to all active clients rather than only the subscribed
  one. Home Assistant learns the network identity from this message: the
  `zwave_js` integration starts (or updates) its config-flow the moment
  it arrives, even on a connection that never issued
  `ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE`. Broadcasting to all is what lets
  a controller hot-plugged *after* a client connected be discovered
  without a reconnect.

  A Z-Wave adapter should call this from its home-ID change path (see
  `Espex.ZWaveProxy`) instead of messaging the single subscriber. Pass
  the 4-byte big-endian home ID; a zeroed value is a valid "network
  gone" signal and is delivered as-is.

  `server_name` defaults to `Espex.Server`.
  """
  @spec push_zwave_home_id(atom(), <<_::32>>) :: :ok
  def push_zwave_home_id(server_name \\ Server, <<_::binary-size(4)>> = home_id_bytes) do
    registry = EspexSupervisor.registry_name(server_name)

    Registry.dispatch(registry, :subscribers, fn entries ->
      Enum.each(entries, fn {pid, _} ->
        send(pid, {:espex_zwave_home_id_changed, home_id_bytes})
      end)
    end)
  end

  @doc """
  List the currently-connected native-API clients as
  `Espex.ClientInfo` structs.

  This is a non-blocking read of the connection Registry — the source of
  truth for the live set. Pass a custom `:server_name` if you started the
  supervisor with one; it defaults to `Espex.Server`.

  Entries appear from TCP accept (so a client that hasn't finished its
  `HelloRequest` yet shows `client_info: nil` / `api_version: nil`) and
  vanish when the connection closes. To be told *when* the set changes
  without polling, configure an `Espex.ConnectionListener`.

      Espex.connected_clients(MyApp.EspexServer)
      #=> [%Espex.ClientInfo{client_info: "Home Assistant 2026.1.0", ...}]
  """
  @spec connected_clients(atom()) :: [ClientInfo.t()]
  def connected_clients(server_name \\ Server) do
    registry = EspexSupervisor.client_registry_name(server_name)
    # Unique-registry entries are {key, pid, value}; key/pid are ignored
    # ($_ / :_) and the ClientInfo value ($1) is returned for every entry.
    Registry.select(registry, [{{:_, :_, :"$1"}, [], [:"$1"]}])
  end
end
