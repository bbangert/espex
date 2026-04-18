defmodule Espex.Supervisor do
  @moduledoc """
  Top-level supervisor for an Espex server instance.

  Starts children in `:rest_for_one` order:

    1. `Espex.Server` — holds the `%ServerState{}` used by every
       accepted connection.
    2. `ThousandIsland` — TCP acceptor pool that spawns `Espex.Connection`
       handler processes per client.

  If `Espex.Server` crashes, the listener restarts too so live
  connections drop rather than hold stale references.

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
        entity_provider: MyApp.MyEntities
      )

  Any adapter key omitted → that feature is disabled.
  """

  use Supervisor

  alias Espex.{Connection, DeviceConfig, Server}

  @adapter_keys [:serial_proxy, :zwave_proxy, :infrared_proxy, :entity_provider]

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
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
    server_name = opts[:server_name] || Server
    registry_name = registry_name(server_name)
    num_acceptors = opts[:num_acceptors] || 10

    adapters = opts |> Keyword.take(@adapter_keys) |> Map.new()

    children = [
      {Registry, keys: :duplicate, name: registry_name},
      {Server, name: server_name, device_config: device_config, adapters: adapters},
      {ThousandIsland,
       port: port,
       handler_module: Connection,
       handler_options: [server_name: server_name, registry_name: registry_name],
       transport_module: ThousandIsland.Transports.TCP,
       transport_options: [nodelay: true],
       num_acceptors: num_acceptors}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
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
