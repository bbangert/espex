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
          serial_proxies: [SerialProxy.Info.t()],
          infrared_entities: [InfraredProxy.Entity.t()],
          entities: [struct()],
          opened_ports: %{non_neg_integer() => term()},
          pending_subscriptions: MapSet.t(non_neg_integer()),
          zwave_subscribed: boolean(),
          infrared_subscribed: boolean(),
          bluetooth_scanner_subscribed: boolean(),
          bluetooth_connections_free_subscribed: boolean(),
          bluetooth_owned: MapSet.t(non_neg_integer()),
          adapters: adapters(),
          clock_fun: (-> non_neg_integer()),
          encryption: encryption()
        }

  @enforce_keys [:device_config, :peer]
  defstruct [
    :device_config,
    :peer,
    server_name: nil,
    buffer: <<>>,
    serial_proxies: [],
    infrared_entities: [],
    entities: [],
    opened_ports: %{},
    pending_subscriptions: MapSet.new(),
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
      entity_provider: nil
    },
    clock_fun: &__MODULE__.os_time_second/0,
    encryption: :disabled
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
  Record that the client subscribed to `instance` before the port was open.
  The intent is replayed once the matching configure/open succeeds.
  """
  @spec put_pending_subscription(t(), non_neg_integer()) :: t()
  def put_pending_subscription(%__MODULE__{} = state, instance) do
    %{state | pending_subscriptions: MapSet.put(state.pending_subscriptions, instance)}
  end

  @doc """
  Forget any pending pre-open subscribe for `instance`.
  """
  @spec drop_pending_subscription(t(), non_neg_integer()) :: t()
  def drop_pending_subscription(%__MODULE__{} = state, instance) do
    %{state | pending_subscriptions: MapSet.delete(state.pending_subscriptions, instance)}
  end

  @doc """
  Return `true` if `instance` has a pending pre-open subscribe.
  """
  @spec pending_subscription?(t(), non_neg_integer()) :: boolean()
  def pending_subscription?(%__MODULE__{pending_subscriptions: set}, instance) do
    MapSet.member?(set, instance)
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
  def put_bluetooth_owned(%__MODULE__{} = state, owned) do
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
end
