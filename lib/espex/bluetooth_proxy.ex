defmodule Espex.BluetoothProxy do
  @moduledoc """
  Behaviour for Bluetooth Low Energy active-proxy adapters.

  Implement this module to expose outbound BLE connections — connect,
  GATT read/write, notifications, pairing — to ESPHome clients through
  the Native API. Together with `Espex.BluetoothScanner` (passive
  advertisement sniffing), this lets a Nerves device act as a drop-in
  BLE proxy for Home Assistant, indistinguishable from an ESPHome
  C++-firmware proxy on the wire.

  This behaviour is independent of `Espex.BluetoothScanner` — you can
  configure either, both, or neither in `Espex.start_link/1`. Scanner-
  only mode is useful for devices that only sniff advertisements;
  proxy-only mode is rare (clients typically want both).

  ## Callbacks

  | Callback | Required | Purpose |
  |----------|----------|---------|
  | `c:connect/3` | yes | Start an outbound connection to a peripheral |
  | `c:disconnect/1` | yes | Tear down an open connection |
  | `c:gatt_get_services/1` | yes | Stream the peripheral's GATT services |
  | `c:gatt_read/2` | yes | Read a characteristic by handle |
  | `c:gatt_write/4` | yes | Write a characteristic by handle |
  | `c:gatt_read_descriptor/2` | yes | Read a descriptor by handle |
  | `c:gatt_write_descriptor/3` | yes | Write a descriptor by handle |
  | `c:gatt_notify/3` | yes | Enable or disable notifications for a handle |
  | `c:connections_free/0` | yes | Report free / total active-connection slots |
  | `c:pair/1` | no | Bond with a peripheral |
  | `c:unpair/1` | no | Remove an existing bond |
  | `c:clear_cache/1` | no | Clear cached GATT data for a peripheral |
  | `c:set_connection_params/2` | no | Tune interval / latency / timeout |

  Espex advertises each optional callback in the device's
  `bluetooth_proxy_feature_flags` only when the adapter exports it. When
  a client invokes a missing optional callback, espex synthesises the
  protocol's "not supported" response shape (`success: false` with an
  error code) without calling the adapter.

  ## Address-keyed model

  Every callback takes `address :: non_neg_integer()` — the 48-bit
  peripheral MAC packed into a uint64 (most-significant 16 bits zero).
  Espex never returns an opaque handle; the client refers to a
  peripheral by address from connect through disconnect. If your
  adapter tracks internal handles, key them by address yourself.

  ## Owner-locked connections

  Espex enforces that an address can be claimed by **at most one
  connection at a time**. The first client to issue `CONNECT` for an
  address becomes its owner; concurrent connects from other clients
  receive a `BUSY` error (`error: -3`) without invoking the adapter.
  All GATT requests on an owned address are gated on ownership; a
  non-owning client gets a GATT error envelope.

  Ownership is released when:

    * The owning client sends `DISCONNECT` for the address.
    * The owning connection's TCP socket closes (espex calls
      `c:disconnect/1` for every owned address during cleanup).

  Adapters should not implement their own per-client ownership tracking —
  espex handles it cross-connection. From your adapter's perspective,
  `c:connect/3` is called at most once per address until the matching
  `c:disconnect/1` fires.

  ## Data flow: subscriber messages

  All adapter callbacks are cast-style: they return `:ok` to acknowledge
  the request and deliver results asynchronously to the `subscriber`
  pid (the per-connection handler). The subscriber pid for an address
  is the one passed to `c:connect/3`.

  Lifecycle messages:

      {:espex_ble_connection, address, {:ok, mtu :: non_neg_integer()}}
      {:espex_ble_connection, address, {:error, error_code :: integer()}}
      {:espex_ble_pair, address, paired? :: boolean(), error_code :: integer()}
      {:espex_ble_unpair, address, success? :: boolean(), error_code :: integer()}
      {:espex_ble_clear_cache, address, success? :: boolean(), error_code :: integer()}
      {:espex_ble_connection_params, address, error_code :: integer()}

  GATT messages:

      {:espex_ble_gatt_service, address, %Espex.BluetoothProxy.Service{}}
      {:espex_ble_gatt_services_done, address}
      {:espex_ble_gatt_read, address, handle, {:ok, data :: binary()}}
      {:espex_ble_gatt_read, address, handle, {:error, error_code :: integer()}}
      {:espex_ble_gatt_write, address, handle, {:ok, _}}
      {:espex_ble_gatt_write, address, handle, {:error, error_code :: integer()}}
      {:espex_ble_gatt_notify, address, handle, {:ok, _}}
      {:espex_ble_gatt_notify, address, handle, {:error, error_code :: integer()}}
      {:espex_ble_gatt_notify_data, address, handle, data :: binary()}

  Espex translates each tuple into the corresponding wire proto and
  forwards it to the client.

  ### Streamed GATT services

  `c:gatt_get_services/1` is a streaming operation: send one
  `{:espex_ble_gatt_service, address, service}` message per service,
  then `{:espex_ble_gatt_services_done, address}` to terminate the
  stream. Espex emits one `BluetoothGATTGetServicesResponse` per
  service plus a final `BluetoothGATTGetServicesDoneResponse`. Don't
  batch — one service per message keeps the contract simple.

  ## `connect/3` options

  The `opts` keyword list carries the client's connection preferences:

  | Key | Values | Notes |
  |-----|--------|-------|
  | `:address_type` | `0` (public), `1` (random), `nil` | When `nil`, the adapter should default to public or use its own discovery cache |
  | `:cache_mode` | `:with_cache`, `:without_cache`, `:default` | Whether the adapter may use cached GATT data for this connect |

  `:cache_mode` reflects the `CONNECT_V3_WITH_CACHE` /
  `CONNECT_V3_WITHOUT_CACHE` / plain `CONNECT` request types from the
  wire — adapters should honor it when caching is supported, or ignore
  it otherwise.

  ## `connections_free/0`

  Espex calls `c:connections_free/0` whenever a client subscribes to
  `BluetoothConnectionsFreeResponse` or after every successful
  connect/disconnect. Return `{free, limit}` where:

    * `limit` — total active-connection slots your adapter supports
    * `free` — slots currently available (i.e. `limit - in_use`)

  Espex fills the `allocated` list from its own ownership set, so you
  don't need to track per-client occupancy.

  ## `set_connection_params/2`

  Optional. The `params` map carries:

    * `:min_interval`, `:max_interval` — connection interval bounds (units
      of 1.25 ms)
    * `:latency` — slave latency (allowed peripheral skips)
    * `:timeout` — supervision timeout (units of 10 ms)

  The adapter applies the parameters and reports the outcome via
  `{:espex_ble_connection_params, address, error_code}` where
  `error_code == 0` means success.

  ## Example: a BlueHeron-shaped adapter

  This sketch wraps a hypothetical `BlueHeron`-style stack. The actual
  GATT machinery is elided; focus on the espex-facing shape.

      defmodule MyApp.BLEProxy do
        @behaviour Espex.BluetoothProxy

        use GenServer

        alias Espex.BluetoothProxy.{Service, Characteristic, Descriptor}

        @max_connections 3

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

        @impl true
        def connect(address, opts, subscriber) do
          GenServer.cast(__MODULE__, {:connect, address, opts, subscriber})
          :ok
        end

        @impl true
        def disconnect(address) do
          GenServer.cast(__MODULE__, {:disconnect, address})
          :ok
        end

        @impl true
        def gatt_get_services(address) do
          GenServer.cast(__MODULE__, {:gatt_get_services, address})
          :ok
        end

        @impl true
        def gatt_read(address, handle) do
          GenServer.cast(__MODULE__, {:gatt_read, address, handle})
          :ok
        end

        @impl true
        def gatt_write(address, handle, data, response?) do
          GenServer.cast(__MODULE__, {:gatt_write, address, handle, data, response?})
          :ok
        end

        @impl true
        def gatt_read_descriptor(address, handle) do
          GenServer.cast(__MODULE__, {:gatt_read_descriptor, address, handle})
          :ok
        end

        @impl true
        def gatt_write_descriptor(address, handle, data) do
          GenServer.cast(__MODULE__, {:gatt_write_descriptor, address, handle, data})
          :ok
        end

        @impl true
        def gatt_notify(address, handle, enable?) do
          GenServer.cast(__MODULE__, {:gatt_notify, address, handle, enable?})
          :ok
        end

        @impl true
        def connections_free do
          {free, _used} = GenServer.call(__MODULE__, :connection_slots)
          {free, @max_connections}
        end

        @impl true
        def pair(address), do: GenServer.cast(__MODULE__, {:pair, address})

        @impl true
        def unpair(address), do: GenServer.cast(__MODULE__, {:unpair, address})

        @impl true
        def clear_cache(address), do: GenServer.cast(__MODULE__, {:clear_cache, address})

        @impl true
        def set_connection_params(address, params) do
          GenServer.cast(__MODULE__, {:set_connection_params, address, params})
        end

        # Inside handle_cast, your stack would call into BlueHeron and
        # forward results back to the subscriber:
        #
        #   send(subscriber, {:espex_ble_connection, address, {:ok, 247}})
        #   send(subscriber, {:espex_ble_gatt_service, address,
        #     %Service{uuid: <<0x18, 0x0F, ...>>, handle: 1, characteristics: [...]}})
        #   send(subscriber, {:espex_ble_gatt_services_done, address})
      end

  ## Wiring

      Espex.start_link(
        device_config: [name: "ble-proxy"],
        bluetooth_scanner: MyApp.BLEScanner,
        bluetooth_proxy: MyApp.BLEProxy
      )

  Configure both adapters together for a full Home Assistant BLE proxy.
  """

  @typedoc """
  48-bit BLE MAC address packed into a `non_neg_integer()` (uint64).
  Used as the cross-call identifier for every active-connection
  operation.
  """
  @type address :: non_neg_integer()

  @typedoc """
  Either a 16-byte binary holding a full 128-bit UUID, or a
  non-negative integer holding a 16/32-bit Bluetooth SIG short UUID.
  Used by `Service`, `Characteristic`, and `Descriptor`; espex picks
  the right wire encoding (`uuid` repeated field vs `short_uuid`).
  """
  @type uuid :: <<_::128>> | non_neg_integer()

  @typedoc """
  Options for `c:connect/3`.

    * `:address_type` — `0` (public), `1` (random), or `nil` when the
      client didn't specify (legacy CONNECT request type).
    * `:cache_mode` — `:with_cache` (the client allows cached GATT
      data), `:without_cache` (forbid cache use this connect), or
      `:default` (no preference; behave as before V3 connect existed).
  """
  @type connect_opts :: [
          address_type: 0 | 1 | nil,
          cache_mode: :with_cache | :without_cache | :default
        ]

  @typedoc """
  Parameters for `c:set_connection_params/2`. Units follow the
  Bluetooth Core spec: `:min_interval` / `:max_interval` in 1.25 ms
  steps; `:timeout` in 10 ms steps; `:latency` in connection events.
  """
  @type connection_params :: %{
          required(:min_interval) => non_neg_integer(),
          required(:max_interval) => non_neg_integer(),
          required(:latency) => non_neg_integer(),
          required(:timeout) => non_neg_integer()
        }

  @doc """
  Start an outbound connection to the peripheral at `address` on
  behalf of `subscriber`.

  Cast-style — return `:ok` to acknowledge. Deliver the result via
  `{:espex_ble_connection, address, {:ok, mtu} | {:error, error_code}}`.
  """
  @callback connect(address(), connect_opts(), subscriber :: pid()) :: :ok | {:error, term()}

  @doc """
  Tear down the connection at `address`. The adapter does not need to
  emit a follow-up message — espex updates its bookkeeping based on
  the call's return.
  """
  @callback disconnect(address()) :: :ok | {:error, term()}

  @doc """
  Stream the GATT services for `address`.

  Send one `{:espex_ble_gatt_service, address, %Service{}}` per
  service to the connection's subscriber, then terminate with
  `{:espex_ble_gatt_services_done, address}`.
  """
  @callback gatt_get_services(address()) :: :ok | {:error, term()}

  @doc """
  Read the GATT characteristic at `handle`. Delivers the result via
  `{:espex_ble_gatt_read, address, handle, {:ok, data} | {:error, code}}`.
  """
  @callback gatt_read(address(), handle :: non_neg_integer()) :: :ok | {:error, term()}

  @doc """
  Write `data` to the GATT characteristic at `handle`. When
  `response?` is true, the adapter must request a response from the
  peripheral and report it via `{:espex_ble_gatt_write, address,
  handle, {:ok, _} | {:error, code}}`. When false, the write is
  fire-and-forget; the adapter may still report errors.
  """
  @callback gatt_write(address(), handle :: non_neg_integer(), data :: binary(), response? :: boolean()) ::
              :ok | {:error, term()}

  @doc """
  Read the GATT descriptor at `handle`. Delivers the result via
  `{:espex_ble_gatt_read, address, handle, {:ok, data} | {:error, code}}`
  (same envelope as characteristic reads).
  """
  @callback gatt_read_descriptor(address(), handle :: non_neg_integer()) :: :ok | {:error, term()}

  @doc """
  Write `data` to the GATT descriptor at `handle`. Delivers the result
  via `{:espex_ble_gatt_write, address, handle, ...}`.
  """
  @callback gatt_write_descriptor(address(), handle :: non_neg_integer(), data :: binary()) ::
              :ok | {:error, term()}

  @doc """
  Enable or disable notifications for the characteristic at `handle`.
  Delivers an acknowledgement via `{:espex_ble_gatt_notify, address,
  handle, {:ok, _} | {:error, code}}`. While notifications are
  enabled, push notification payloads via `{:espex_ble_gatt_notify_data,
  address, handle, data}`.
  """
  @callback gatt_notify(address(), handle :: non_neg_integer(), enable? :: boolean()) ::
              :ok | {:error, term()}

  @doc """
  Report the number of free and total active-connection slots. Called
  on `SubscribeBluetoothConnectionsFreeRequest` and after every
  successful connect / disconnect.
  """
  @callback connections_free() :: {free :: non_neg_integer(), limit :: non_neg_integer()}

  @doc """
  Bond with the peripheral at `address`. Optional. Delivers the
  outcome via `{:espex_ble_pair, address, paired?, error_code}`.
  """
  @callback pair(address()) :: :ok | {:error, term()}

  @doc """
  Remove the bond with the peripheral at `address`. Optional. Delivers
  the outcome via `{:espex_ble_unpair, address, success?, error_code}`.
  """
  @callback unpair(address()) :: :ok | {:error, term()}

  @doc """
  Clear cached GATT data for the peripheral at `address`. Optional.
  Delivers the outcome via `{:espex_ble_clear_cache, address,
  success?, error_code}`.
  """
  @callback clear_cache(address()) :: :ok | {:error, term()}

  @doc """
  Apply BLE connection parameters for `address`. Optional. Delivers
  the outcome via `{:espex_ble_connection_params, address,
  error_code}`.
  """
  @callback set_connection_params(address(), connection_params()) :: :ok | {:error, term()}

  @optional_callbacks pair: 1, unpair: 1, clear_cache: 1, set_connection_params: 2

  @doc """
  Split a `t:uuid/0` into the `{uuid_list, short_uuid}` shape used by
  the wire protobufs.

    * A 16-byte binary becomes `{[high, low], 0}` — the binary is read
      as network byte order (most-significant byte first), then split
      into two `uint64`s and packed **high-half first** into the wire's
      `repeated uuid` field. Per the reference Python client
      (`aioesphomeapi.model._join_split_uuid_high_low`), `uuid[0]` is
      the upper 64 bits and `uuid[1]` is the lower 64 bits of the
      full 128-bit UUID integer.
    * A non-negative integer becomes `{[], int}` — empty `uuid` field
      with the integer in `short_uuid`.

  Used by the `to_proto/1` functions on `Service`, `Characteristic`,
  and `Descriptor`. Exposed publicly so adapters writing their own
  conversions can use the same encoding.
  """
  @spec encode_uuid(uuid()) :: {[non_neg_integer()], non_neg_integer()}
  def encode_uuid(<<msb::unsigned-big-integer-size(64), lsb::unsigned-big-integer-size(64)>>) do
    {[msb, lsb], 0}
  end

  def encode_uuid(short) when is_integer(short) and short >= 0 do
    {[], short}
  end
end
