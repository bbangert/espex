defmodule Espex do
  @moduledoc """
  ESPHome Native API server library.

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

  Any adapter key omitted → that feature is disabled. See
  `Espex.Supervisor` for the full list of start options.

  ## Implementing adapters

  Four behaviours define the consumer contract for hardware:

    * `Espex.SerialProxy` — one or more serial ports exposed over the
      Native API's serial proxy feature
    * `Espex.ZWaveProxy` — a Z-Wave Serial API controller proxied to
      clients (typically Home Assistant)
    * `Espex.InfraredProxy` — IR transmit/receive devices
    * `Espex.EntityProvider` — arbitrary ESPHome entities (sensors,
      switches, etc.)
  """

  alias Espex.{DeviceConfig, Server}
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
end
