defmodule Espex.ConnectionState do
  @moduledoc false

  alias Espex.{DeviceConfig, InfraredProxy, Noise, SerialProxy}

  @type feature ::
          :serial_proxy
          | :zwave_proxy
          | :infrared_proxy
          | :bluetooth_scanner
          | :bluetooth_proxy
          | :entity_provider
          | :psk_store
          | :connection_listener
  @type adapters :: %{feature() => module() | nil}

  @typedoc """
  Per-connection encryption state:

    * `:disabled` — no PSK; plaintext transport only
    * `:awaiting_hello` — PSK set; waiting for the client's NOISE_HELLO frame
    * `{:awaiting_init, handshake}` — sent ServerHello; waiting for client's
      handshake init message
    * `{:active, tx, rx}` — handshake complete; encrypted transport
  """
  @type encryption ::
          :disabled
          | :awaiting_hello
          | {:awaiting_init, Noise.handshake()}
          | {:active, Noise.cipher(), Noise.cipher()}

  @typedoc """
  The lists below are captured once at connection accept time and never
  change for the lifetime of the connection — ESPHome clients (Home
  Assistant) cache them after the first `ListEntitiesRequest` /
  `DeviceInfoRequest` round, so silently changing them mid-connection
  would desync the client. To advertise a new device, force a reconnect.
  """
  @type t :: %__MODULE__{
          buffer: binary(),
          device_config: DeviceConfig.t(),
          peer: String.t(),
          server_name: atom() | nil,
          client_registry: atom() | nil,
          client_info: String.t() | nil,
          api_version: {non_neg_integer(), non_neg_integer()} | nil,
          connected_at: integer() | nil,
          last_activity_at: integer() | nil,
          serial_proxies: [SerialProxy.Info.t()],
          infrared_entities: [InfraredProxy.Entity.t()],
          entities: [struct()],
          opened_ports: %{non_neg_integer() => term()},
          serial_subscriptions: MapSet.t(non_neg_integer()),
          serial_open_failures: %{non_neg_integer() => integer()},
          zwave_subscribed: boolean(),
          infrared_subscribed: boolean(),
          bluetooth_scanner_subscribed: boolean(),
          bluetooth_connections_free_subscribed: boolean(),
          bluetooth_owned: MapSet.t(non_neg_integer()),
          adapters: adapters(),
          clock_fun: (-> non_neg_integer()),
          encryption: encryption(),
          keepalive_idle_ms: pos_integer(),
          keepalive_grace_ms: pos_integer(),
          keepalive_timer: reference() | nil,
          keepalive_outstanding: boolean()
        }

  @enforce_keys [:device_config, :peer]
  defstruct [
    :device_config,
    :peer,
    server_name: nil,
    client_registry: nil,
    client_info: nil,
    api_version: nil,
    connected_at: nil,
    last_activity_at: nil,
    buffer: <<>>,
    serial_proxies: [],
    infrared_entities: [],
    entities: [],
    opened_ports: %{},
    serial_subscriptions: MapSet.new(),
    serial_open_failures: %{},
    zwave_subscribed: false,
    infrared_subscribed: false,
    bluetooth_scanner_subscribed: false,
    bluetooth_connections_free_subscribed: false,
    bluetooth_owned: MapSet.new(),
    adapters: %{
      serial_proxy: nil,
      zwave_proxy: nil,
      infrared_proxy: nil,
      bluetooth_scanner: nil,
      bluetooth_proxy: nil,
      entity_provider: nil,
      psk_store: nil,
      connection_listener: nil
    },
    clock_fun: &__MODULE__.os_time_second/0,
    encryption: :disabled,
    # Device-initiated keepalive (see Espex.Connection): after
    # keepalive_idle_ms of inbound silence we send a PingRequest; after
    # keepalive_grace_ms more of silence we close. Clients like
    # aioesphomeapi skip their own pings while they're RECEIVING data, so
    # a busy device (e.g. a BLE advert stream) sees a totally silent
    # inbound side on a healthy connection — the device must initiate.
    keepalive_idle_ms: 60_000,
    keepalive_grace_ms: 60_000,
    keepalive_timer: nil,
    keepalive_outstanding: false
  ]

  @doc false
  @spec os_time_second() :: non_neg_integer()
  def os_time_second, do: System.os_time(:second)

  @doc """
  Build a new `%ConnectionState{}` from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Append data to the inbound byte buffer.
  """
  @spec append_buffer(t(), binary()) :: t()
  def append_buffer(%__MODULE__{} = state, data) do
    %{state | buffer: state.buffer <> data}
  end

  @doc """
  Replace the buffer with the given binary — typically the leftover after
  `Espex.Frame.decode_frame/1` consumed one or more complete frames.
  """
  @spec put_buffer(t(), binary()) :: t()
  def put_buffer(%__MODULE__{} = state, buffer) when is_binary(buffer) do
    %{state | buffer: buffer}
  end

  @doc """
  Record that `instance` has been opened and hold the adapter-returned
  handle so later writes/closes can refer back to it.
  """
  @spec put_port(t(), non_neg_integer(), term()) :: t()
  def put_port(%__MODULE__{} = state, instance, handle) do
    %{state | opened_ports: Map.put(state.opened_ports, instance, handle)}
  end

  @doc """
  Remove `instance` from the open-port map.

  Returns `{new_state, handle}` where `handle` is the previously-stored
  handle (or `nil` if the instance wasn't open).
  """
  @spec drop_port(t(), non_neg_integer()) :: {t(), term() | nil}
  def drop_port(%__MODULE__{} = state, instance) do
    case Map.pop(state.opened_ports, instance) do
      {nil, _ports} -> {state, nil}
      {handle, new_ports} -> {%{state | opened_ports: new_ports}, handle}
    end
  end

  @doc """
  Look up the adapter handle for a given open instance.
  """
  @spec port_handle(t(), non_neg_integer()) :: {:ok, term()} | :error
  def port_handle(%__MODULE__{opened_ports: ports}, instance) do
    Map.fetch(ports, instance)
  end

  @doc """
  Return `true` if `instance` is currently open. Use when you only need
  existence, not the handle itself.
  """
  @spec port_open?(t(), non_neg_integer()) :: boolean()
  def port_open?(%__MODULE__{opened_ports: ports}, instance) do
    Map.has_key?(ports, instance)
  end

  @doc """
  Reverse-lookup the instance id for an adapter-returned handle.
  Returns the first matching instance, or `nil`.
  """
  @spec instance_for_handle(t(), term()) :: non_neg_integer() | nil
  def instance_for_handle(%__MODULE__{opened_ports: ports}, handle) do
    Enum.find_value(ports, fn
      {instance, ^handle} -> instance
      _ -> nil
    end)
  end

  @doc """
  Find the advertised `SerialProxy.Info` for the given instance id.
  """
  @spec find_serial_proxy(t(), non_neg_integer()) :: SerialProxy.Info.t() | nil
  def find_serial_proxy(%__MODULE__{serial_proxies: list}, instance) do
    Enum.find(list, &(&1.instance == instance))
  end

  @doc """
  Record the client's subscribe intent for a serial instance. Set by
  SUBSCRIBE, cleared only by UNSUBSCRIBE — it persists across port
  (re)opens so the connection can reattach the adapter-side subscription
  after a reconfigure or lazy open.
  """
  @spec put_serial_subscription(t(), non_neg_integer()) :: t()
  def put_serial_subscription(%__MODULE__{} = state, instance) do
    %{state | serial_subscriptions: MapSet.put(state.serial_subscriptions, instance)}
  end

  @doc """
  Forget the client's subscribe intent for `instance` (UNSUBSCRIBE).
  """
  @spec drop_serial_subscription(t(), non_neg_integer()) :: t()
  def drop_serial_subscription(%__MODULE__{} = state, instance) do
    %{state | serial_subscriptions: MapSet.delete(state.serial_subscriptions, instance)}
  end

  @doc """
  Return `true` if the client currently intends to be subscribed to
  `instance` (regardless of whether the port is open right now).
  """
  @spec serial_subscribed?(t(), non_neg_integer()) :: boolean()
  def serial_subscribed?(%__MODULE__{serial_subscriptions: set}, instance) do
    MapSet.member?(set, instance)
  end

  @doc """
  Record that a lazy open of `instance` failed at `at_ms` (monotonic
  milliseconds). State only stores the timestamp — the backoff window
  itself is a policy decision that lives in `Espex.Connection`.
  """
  @spec put_serial_open_failure(t(), non_neg_integer(), integer()) :: t()
  def put_serial_open_failure(%__MODULE__{} = state, instance, at_ms) do
    %{state | serial_open_failures: Map.put(state.serial_open_failures, instance, at_ms)}
  end

  @doc """
  Forget a recorded open failure for `instance` (called after a
  successful open).
  """
  @spec clear_serial_open_failure(t(), non_neg_integer()) :: t()
  def clear_serial_open_failure(%__MODULE__{} = state, instance) do
    %{state | serial_open_failures: Map.delete(state.serial_open_failures, instance)}
  end

  @doc """
  Return the monotonic millisecond timestamp of the last recorded open
  failure for `instance`, or `nil` if none is recorded.
  """
  @spec serial_open_failure_at(t(), non_neg_integer()) :: integer() | nil
  def serial_open_failure_at(%__MODULE__{serial_open_failures: failures}, instance) do
    Map.get(failures, instance)
  end

  @doc """
  Mark the Z-Wave proxy subscription state.
  """
  @spec put_zwave_subscribed(t(), boolean()) :: t()
  def put_zwave_subscribed(%__MODULE__{} = state, subscribed?) do
    %{state | zwave_subscribed: subscribed?}
  end

  @doc """
  Mark the infrared proxy subscription state.
  """
  @spec put_infrared_subscribed(t(), boolean()) :: t()
  def put_infrared_subscribed(%__MODULE__{} = state, subscribed?) do
    %{state | infrared_subscribed: subscribed?}
  end

  @doc """
  Mark whether the client is subscribed to BLE raw advertisements.
  """
  @spec put_bluetooth_scanner_subscribed(t(), boolean()) :: t()
  def put_bluetooth_scanner_subscribed(%__MODULE__{} = state, subscribed?) do
    %{state | bluetooth_scanner_subscribed: subscribed?}
  end

  @doc """
  Mark whether the client is subscribed to
  `BluetoothConnectionsFreeResponse` updates.
  """
  @spec put_bluetooth_connections_free_subscribed(t(), boolean()) :: t()
  def put_bluetooth_connections_free_subscribed(%__MODULE__{} = state, subscribed?) do
    %{state | bluetooth_connections_free_subscribed: subscribed?}
  end

  @doc """
  Replace the set of BLE peripheral addresses this connection owns.
  """
  @spec put_bluetooth_owned(t(), MapSet.t(non_neg_integer())) :: t()
  def put_bluetooth_owned(%__MODULE__{} = state, owned) when is_struct(owned, MapSet) do
    %{state | bluetooth_owned: owned}
  end

  @doc """
  Record that this connection now owns the given peripheral address.
  """
  @spec add_bluetooth_owned(t(), non_neg_integer()) :: t()
  def add_bluetooth_owned(%__MODULE__{} = state, address) do
    %{state | bluetooth_owned: MapSet.put(state.bluetooth_owned, address)}
  end

  @doc """
  Forget that this connection owns the given peripheral address.
  """
  @spec drop_bluetooth_owned(t(), non_neg_integer()) :: t()
  def drop_bluetooth_owned(%__MODULE__{} = state, address) do
    %{state | bluetooth_owned: MapSet.delete(state.bluetooth_owned, address)}
  end

  @doc """
  Return `true` if this connection owns the given peripheral address.
  """
  @spec bluetooth_owns?(t(), non_neg_integer()) :: boolean()
  def bluetooth_owns?(%__MODULE__{bluetooth_owned: owned}, address) do
    MapSet.member?(owned, address)
  end

  @doc """
  Return the adapter module configured for `feature`, or `nil`.
  """
  @spec adapter(t(), feature()) :: module() | nil
  def adapter(%__MODULE__{adapters: adapters}, feature) do
    Map.get(adapters, feature)
  end

  @doc """
  Return `true` if an adapter is configured for `feature`.
  """
  @spec adapter?(t(), feature()) :: boolean()
  def adapter?(%__MODULE__{} = state, feature), do: adapter(state, feature) != nil

  @doc """
  Replace the encryption state.
  """
  @spec put_encryption(t(), encryption()) :: t()
  def put_encryption(%__MODULE__{} = state, enc), do: %{state | encryption: enc}

  @doc """
  Record the client identity learned from a `HelloRequest`.
  """
  @spec put_client_hello(t(), String.t(), {non_neg_integer(), non_neg_integer()}) :: t()
  def put_client_hello(%__MODULE__{} = state, client_info, {_major, _minor} = api_version) do
    %{state | client_info: client_info, api_version: api_version}
  end

  @doc """
  Stamp the most recent inbound activity time (epoch seconds).
  """
  @spec touch_activity(t(), integer()) :: t()
  def touch_activity(%__MODULE__{} = state, now) when is_integer(now) do
    %{state | last_activity_at: now}
  end
end
