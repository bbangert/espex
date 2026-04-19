defmodule Espex.ZWaveProxy do
  @moduledoc """
  Behaviour for Z-Wave proxy adapters.

  Implement this module to proxy a Z-Wave Serial API controller (e.g.
  a 700/800-series Silicon Labs stick) over the ESPHome Native API.
  Home Assistant's Z-Wave JS integration drives a proxied controller
  identically to a locally-attached one — you just point it at the
  espex server instead of a `/dev/tty*` path.

  Espex acts as a framing shim only. Home Assistant and the controller
  exchange raw Z-Wave Serial API bytes; your adapter's job is to wrap
  the hardware link and fan frames out to subscribed connection
  handlers.

  ## Callbacks

  | Callback | Purpose |
  |----------|---------|
  | `c:available?/0` | Is the controller reachable right now? |
  | `c:home_id/0` | Current 32-bit home ID (0 if no network) |
  | `c:feature_flags/0` | `DeviceInfoResponse.zwave_proxy_feature_flags` bitfield |
  | `c:subscribe/1` | Register a connection handler for inbound frames |
  | `c:unsubscribe/1` | Deregister a handler (idempotent) |
  | `c:send_frame/1` | Send a client-originated frame to the controller |

  All six are required; there are no optional callbacks.

  ## Data flow

  Subscribers receive two kinds of messages from your adapter:

      {:espex_zwave_frame, binary}               # raw Z-Wave Serial API frame
      {:espex_zwave_home_id_changed, <<_::32>>}  # new home ID (4-byte binary)

  Home ID changes matter because Home Assistant learns the network id
  at subscribe time; if the controller is reset or the network rekeyed
  while a client is connected, send the change event so HA's stored
  state stays in sync.

  `c:subscribe/1` returns `{:ok, home_id_bytes}` where `home_id_bytes`
  is the current home ID as a 4-byte binary. Espex uses the value to
  decide whether to emit an initial change notification to the new
  subscriber.

  ## `feature_flags/0` and `home_id/0`

  These two callbacks are called when a client issues
  `DeviceInfoRequest`. Set `feature_flags/0` to at least `0x01` (bit 0)
  to signal "Z-Wave proxy available". Return `0` from `home_id/0` when
  no controller is attached — clients will treat that as "no network".

  ## Example

  This sketch assumes a single controller and uses a simple Registry
  for multi-client fan-out. A production adapter would also handle
  controller reconnects and buffer frames during transient outages.

      defmodule MyApp.ZWaveAdapter do
        @behaviour Espex.ZWaveProxy
        use GenServer

        @registry MyApp.ZWaveSubscribers

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

        @impl true
        def available?, do: GenServer.call(__MODULE__, :available?)

        @impl true
        def home_id, do: GenServer.call(__MODULE__, :home_id)

        @impl true
        def feature_flags, do: 0x01

        @impl true
        def subscribe(pid) do
          {:ok, _} = Registry.register(@registry, :subscribers, nil)
          # caller is `pid`, not self() — redirect if your Registry usage differs
          {:ok, home_id_bytes()}
        end

        @impl true
        def unsubscribe(pid) do
          Registry.unregister(@registry, :subscribers)
          :ok
        end

        @impl true
        def send_frame(data), do: MyApp.ZWaveController.write(data)

        # Called from the hardware read loop whenever a frame arrives:
        def broadcast_frame(data) do
          Registry.dispatch(@registry, :subscribers, fn entries ->
            Enum.each(entries, fn {pid, _} -> send(pid, {:espex_zwave_frame, data}) end)
          end)
        end

        defp home_id_bytes do
          <<home_id()::32>>
        end

        # ... init/1, handle_call/3, reconnect logic, etc.
      end

  ## Wiring

      Espex.start_link(
        device_config: [name: "zwave-gateway"],
        zwave_proxy: MyApp.ZWaveAdapter
      )
  """

  @doc """
  Is the Z-Wave controller currently reachable?
  """
  @callback available?() :: boolean()

  @doc """
  Current Z-Wave home ID as a 32-bit integer (`0` if none).
  """
  @callback home_id() :: non_neg_integer()

  @doc """
  Feature flags reported to ESPHome clients. See
  `DeviceInfoResponse.zwave_proxy_feature_flags`.
  """
  @callback feature_flags() :: non_neg_integer()

  @doc """
  Subscribe the given pid to Z-Wave frames.

  Returns the current home ID as a 4-byte binary so the subscriber can
  decide whether to emit an initial change event.
  """
  @callback subscribe(subscriber :: pid()) ::
              {:ok, home_id_bytes :: <<_::32>>} | {:error, term()}

  @doc """
  Unsubscribe a previously subscribed pid. Idempotent.
  """
  @callback unsubscribe(subscriber :: pid()) :: :ok

  @doc """
  Send a raw Z-Wave Serial API frame to the controller.
  """
  @callback send_frame(data :: binary()) :: :ok | {:error, term()}
end
