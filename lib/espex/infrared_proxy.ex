defmodule Espex.InfraredProxy do
  @moduledoc """
  Behaviour for infrared proxy adapters.

  Implement this module to expose IR transmitters and receivers as
  ESPHome entities. Home Assistant treats each entity as a remote
  control — you can send raw-timing transmit commands and receive
  learned codes through the UI.

  IR entities are first-class ESPHome entities, distinct from the
  `Espex.EntityProvider` mechanism. They share the same physical
  connection but are advertised separately.

  ## Callbacks

  | Callback | Purpose |
  |----------|---------|
  | `c:list_entities/0` | Advertise the IR devices |
  | `c:transmit_raw/3` | Transmit a raw-timing pattern and return once it is sent (runs in a task) |
  | `c:subscribe/1` | Register a connection handler for receive events |
  | `c:unsubscribe/1` | Deregister (idempotent) |

  ## Entities

  `c:list_entities/0` returns a list of `Espex.InfraredProxy.Entity`
  structs. Each entity carries:

    * `key` — stable `non_neg_integer()`; this is the id you'll see in
      `c:transmit_raw/3` and the one you emit in receive events
    * `object_id` — stable string id
    * `name` — display name
    * `capabilities` — `[:transmit]`, `[:receive]`, or both — declares
      what the entity can do

  Use the `capabilities` list to model read-only IR blasters (transmit
  only), learning remotes (receive only), or combined TX+RX devices.

  ## Data flow

  ### Transmit

  When the client sends a transmit command, espex calls
  `c:transmit_raw/3` with:

    * `key` — the entity id the command is targeting
    * `timings` — list of pulse durations in microseconds. Positive
      values are ON periods, negative are OFF (standard IR raw-timing
      convention)
    * `opts` — a keyword list matching `t:transmit_opts/0`

  `t:transmit_opts/0`:

  | Key | Default | Notes |
  |-----|---------|-------|
  | `:carrier_frequency` | `38_000` | Hz; 38 kHz is the de-facto standard |
  | `:repeat_count` | `1` | how many times to emit the pattern |

  ### Transmit completion (API 1.18)

  espex answers each transmit request from a client on API 1.18 or later
  with an `InfraredRFTransmitCompleteResponse`, sent only to the
  connection that asked. Those clients pace their queue on this reply:
  they send the next frame only once the previous one is reported
  complete, and otherwise wait up to 35 s past the frame's air time.
  Clients below 1.18 get no reply, as from ESPHome firmware.

  The reply is the return of `c:transmit_raw/3`. `:ok` reports
  `success: true`, `{:error, _}` reports `success: false`. espex refuses
  a request with no timings, or for a key that `c:list_entities/0` did
  not advertise, with `success: false` without calling the adapter.

  So return from `c:transmit_raw/3` once the frame, all repeats included,
  has left the transmitter. An adapter that returns as soon as the frame
  is queued lets the client send the next one too early.

  `c:transmit_raw/3` runs in a task, not in the connection, so a long
  frame does not hold up the connection's other messages. espex follows
  the firmware's rules around it:

  | Situation | What espex does |
  |-----------|-----------------|
  | Two requests for one adapter | Run one at a time, in arrival order, whichever clients sent them |
  | A newer request for the same key, from any client | Answers the older one `success: false` at once. If the older one has not started it is dropped; if it is running it finishes, unanswered |
  | No return 30 s past the frame's air time (air time counted up to 8 min) | Answers `success: false`, kills the call, and starts the next request |
  | The adapter raises or exits | Answers `success: false` |
  | The requesting client disconnects | Its frames still go out, unanswered |

  Calls for different adapter modules run in parallel. A request runs on
  the adapter its connection started with, even after
  `Espex.update_adapters/2`.

  ### Receive

  When IR is detected, deliver `{:espex_ir_receive, key, timings}` to
  every pid that has subscribed via `c:subscribe/1`. `key` is the
  entity key of the receiving device; `timings` is the captured pulse
  pattern in microseconds.

  ## Example

      defmodule MyApp.IRAdapter do
        @behaviour Espex.InfraredProxy

        alias Espex.InfraredProxy.Entity

        @key 42

        @impl true
        def list_entities do
          [
            %Entity{
              key: @key,
              object_id: "ir_blaster",
              name: "IR Blaster",
              icon: "mdi:remote",
              capabilities: [:transmit, :receive]
            }
          ]
        end

        @impl true
        def transmit_raw(@key, timings, opts) do
          MyApp.IRHardware.transmit(timings,
            carrier_hz: opts[:carrier_frequency],
            repeat: opts[:repeat_count]
          )
        end

        def transmit_raw(_unknown_key, _timings, _opts), do: {:error, :no_such_entity}

        @impl true
        def subscribe(pid), do: MyApp.IRSubscribers.add(pid)

        @impl true
        def unsubscribe(pid), do: MyApp.IRSubscribers.remove(pid)
      end

  And in your hardware read loop, whenever IR is decoded:

      Enum.each(MyApp.IRSubscribers.all(), fn pid ->
        send(pid, {:espex_ir_receive, @key, timings})
      end)

  ## Wiring

      Espex.start_link(
        device_config: [name: "ir-bridge"],
        infrared_proxy: MyApp.IRAdapter
      )
  """

  alias Espex.InfraredProxy.Entity

  @typedoc """
  Options for `c:transmit_raw/3`:

    * `:carrier_frequency` — carrier frequency in Hz (defaults to 38_000)
    * `:repeat_count` — number of repeats (defaults to 1)
  """
  @type transmit_opts :: [carrier_frequency: non_neg_integer(), repeat_count: pos_integer()]

  @doc """
  Return the list of IR entities this adapter exposes.
  """
  @callback list_entities() :: [Entity.t()]

  @doc """
  Transmit a raw timing pattern on the device identified by `key`.

  Return once the frame, all repeats included, has left the transmitter:
  the return is reported to the client as the transmit's completion, and
  the client paces its next frame on it. Return `{:error, _}` for a
  failed transmit.

  The call runs in a task. It may run at the same time as calls on
  other adapter modules, but never two at a time for one adapter module.
  It is killed if it has not returned 30 s past the frame's air time.
  See "Transmit completion (API 1.18)" in the moduledoc.
  """
  @callback transmit_raw(key :: non_neg_integer(), timings :: [integer()], transmit_opts()) ::
              :ok | {:error, term()}

  @doc """
  Subscribe the given pid to infrared receive events. Idempotent.
  """
  @callback subscribe(subscriber :: pid()) :: :ok

  @doc """
  Unsubscribe a previously subscribed pid. Idempotent.
  """
  @callback unsubscribe(subscriber :: pid()) :: :ok
end
