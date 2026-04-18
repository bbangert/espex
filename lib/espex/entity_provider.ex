defmodule Espex.EntityProvider do
  @moduledoc """
  Behaviour for entity providers — the pluggable source of custom ESPHome
  entities beyond the built-in serial/Z-Wave/infrared proxies.

  Implement this to expose arbitrary ESPHome entities (sensors, switches,
  lights, etc.) over the Native API. Espex calls `c:list_entities/0` when
  a client sends `ListEntitiesRequest`, `c:initial_states/0` when a client
  subscribes to state, and `c:handle_command/1` when a client issues a
  command.

  The struct types returned and accepted must be the generated
  `Espex.Proto.*` messages — e.g. `%Espex.Proto.ListEntitiesSwitchResponse{}`
  for a switch entity, `%Espex.Proto.SwitchStateResponse{}` for its state,
  `%Espex.Proto.SwitchCommandRequest{}` for commands.
  """

  @doc """
  Entities this provider advertises. One struct per entity — typically a
  mix of the various `Espex.Proto.ListEntities*Response` messages.
  """
  @callback list_entities() :: [struct()]

  @doc """
  Initial state for each advertised entity, sent when a client subscribes.
  One struct per entity — typically the matching `Espex.Proto.*StateResponse`
  message for the entity type.
  """
  @callback initial_states() :: [struct()]

  @doc """
  Handle a command from an ESPHome client — e.g.
  `%Espex.Proto.SwitchCommandRequest{}`, `%Espex.Proto.LightCommandRequest{}`.
  """
  @callback handle_command(command :: struct()) :: :ok | {:error, term()}
end
