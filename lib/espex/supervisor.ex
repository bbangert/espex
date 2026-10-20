defmodule Espex.Supervisor do
  @moduledoc """
  Top-level supervisor for an Espex server instance.

  Starts children in `:rest_for_one` order:

    1. `Registry` (duplicate keys) — fan-out point for `Espex.push_state/2`.
    2. `Registry` (unique keys) — per-connection client-info snapshots.
    3. `Task.Supervisor` (internal) — runs fire-and-forget work such as
       `c:Espex.ConnectionListener.connections_changed/0` notifications.
    4. A cross-connection state server (internal) — holds the device
       config and adapter modules.
    5. An IR/RF transmit queue (internal) — runs
       `c:Espex.InfraredProxy.transmit_raw/3` calls off the connections.
    6. A `Task.Supervisor` (internal) for the transmit queue's tasks.
    7. A dial-back dialer, its connection's `DynamicSupervisor` and its
       `Task.Supervisor` (internal) — only when `:outgoing_connection`
       is configured.
    8. `ThousandIsland` — TCP acceptor pool that spawns a per-client
       connection handler process (internal).
    9. An mDNS advertiser GenServer (internal) — optional, started
       only when `:mdns` is configured.

  If the server child crashes, everything after it restarts too, so live
  connections drop rather than hold stale references. A crash of the
  transmit queue or the dialer likewise drops the connections, so no
  client waits on a transmit reply that can never come, and no
  connection outlives the dialer that knew of it.

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
        sendspin: MyApp.MySendspin,         # reports a Sendspin client (Espex.Sendspin)
        wizard: MyApp.MyWizard,             # device wizard (Espex.Wizard, OTP 28+)
        home_assistant_states: MyApp.HAStates, # Home Assistant states (Espex.HomeAssistantStates)
        outgoing_connection: [port: 6054],  # dial-back (see below)
        outgoing_target_store: MyApp.TargetStore, # keeps the learned dial-back target
        mdns: Espex.Mdns.MdnsLite,
        keepalive_idle_ms: 60_000,            # inbound silence before we ping
        keepalive_grace_ms: 60_000,           # further silence before we close
        disconnect_grace_ms: 2_000,           # wait for DisconnectResponse before closing
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

  ## Dial-back

  `:outgoing_connection` (new in 0.12.0) makes the node dial Home
  Assistant when no client is connected, for networks where Home
  Assistant cannot reach the node (API 1.18, as ESPHome's
  `outgoing_connection:`). Home Assistant listens on port 6054 and
  matches the node by the MAC in its Noise hello.

      outgoing_connection: [
        host: "192.168.1.10",   # an IP address, no DNS; omit to learn it
        port: 6054,             # default 6054, for host and learned target alike
        delay: 60_000,          # ms; default 60 s
        target: {192, 168, 1, 10} # a learned target saved earlier, to dial after boot
      ]

    * Dial-back is Noise only: the device config needs a `:psk`, or
      `accepts_key_provisioning: true` for a key provisioned later.
      Without a key the node waits and checks again every 5 s.
    * Without `host`, the target is learned: a client whose hello sets
      `outgoing_connection_target` over Noise becomes the target, and
      its IP address is remembered and passed to the
      `:outgoing_target_store` adapter (`Espex.OutgoingTargetStore`).
      Home Assistant does this for the node's own config entry.
      Link-local IPv6 addresses are not remembered: they cannot be
      dialed without a scope id. With `host`, nothing is learned. On a
      keyless node with `accepts_key_provisioning`, the client that
      provisions the key can then make itself the target; set `host`
      if that matters on your network.
    * The first dial is `delay` after start. While a target client or
      the dialed connection is connected, nothing is dialed; when it
      goes, the node waits `delay` for it to return, then dials. A
      failed dial — refused, 10 s without a connection, or a connection
      closed before its hello — waits 5 s, doubling up to 300 s, ±20 %.
    * The dialed connection speaks first: the node sends its Noise hello
      as soon as the socket opens, and stays the Noise responder. It is
      otherwise a normal connection: `Espex.connected_clients/1` lists
      it and an `Espex.ConnectionListener` hears about it.
    * The dialed connection does not count against ThousandIsland's
      connection limits, and its `:connection` telemetry span has a
      parent span that was never started.
    * `DeviceInfoResponse.api_outgoing_connection_supported` is set on
      every connection while dial-back is configured.

  The options are checked at start; a bad one raises `ArgumentError`.

  ## Runtime reconfiguration

  `Espex.update_device_config/2` swaps the `%DeviceConfig{}` new
  connections are built from, `Espex.update_adapters/2` swaps the adapter
  modules, and `Espex.disconnect_clients/1` asks every connected client
  to disconnect and come back — together they make Home Assistant re-read
  `DeviceInfo` and the entity list without restarting this tree. All
  three, and the option below, are new in 0.10.0. `disconnect_grace_ms`
  bounds how long a connection waits for the client's
  `DisconnectResponse` before closing the socket anyway.
  """

  use Supervisor

  alias Espex.{Connection, DeviceConfig, InfraredQueue, Server}
  alias Espex.Mdns.Advertiser, as: MdnsAdvertiser

  @adapter_keys [
    :serial_proxy,
    :zwave_proxy,
    :infrared_proxy,
    :bluetooth_scanner,
    :bluetooth_proxy,
    :entity_provider,
    :psk_store,
    :connection_listener,
    :sendspin,
    :wizard,
    :home_assistant_states,
    :outgoing_target_store
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

  # Upper bound on in-flight connection-listener notifications per instance.
  @max_listener_tasks 16

  # Upper bound on concurrent IR/RF transmits: one per adapter module.
  @max_infrared_tasks 8

  @impl Supervisor
  def init(opts) do
    device_config = normalise_device_config(opts[:device_config])
    port = opts[:port] || device_config.port
    supervisor_name = Keyword.get(opts, :name, __MODULE__)
    server_name = opts[:server_name] || Server
    registry_name = registry_name(server_name)
    client_registry_name = client_registry_name(server_name)
    task_supervisor_name = task_supervisor_name(server_name)
    num_acceptors = opts[:num_acceptors] || 10

    adapters = opts |> Keyword.take(@adapter_keys) |> Map.new()
    check_wizard_available!(adapters)
    outgoing = outgoing_connection!(opts[:outgoing_connection], device_config)
    read_timeout = opts[:read_timeout] || 180_000

    # Built once: the listener's connections and the dialed one run the
    # same handler with the same options.
    handler_options =
      [
        server_name: server_name,
        registry_name: registry_name,
        client_registry: client_registry_name,
        task_supervisor: task_supervisor_name,
        infrared_queue: infrared_queue_name(server_name),
        keepalive_idle_ms: opts[:keepalive_idle_ms] || 60_000,
        keepalive_grace_ms: opts[:keepalive_grace_ms] || 60_000,
        disconnect_grace_ms: opts[:disconnect_grace_ms] || 2_000
      ] ++ if(outgoing, do: [dialer: dialer_name(server_name), outgoing_connection?: true], else: [])

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
        # Supervises detached connection-listener notifications. Started
        # before the listener so it outlives every connection on shutdown
        # (:rest_for_one stops children in reverse order), letting the
        # final disconnect notification still be dispatched. Bounded so a
        # slow listener under connection churn sheds notifications instead
        # of accumulating tasks (each is only a best-effort re-query hint).
        {Task.Supervisor, name: task_supervisor_name, max_children: @max_listener_tasks},
        {Server, name: server_name, device_config: device_config, adapters: adapters, registry_name: registry_name},
        # IR/RF transmits run here, off the connections. The queue comes
        # first so its restart also restarts its tasks: a new queue never
        # overlaps a frame an old one started. Its own Task.Supervisor,
        # because the one above sheds work by design.
        {InfraredQueue,
         name: infrared_queue_name(server_name), task_supervisor: infrared_task_supervisor_name(server_name)},
        {Task.Supervisor, name: infrared_task_supervisor_name(server_name), max_children: @max_infrared_tasks}
      ] ++
        dialer_children(outgoing, server_name, handler_options, read_timeout) ++
        [
          {
            ThousandIsland,
            # Hard backstop only: the Connection-level keepalive ping keeps the
            # inbound side of healthy connections audible well inside this
            # (ThousandIsland's default of 60s would reap busy-but-quiet
            # clients — see "Keepalive" in the moduledoc).
            port: port,
            handler_module: Connection,
            handler_options: handler_options,
            transport_module: ThousandIsland.Transports.TCP,
            transport_options: [nodelay: true],
            read_timeout: read_timeout,
            num_acceptors: num_acceptors
          }
        ] ++ mdns_children(opts, device_config, supervisor_name)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp check_wizard_available!(%{wizard: wizard}) when wizard != nil do
    if not Espex.Wizard.available?() do
      raise ArgumentError,
            "the :wizard adapter #{inspect(wizard)} needs OTP 28 or newer, which has the :zstd module " <>
              "the device wizard is compressed with; this node runs OTP #{System.otp_release()}"
    end
  end

  defp check_wizard_available!(_adapters), do: :ok

  @outgoing_keys [:host, :port, :delay, :target]
  # Test-only overrides of the dialer's timings (see Espex.Dialer).
  @outgoing_private_keys [:connect_timeout, :precondition_retry, :backoff_min, :random, :dial]

  defp outgoing_connection!(nil, _device_config), do: nil
  defp outgoing_connection!(false, _device_config), do: nil

  defp outgoing_connection!(opts, device_config) when is_list(opts) do
    case Keyword.keys(opts) -- (@outgoing_keys ++ @outgoing_private_keys) do
      [] -> :ok
      [key | _] -> outgoing_invalid!("unknown key #{inspect(key)}")
    end

    if not (DeviceConfig.encrypted?(device_config) or device_config.accepts_key_provisioning) do
      outgoing_invalid!("dial-back is Noise only: set a :psk, or accepts_key_provisioning: true")
    end

    port = Keyword.get(opts, :port, 6054)
    delay = Keyword.get(opts, :delay, 60_000)
    if port not in 1..65_535//1, do: outgoing_invalid!(":port #{inspect(port)} is not 1-65535")
    if not (is_integer(delay) and delay >= 0), do: outgoing_invalid!(":delay #{inspect(delay)} is not a time in ms")

    Keyword.take(opts, @outgoing_private_keys) ++
      [
        host: outgoing_address!(opts[:host], :host),
        target: outgoing_address!(opts[:target], :target),
        port: port,
        delay: delay
      ]
  end

  defp outgoing_connection!(other, _device_config),
    do: outgoing_invalid!("expected a keyword list, got #{inspect(other)}")

  defp outgoing_address!(nil, _key), do: nil

  defp outgoing_address!(value, key) do
    case Espex.Dialer.Target.parse(value) do
      {:ok, ip} -> ip
      {:error, message} -> outgoing_invalid!("#{inspect(key)} #{message}")
    end
  end

  @spec outgoing_invalid!(String.t()) :: no_return()
  defp outgoing_invalid!(message), do: raise(ArgumentError, "invalid :outgoing_connection: " <> message)

  # The dialer goes first: its crash restarts the dialed connection's
  # supervisor and the listener, so no connection outlives the dialer
  # that knew of it.
  defp dialer_children(nil, _server_name, _handler_options, _read_timeout), do: []

  defp dialer_children(outgoing, server_name, handler_options, read_timeout) do
    [
      {Espex.Dialer,
       Keyword.merge(outgoing,
         name: dialer_name(server_name),
         server: server_name,
         connection_supervisor: dialer_connection_supervisor_name(server_name),
         task_supervisor: dialer_task_supervisor_name(server_name),
         handler_options: [dialed: true] ++ handler_options,
         read_timeout: read_timeout
       )},
      # One dialed connection and one dial at a time, as upstream.
      {DynamicSupervisor, name: dialer_connection_supervisor_name(server_name), max_children: 1},
      {Task.Supervisor, name: dialer_task_supervisor_name(server_name), max_children: 1}
    ]
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

  # Conventional name of the per-instance Task.Supervisor (internal).
  @doc false
  @spec task_supervisor_name(atom()) :: atom()
  def task_supervisor_name(server_name), do: Module.concat(server_name, "TaskSupervisor")

  # Conventional names of the IR/RF transmit queue and its Task.Supervisor (internal).
  @doc false
  @spec infrared_queue_name(atom()) :: atom()
  def infrared_queue_name(server_name), do: Module.concat(server_name, "InfraredQueue")

  @doc false
  @spec infrared_task_supervisor_name(atom()) :: atom()
  def infrared_task_supervisor_name(server_name), do: Module.concat(server_name, "InfraredTaskSupervisor")

  # Conventional names of the dial-back processes (internal).
  @doc false
  @spec dialer_name(atom()) :: atom()
  def dialer_name(server_name), do: Module.concat(server_name, "Dialer")

  @doc false
  @spec dialer_connection_supervisor_name(atom()) :: atom()
  def dialer_connection_supervisor_name(server_name), do: Module.concat(server_name, "DialerConnectionSupervisor")

  @doc false
  @spec dialer_task_supervisor_name(atom()) :: atom()
  def dialer_task_supervisor_name(server_name), do: Module.concat(server_name, "DialerTaskSupervisor")

  @doc """
  Return the conventional Registry name for a given server name.
  """
  @spec registry_name(atom()) :: atom()
  def registry_name(server_name), do: Module.concat(server_name, "Registry")

  @doc since: "0.5.0"
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
