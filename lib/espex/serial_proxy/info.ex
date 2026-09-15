defmodule Espex.SerialProxy.Info do
  @moduledoc """
  Description of a serial proxy instance exposed by an `Espex.SerialProxy`
  adapter.

  Adapters return a list of these from `c:Espex.SerialProxy.list_instances/0`.
  The `:instance` integer is the stable identifier used by the ESPHome client
  in `SerialProxyConfigureRequest`, `SerialProxyWriteRequest`, etc. — the
  adapter chooses the numbering and must keep it stable for the lifetime of
  the device.
  """

  alias Espex.Proto

  @type port_type :: :ttl | :rs232 | :rs485
  @typedoc "A modem control line the port can drive via `set_modem_pins/3`."
  @type line :: :rts | :dtr

  @type t :: %__MODULE__{
          instance: non_neg_integer(),
          name: String.t(),
          port_type: port_type(),
          configured_line_states: [line()]
        }

  @enforce_keys [:instance, :name]
  defstruct [:instance, :name, port_type: :ttl, configured_line_states: []]

  # Bit positions per ESPHome's SerialProxyLineStateFlag enum (serial_proxy.h);
  # the same values Espex.Dispatch uses for {Set,Get}ModemPins line_states.
  @line_bits %{rts: 0x01, dtr: 0x02}

  @doc """
  Build an `%Info{}` from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Convert to the protobuf `SerialProxyInfo` message used inside
  `DeviceInfoResponse.serial_proxies`.
  """
  @spec to_proto(t()) :: Proto.SerialProxyInfo.t()
  def to_proto(%__MODULE__{} = info) do
    %Proto.SerialProxyInfo{
      name: info.name,
      port_type: port_type_to_proto(info.port_type),
      configured_line_states: line_states_to_bits(info.configured_line_states)
    }
  end

  @doc """
  Encode a list of modem lines as the `configured_line_states` bitmask
  (`:rts` → bit 0, `:dtr` → bit 1).
  """
  @spec line_states_to_bits([line()]) :: non_neg_integer()
  def line_states_to_bits(lines) when is_list(lines) do
    Enum.reduce(lines, 0, fn line, acc -> Bitwise.bor(acc, Map.fetch!(@line_bits, line)) end)
  end

  defp port_type_to_proto(:ttl), do: :SERIAL_PROXY_PORT_TYPE_TTL
  defp port_type_to_proto(:rs232), do: :SERIAL_PROXY_PORT_TYPE_RS232
  defp port_type_to_proto(:rs485), do: :SERIAL_PROXY_PORT_TYPE_RS485
end
