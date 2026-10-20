defmodule Espex.HomeAssistantStates do
  @moduledoc since: "0.12.0"
  @moduledoc """
  Behaviour for receiving Home Assistant entity states (ESPHome's
  `homeassistant` sensors).

  The device keeps a table of `Espex.HomeAssistantStates.Subscription`
  entries, each an entity id with an optional attribute. Home Assistant
  sends `SubscribeHomeAssistantStatesRequest` on every connect; espex
  answers with one `SubscribeHomeAssistantStateResponse` per entry, and
  from then on Home Assistant sends the entry's state when it changes.
  espex hands each state to `c:handle_state/3`.

  ## Callbacks

  | Callback | Purpose |
  |----------|---------|
  | `c:subscriptions/0` | The entries to subscribe to (optional, default none) |
  | `c:handle_state/3` | Receive a state Home Assistant sent |

  ## Where entries come from

    * `c:subscriptions/0`, read when the server starts and again when
      `Espex.update_adapters/2` sets a new `:home_assistant_states`
      module. Put entries here when they must survive a restart.
    * `Espex.subscribe_home_assistant_state/2` and
      `Espex.unsubscribe_home_assistant_state/2`, at runtime. These live
      in memory only and are lost if the espex server restarts.
    * Wizard inputs linked to an entity (`links` on `Espex.Wizard.Input`),
      filled in when the client sets the input.

  An entry asked for from several places is sent once. A client that has
  already subscribed is sent new entries as they appear. Removing an
  entry sends nothing, as the protocol has no unsubscribe: Home
  Assistant keeps sending states for it until it reconnects, and espex
  drops them.

  The table works without an adapter (the runtime API and wizard links
  still fill it); states that arrive are then dropped.

  ## Delivery

  `c:handle_state/3` runs in the process of the connection the state
  arrived on, so calls arrive concurrently when several clients are
  connected, and a slow callback holds up that connection. Return
  promptly and hand long work to a process of your own. A raise is
  logged and the connection carries on.

  Each state message calls `c:handle_state/3` once, whatever the number
  of entries it matches. `once` entries match like any other. Home
  Assistant sends `"on"` / `"off"` for a boolean attribute and the value
  as a string otherwise; firmware components treat `"None"`,
  `"unavailable"` and `"unknown"` as no value.

  As with firmware, espex does not check which client sent a state or
  whether it subscribed: on a node without a Noise key, any client on
  the network can send one.

  ## Example

      defmodule MyApp.HAStates do
        @behaviour Espex.HomeAssistantStates

        alias Espex.HomeAssistantStates.Subscription

        @impl true
        def subscriptions do
          [
            Subscription.new!(entity_id: "sun.sun"),
            Subscription.new!(entity_id: "sun.sun", attribute: "elevation")
          ]
        end

        @impl true
        def handle_state(entity_id, attribute, state) do
          send(MyApp.Dashboard, {:ha_state, entity_id, attribute, state})
          :ok
        end
      end

  ## Wiring

      Espex.start_link(
        device_config: [name: "my-device"],
        home_assistant_states: MyApp.HAStates
      )
  """

  alias Espex.HomeAssistantStates.Subscription

  @doc """
  Return the entries to subscribe to. Optional; without it the table
  starts empty.

  Called when the server starts and when `Espex.update_adapters/2` sets
  a new `:home_assistant_states` module. A raise is logged and counts
  as no entries.
  """
  @callback subscriptions() :: [Subscription.t()]

  @doc """
  Receive a state Home Assistant sent for a subscribed entity.

  `attribute` is `nil` for the entity's state. Called in the
  connection's process; see "Delivery" in the moduledoc.
  """
  @callback handle_state(entity_id :: String.t(), attribute :: String.t() | nil, state :: String.t()) :: :ok

  @optional_callbacks subscriptions: 0
end
