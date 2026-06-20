defmodule Espex.Supervisor do
  @moduledoc """
  Top-level supervisor for an Espex server instance.

  Starts children in `:rest_for_one` order:

    1. `Registry` (duplicate keys) — fan-out point for `Espex.push_state/2`.
    2. A cross-connection state server (internal) — holds the device
       config and adapter modules.
    3. `ThousandIsland` — TCP acceptor pool that spawns a per-client
       connection handler process (internal).
    4. An mDNS advertiser GenServer (internal) — optional, started
       only when `:mdns` is configured.

  If the server child crashes, the listener and advertiser restart
  too, so live connections drop rather than hold stale references.

  Configuration is passed as keyword options:

      Espex.Supervisor.start_link(
        device_config: [name: "my-device"],   # or a %DeviceConfig{}
        port: 6053,                           # overrides device_config.port
        name: :my_espex,                      # supervisor registered name
        server_name: MyApp.EspexServer,       # Espex.Server registered name
        num_acceptors: 10,
        serial_proxy: MyApp.MySerialAdapter,
        zwave_proxy: MyApp.MyZWaveAdapter,
        infrared_proxy: MyApp.MyIRAdapter,
        bluetooth_scanner: MyApp.MyBLEScanner,
        bluetooth_proxy: MyApp.MyBLEProxy,
        entity_provider: MyApp.MyEntities,
        psk_store: MyApp.MyPskStore,        # persists a runtime-provisioned PSK
        connection_listener: MyApp.Tracker, # notified when the connected-client set changes
        mdns: Espex.Mdns.MdnsLite,
        keepalive_idle_ms: 60_000,            # inbound silence before we ping
        keepalive_grace_ms: 60_000,           # further silence before we close
        read_timeout: 180_000                 # hard transport-level backstop
      )

  Any adapter key omitted disables that feature. Pass `:mdns` with an
  `Espex.Mdns` adapter module (e.g. `Espex.Mdns.MdnsLite`) to advertise
  the server over mDNS; omit to skip. Pass `:psk_store` with an
  `Espex.PskStore` module to persist a Noise PSK that Home Assistant
  provisions or rotates at runtime; omit to apply provisioned keys to
  the running server only (lost on restart, with a warning). Pass
  `:connection_listener` with an `Espex.ConnectionListener` module to be
  notified when the connected-client set changes; start it before the
  Espex child (`:rest_for_one`) so it is ready when the listener opens.

  ## Keepalive

  The server pings idle clients the way real ESPHome firmware does:
  after `keepalive_idle_ms` without inbound bytes it sends a
  `PingRequest`, and closes only after `keepalive_grace_ms` more of
  silence. This matters because aioesphomeapi (Home Assistant) skips its
  own client→device pings whenever it is *receiving* data — a device that
  streams (e.g. BLE advertisements) therefore sees a permanently silent
  inbound side on a healthy connection, and any naive read timeout will
  cycle it. `read_timeout` (passed through to ThousandIsland) is a hard
  backstop that reaps connections wedged at the transport level. Keep it
  above `keepalive_idle_ms + keepalive_grace_ms` so a healthy-but-idle
  client always gets its full ping-and-grace window before ThousandIsland
  times out — the 180 s default clears the 60 s + 60 s keepalive defaults;
  if you shorten `read_timeout` or lengthen the keepalive intervals, raise
  it to match.
  """

  use Supervisor

  alias Espex.{Connection, DeviceConfig, Server}
  alias Espex.Mdns.Advertiser, as: MdnsAdvertiser

  @adapter_keys [
    :serial_proxy,
    :zwave_proxy,
    :infrared_proxy,
    :bluetooth_scanner,
    :bluetooth_proxy,
    :entity_provider,
    :psk_store,
    :connection_listener
  ]

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Return the port the listener is currently bound to. Useful when
  starting the server with `port: 0` (ephemeral) — typically in tests.
  """
  @spec bound_port(Supervisor.supervisor()) :: {:ok, :inet.port_number()} | {:error, term()}
  def bound_port(supervisor) do
    case find_listener(supervisor) do
      nil ->
        {:error, :listener_not_found}

      pid ->
        case ThousandIsland.listener_info(pid) do
          {:ok, {_address, port}} -> {:ok, port}
          :error -> {:error, :listener_not_ready}
        end
    end
  end

  defp find_listener(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {{ThousandIsland, _ref}, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  @impl Supervisor
  def init(opts) do
    device_config = normalise_device_config(opts[:device_config])
    port = opts[:port] || device_config.port
    supervisor_name = Keyword.get(opts, :name, __MODULE__)
    server_name = opts[:server_name] || Server
    registry_name = registry_name(server_name)
    client_registry_name = client_registry_name(server_name)
    num_acceptors = opts[:num_acceptors] || 10

    adapters = opts |> Keyword.take(@adapter_keys) |> Map.new()

    children =
      [
        # Duplicate-key registry: many connections under the single
        # `:subscribers` key, used for push_state/2 fan-out.
        {Registry, keys: :duplicate, name: registry_name},
        # Unique-key registry keyed by connection pid, holding each
        # connection's mutable Espex.ClientInfo snapshot. Unique (not
        # duplicate) because Registry.update_value/3 — the per-frame
        # snapshot refresh — is only supported on unique registries.
        {Registry, keys: :unique, name: client_registry_name},
        {Server, name: server_name, device_config: device_config, adapters: adapters},
        {
          ThousandIsland,
          # Hard backstop only: the Connection-level keepalive ping keeps the
          # inbound side of healthy connections audible well inside this
          # (ThousandIsland's default of 60s would reap busy-but-quiet
          # clients — see "Keepalive" in the moduledoc).
          port: port,
          handler_module: Connection,
          handler_options: [
            server_name: server_name,
            registry_name: registry_name,
            client_registry: client_registry_name,
            keepalive_idle_ms: opts[:keepalive_idle_ms] || 60_000,
            keepalive_grace_ms: opts[:keepalive_grace_ms] || 60_000
          ],
          transport_module: ThousandIsland.Transports.TCP,
          transport_options: [nodelay: true],
          read_timeout: opts[:read_timeout] || 180_000,
          num_acceptors: num_acceptors
        }
      ] ++ mdns_children(opts, device_config, supervisor_name)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Builds the advertiser child spec when the caller opted in via :mdns.
  defp mdns_children(opts, device_config, supervisor_name) do
    case Keyword.get(opts, :mdns) do
      adapter when is_atom(adapter) and adapter not in [nil, false] ->
        [
          {MdnsAdvertiser,
           adapter: adapter, device_config: device_config, supervisor_name: supervisor_name, port: opts[:port]}
        ]

      _ ->
        []
    end
  end

  @doc """
  Return the conventional Registry name for a given server name.
  """
  @spec registry_name(atom()) :: atom()
  def registry_name(server_name), do: Module.concat(server_name, "Registry")

  @doc """
  Return the conventional connected-clients Registry name for a given
  server name. This is the unique-key registry that backs
  `Espex.connected_clients/1`.
  """
  @spec client_registry_name(atom()) :: atom()
  def client_registry_name(server_name), do: Module.concat(server_name, "ClientRegistry")

  defp normalise_device_config(%DeviceConfig{} = config), do: config
  defp normalise_device_config(opts) when is_list(opts), do: DeviceConfig.new(opts)
  defp normalise_device_config(nil), do: DeviceConfig.new()
end
