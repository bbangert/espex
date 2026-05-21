defmodule Espex.BluetoothScanner do
  @moduledoc """
  Behaviour for Bluetooth Low Energy scanner adapters.

  Implement this module to expose a passive BLE scanner — typically a
  built-in radio on a Nerves device — to ESPHome clients through the
  Native API's Bluetooth proxy feature. Home Assistant uses these
  advertisements to discover and update ESPHome BLE proxy entities,
  Govee/Xiaomi sensors, Bluetooth tags, and any other advertising
  device in range.

  This behaviour is independent of `Espex.BluetoothProxy`: a device may
  expose only a scanner (passive sniffing, no outbound connections), or
  pair this with the active behaviour for full proxy capability.

  ## Callbacks

  | Callback | Required | Purpose |
  |----------|----------|---------|
  | `c:subscribe/1` | yes | Register a connection handler for inbound advertisements |
  | `c:unsubscribe/1` | yes | Deregister a handler (idempotent) |
  | `c:set_scanner_mode/1` | no | Switch between passive and active scanning |

  When `c:set_scanner_mode/1` is omitted, espex omits the
  `STATE_AND_MODE` bit from the advertised feature flags and the client
  will not attempt to flip modes.

  ## Data flow

  Subscribers receive two kinds of messages from the adapter:

      {:espex_ble_advertisement, address, rssi, address_type, data}
      {:espex_ble_scanner_state, state, mode, configured_mode}

  ### Raw advertisements

  Each advertisement is sent as a single message. Espex wraps each one
  in a one-element `BluetoothLERawAdvertisementsResponse` and forwards
  it to the subscribed client. Batching multiple advertisements into a
  single response is a future optimization — keep the adapter contract
  simple by sending one ad per message.

    * `address` — 48-bit MAC packed into a `non_neg_integer()` (uint64)
    * `rssi` — signed integer, dBm
    * `address_type` — `0` (public) or `1` (random)
    * `data` — raw advertisement payload bytes

  Only the raw-advertisement format is supported. The legacy parsed
  format (`BluetoothLEAdvertisementResponse`, proto id 67) is not
  wired — modern clients ignore it in favor of the raw stream.

  ### Scanner state changes

  When the radio's state or mode changes (e.g., the controller starts,
  enters active-scan mode, or pauses for a connection), notify
  subscribers:

      send(subscriber, {:espex_ble_scanner_state, :running, :passive, :passive})

  The three atoms map directly to the `BluetoothScannerStateResponse`
  wire enums. Common values:

    * `state` — `:idle`, `:starting`, `:running`, `:failed`, `:stopping`, `:stopped`
    * `mode`, `configured_mode` — `:passive` or `:active`

  Espex passes these straight through to the wire enum encoding; the
  exact set of supported values is determined by your underlying BLE
  stack.

  ## Example: a passive scanner over BlueHeron

  This sketch wraps a hypothetical `BlueHeron`-style stack and broadcasts
  advertisements to every subscribed connection handler.

      defmodule MyApp.BLEScanner do
        @behaviour Espex.BluetoothScanner

        use GenServer

        @registry MyApp.BLEScannerSubscribers

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

        @impl true
        def subscribe(pid) do
          Registry.register(@registry, :subscribers, nil)
          GenServer.cast(__MODULE__, :ensure_scanning)
          :ok
        end

        @impl true
        def unsubscribe(_pid) do
          Registry.unregister(@registry, :subscribers)
          :ok
        end

        @impl true
        def set_scanner_mode(:passive), do: GenServer.call(__MODULE__, {:set_mode, :passive})
        def set_scanner_mode(:active), do: GenServer.call(__MODULE__, {:set_mode, :active})

        # Called from the BlueHeron read loop on each advertisement:
        def broadcast_advertisement(address, rssi, address_type, data) do
          Registry.dispatch(@registry, :subscribers, fn entries ->
            Enum.each(entries, fn {pid, _} ->
              send(pid, {:espex_ble_advertisement, address, rssi, address_type, data})
            end)
          end)
        end

        # Called when the scanner state or mode transitions:
        def broadcast_state(state, mode, configured) do
          Registry.dispatch(@registry, :subscribers, fn entries ->
            Enum.each(entries, fn {pid, _} ->
              send(pid, {:espex_ble_scanner_state, state, mode, configured})
            end)
          end)
        end
      end

  ## Wiring

      Espex.start_link(
        device_config: [name: "ble-proxy"],
        bluetooth_scanner: MyApp.BLEScanner
      )

  Pair with `bluetooth_proxy:` for an active proxy that can connect to
  discovered devices.
  """

  @doc """
  Subscribe the given pid to BLE advertisements. The adapter must
  forward every advertisement and every scanner state change to the
  pid via the message tuples described in the moduledoc.
  """
  @callback subscribe(subscriber :: pid()) :: :ok | {:error, term()}

  @doc """
  Unsubscribe a previously subscribed pid. Idempotent.
  """
  @callback unsubscribe(subscriber :: pid()) :: :ok

  @doc """
  Switch the scanner between passive and active modes. Optional —
  adapters that can only run in one mode (or that select the mode
  out-of-band) may omit this callback. When omitted, espex omits
  the `STATE_AND_MODE` bit from `bluetooth_proxy_feature_flags` and
  the client will not send `BluetoothScannerSetModeRequest`.
  """
  @callback set_scanner_mode(:passive | :active) :: :ok | {:error, term()}

  @optional_callbacks set_scanner_mode: 1
end
