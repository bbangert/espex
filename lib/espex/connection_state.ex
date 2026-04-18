defmodule Espex.ConnectionState do
  @moduledoc """
  Pure per-connection state for `Espex.Connection` handlers.

  Built once at connection accept time and passed to `Espex.Dispatch`
  with every inbound message / adapter event. Contains only inert data
  — no pids, no process-level concerns other than a clock function that
  tests can override.
  """

  alias Espex.{DeviceConfig, InfraredProxy, SerialProxy}

  @type feature :: :serial_proxy | :zwave_proxy | :infrared_proxy | :entity_provider
  @type adapters :: %{feature() => module() | nil}

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
          serial_proxies: [SerialProxy.Info.t()],
          infrared_entities: [InfraredProxy.Entity.t()],
          entities: [struct()],
          opened_ports: %{non_neg_integer() => term()},
          zwave_subscribed: boolean(),
          infrared_subscribed: boolean(),
          adapters: adapters(),
          clock_fun: (-> non_neg_integer())
        }

  @enforce_keys [:device_config, :peer]
  defstruct [
    :device_config,
    :peer,
    buffer: <<>>,
    serial_proxies: [],
    infrared_entities: [],
    entities: [],
    opened_ports: %{},
    zwave_subscribed: false,
    infrared_subscribed: false,
    adapters: %{
      serial_proxy: nil,
      zwave_proxy: nil,
      infrared_proxy: nil,
      entity_provider: nil
    },
    clock_fun: &__MODULE__.os_time_second/0
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
end
