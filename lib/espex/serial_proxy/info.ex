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

  @type t :: %__MODULE__{
          instance: non_neg_integer(),
          name: String.t(),
          port_type: port_type()
        }

  @enforce_keys [:instance, :name]
  defstruct [:instance, :name, port_type: :ttl]

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
      port_type: port_type_to_proto(info.port_type)
    }
  end

  defp port_type_to_proto(:ttl), do: :SERIAL_PROXY_PORT_TYPE_TTL
  defp port_type_to_proto(:rs232), do: :SERIAL_PROXY_PORT_TYPE_RS232
  defp port_type_to_proto(:rs485), do: :SERIAL_PROXY_PORT_TYPE_RS485
end
