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
      `Espex.EntityProvider`, `Espex.Mdns` — the five behaviours,
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
