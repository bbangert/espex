defmodule Espex.BluetoothProxy.Characteristic do
  @moduledoc """
  A GATT characteristic inside a `Espex.BluetoothProxy.Service`.

  Built by `Espex.BluetoothProxy` adapters and passed inside service
  trees during `c:Espex.BluetoothProxy.gatt_get_services/1` streaming.
  Espex converts to the wire `BluetoothGATTCharacteristic` at the send
  boundary.

  ## UUID encoding

  See `Espex.BluetoothProxy.encode_uuid/1` for the shared UUID rules.

  ## `properties`

  The `:properties` field is the standard BLE characteristic-properties
  bitfield (e.g. `0x02 = READ`, `0x08 = WRITE`, `0x10 = NOTIFY`).
  Espex passes the value through untouched; adapters should set it
  from whatever their underlying BLE stack reports.
  """

  alias Espex.{BluetoothProxy, Proto}
  alias Espex.BluetoothProxy.Descriptor

  @type t :: %__MODULE__{
          uuid: BluetoothProxy.uuid(),
          handle: non_neg_integer(),
          properties: non_neg_integer(),
          descriptors: [Descriptor.t()]
        }

  @enforce_keys [:uuid, :handle]
  defstruct [:uuid, :handle, properties: 0, descriptors: []]

  @doc """
  Build a characteristic from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Convert to the wire `Proto.BluetoothGATTCharacteristic`.
  """
  @spec to_proto(t()) :: Proto.BluetoothGATTCharacteristic.t()
  def to_proto(%__MODULE__{} = characteristic) do
    {uuid, short_uuid} = BluetoothProxy.encode_uuid(characteristic.uuid)

    %Proto.BluetoothGATTCharacteristic{
      uuid: uuid,
      handle: characteristic.handle,
      properties: characteristic.properties,
      descriptors: Enum.map(characteristic.descriptors, &Descriptor.to_proto/1),
      short_uuid: short_uuid
    }
  end
end
