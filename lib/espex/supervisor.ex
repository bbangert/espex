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
        entity_provider: MyApp.MyEntities,
        mdns: Espex.Mdns.MdnsLite
      )

  Any adapter key omitted disables that feature. Pass `:mdns` with an
  `Espex.Mdns` adapter module (e.g. `Espex.Mdns.MdnsLite`) to advertise
  the server over mDNS; omit to skip.
  """

  use Supervisor

  alias Espex.{Connection, DeviceConfig, Server}
  alias Espex.Mdns.Advertiser, as: MdnsAdvertiser

  @adapter_keys [:serial_proxy, :zwave_proxy, :infrared_proxy, :entity_provider]

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
    num_acceptors = opts[:num_acceptors] || 10

    adapters = opts |> Keyword.take(@adapter_keys) |> Map.new()

    children =
      [
        {Registry, keys: :duplicate, name: registry_name},
        {Server, name: server_name, device_config: device_config, adapters: adapters},
        {ThousandIsland,
         port: port,
         handler_module: Connection,
         handler_options: [server_name: server_name, registry_name: registry_name],
         transport_module: ThousandIsland.Transports.TCP,
         transport_options: [nodelay: true],
         num_acceptors: num_acceptors}
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

  defp normalise_device_config(%DeviceConfig{} = config), do: config
  defp normalise_device_config(opts) when is_list(opts), do: DeviceConfig.new(opts)
  defp normalise_device_config(nil), do: DeviceConfig.new()
end
