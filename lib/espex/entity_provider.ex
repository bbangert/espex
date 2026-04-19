defmodule Espex.EntityProvider do
  @moduledoc """
  Behaviour for entity providers — the pluggable source of custom
  ESPHome entities (sensors, switches, lights, covers, climate, …)
  beyond the built-in serial, Z-Wave, and infrared proxies.

  See the ["Entity types" guide](entity_types.html) for the specific
  proto structs and field semantics for each entity type. This module
  documents the behaviour itself and the two common patterns for
  implementing it.

  ## Callbacks

  | Callback | When called |
  |----------|-------------|
  | `c:list_entities/0` | Once per connection, when the client sends `ListEntitiesRequest` |
  | `c:initial_states/0` | Once per connection, when the client sends `SubscribeStatesRequest` |
  | `c:handle_command/1` | Each time the client issues a command struct for one of your entities |

  Return values:

    * `c:list_entities/0` and `c:initial_states/0` return lists of
      `Espex.Proto.*` structs. Use the advertisement structs
      (`ListEntities*Response`) in the first, and the state structs
      (`*StateResponse`) in the second. See the entity-types guide.
    * `c:handle_command/1` returns `:ok` on success or `{:error, term}`
      on failure. Espex currently logs errors and continues — it does
      not send an error back to the client.

  ## Frozen-at-accept-time snapshot

  `c:list_entities/0` is called exactly once per connection, at accept
  time. The returned list is cached by the connection handler for the
  lifetime of the connection. ESPHome clients (including Home
  Assistant) also cache the advertisement after the first
  `ListEntitiesRequest`.

  **Implication**: if you dynamically add or remove entities at
  runtime, existing clients will continue to see the set that was
  returned when they connected. A reconnect is required to pick up
  changes.

  ## The stateful provider pattern (GenServer)

  Most real providers hold mutable state — current values of each
  entity, observer pids, connections to downstream hardware — so a
  GenServer is the natural fit. The provider module implements both
  the `Espex.EntityProvider` behaviour and the `GenServer` behaviour;
  the behaviour callbacks typically delegate reads into `GenServer.call/2`
  and commands into `GenServer.cast/2` against itself.

      defmodule MyApp.Entities do
        @behaviour Espex.EntityProvider
        use GenServer

        alias Espex.Proto

        @switch_key 1001
        @sensor_key 1002

        # --- public API ---

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

        def set_sensor(value), do: GenServer.call(__MODULE__, {:set_sensor, value})

        # --- EntityProvider callbacks ---

        @impl Espex.EntityProvider
        def list_entities do
          [
            %Proto.ListEntitiesSwitchResponse{
              object_id: "demo_switch", key: @switch_key, name: "Demo Switch"
            },
            %Proto.ListEntitiesSensorResponse{
              object_id: "demo_sensor", key: @sensor_key, name: "Demo Sensor",
              unit_of_measurement: "°C", accuracy_decimals: 1
            }
          ]
        end

        @impl Espex.EntityProvider
        def initial_states do
          GenServer.call(__MODULE__, :initial_states)
        end

        @impl Espex.EntityProvider
        def handle_command(command) do
          GenServer.cast(__MODULE__, {:command, command})
        end

        # --- GenServer callbacks ---

        @impl GenServer
        def init(opts) do
          {:ok, %{switch: false, sensor: 20.0, server: Keyword.fetch!(opts, :server)}}
        end

        @impl GenServer
        def handle_call(:initial_states, _from, state) do
          responses = [
            %Proto.SwitchStateResponse{key: @switch_key, state: state.switch},
            %Proto.SensorStateResponse{key: @sensor_key, state: state.sensor, missing_state: false}
          ]

          {:reply, responses, state}
        end

        def handle_call({:set_sensor, value}, _from, state) do
          Espex.push_state(state.server, %Proto.SensorStateResponse{
            key: @sensor_key, state: value, missing_state: false
          })

          {:reply, :ok, %{state | sensor: value}}
        end

        @impl GenServer
        def handle_cast({:command, %Proto.SwitchCommandRequest{key: @switch_key, state: s}}, state) do
          Espex.push_state(state.server, %Proto.SwitchStateResponse{key: @switch_key, state: s})
          {:noreply, %{state | switch: s}}
        end

        def handle_cast({:command, _unknown}, state), do: {:noreply, state}
      end

  Note the two key moves:

    * **`handle_command/1` casts back to self**. Commands arrive on
      whichever connection handler received them; delegating to the
      provider GenServer keeps the single owner of the state the
      serializing point for all updates.
    * **`push_state/2` broadcasts to every connection**. Each subscribed
      connection's `handle_info/2` will see the state frame. If only
      the commanding client is connected, it's still the right
      behaviour — multiple HA installs or other clients stay in sync.

  ## The stateless provider pattern

  When your "state" lives outside espex (an external API, a database,
  an ETS table owned by another process), you don't need a GenServer.
  Implement the three callbacks as plain module functions:

      defmodule MyApp.Readonly do
        @behaviour Espex.EntityProvider

        alias Espex.Proto

        @impl true
        def list_entities do
          [
            %Proto.ListEntitiesBinarySensorResponse{
              object_id: "door_open", key: 1, name: "Door Open", device_class: "door"
            }
          ]
        end

        @impl true
        def initial_states do
          [
            %Proto.BinarySensorStateResponse{
              key: 1, state: MyApp.DoorSensor.current(), missing_state: false
            }
          ]
        end

        @impl true
        def handle_command(_), do: :ok  # no commands for read-only sensors
      end

  ## Pushing state updates

  `Espex.push_state/2` broadcasts a state struct to every currently
  connected client that's subscribed via `SubscribeStatesRequest`.
  Pass the server name you configured (defaults to `Espex.Server`):

      Espex.push_state(MyApp.EspexServer, %Proto.SensorStateResponse{
        key: 1002,
        state: 23.5,
        missing_state: false
      })

  With no subscribed clients, the broadcast is a silent no-op. See
  the ["Architecture" guide](architecture.html) for the underlying
  Registry fan-out mechanics.

  ## Wiring

  Start the provider under your own supervisor (or the application
  tree), then point espex at it:

      children = [
        {MyApp.Entities, server: MyApp.EspexServer},
        {Espex,
         name: MyApp.EspexSup,
         server_name: MyApp.EspexServer,
         device_config: [name: "my-device"],
         entity_provider: MyApp.Entities}
      ]

      Supervisor.start_link(children, strategy: :rest_for_one)

  Starting the provider before espex (and using `:rest_for_one`)
  ensures espex can't receive a connection before the provider is
  ready to answer `list_entities/0`.
  """

  @doc """
  Return the list of entities this provider advertises. One struct per
  entity — typically a mix of the various `Espex.Proto.ListEntities*Response`
  messages.
  """
  @callback list_entities() :: [struct()]

  @doc """
  Return the initial state for each advertised entity, sent when a
  client subscribes. One struct per entity — typically the matching
  `Espex.Proto.*StateResponse` message for the entity type.
  """
  @callback initial_states() :: [struct()]

  @doc """
  Handle a command from an ESPHome client — e.g.
  `%Espex.Proto.SwitchCommandRequest{}`, `%Espex.Proto.LightCommandRequest{}`.
  """
  @callback handle_command(command :: struct()) :: :ok | {:error, term()}
end
