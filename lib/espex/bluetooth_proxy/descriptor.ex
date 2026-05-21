defmodule Espex.BluetoothProxy.Descriptor do
  @moduledoc """
  A GATT descriptor inside a `Espex.BluetoothProxy.Characteristic`.

  Built by `Espex.BluetoothProxy` adapters and passed inside service
  trees during `c:Espex.BluetoothProxy.gatt_get_services/1` streaming.
  Espex converts to the wire `BluetoothGATTDescriptor` at the send
  boundary.

  ## UUID encoding

  See `Espex.BluetoothProxy.encode_uuid/1` for the rules — the `:uuid`
  field accepts either a 16-byte binary (full 128-bit) or a small
  non-negative integer (Bluetooth SIG short UUID).
  """

  alias Espex.{BluetoothProxy, Proto}

  @type t :: %__MODULE__{
          uuid: BluetoothProxy.uuid(),
          handle: non_neg_integer()
        }

  @enforce_keys [:uuid, :handle]
  defstruct [:uuid, :handle]

  @doc """
  Build a descriptor from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Convert to the wire `Proto.BluetoothGATTDescriptor`.
  """
  @spec to_proto(t()) :: Proto.BluetoothGATTDescriptor.t()
  def to_proto(%__MODULE__{} = descriptor) do
    {uuid, short_uuid} = BluetoothProxy.encode_uuid(descriptor.uuid)

    %Proto.BluetoothGATTDescriptor{
      uuid: uuid,
      handle: descriptor.handle,
      short_uuid: short_uuid
    }
  end
end
