defmodule Espex.BluetoothProxy.Service do
  @moduledoc """
  A GATT service streamed from a `Espex.BluetoothProxy` adapter.

  Adapters build these in response to `c:Espex.BluetoothProxy.gatt_get_services/1`
  and send them one-at-a-time as:

      send(subscriber, {:espex_ble_gatt_service, address, service})

  Espex wraps each service in a single `BluetoothGATTGetServicesResponse`
  and forwards it to the client. After the last service, the adapter
  emits `{:espex_ble_gatt_services_done, address}` to signal completion.

  ## UUID encoding

  See `Espex.BluetoothProxy.encode_uuid/1` for the shared UUID rules.
  """

  alias Espex.{BluetoothProxy, Proto}
  alias Espex.BluetoothProxy.Characteristic

  @type t :: %__MODULE__{
          uuid: BluetoothProxy.uuid(),
          handle: non_neg_integer(),
          characteristics: [Characteristic.t()]
        }

  @enforce_keys [:uuid, :handle]
  defstruct [:uuid, :handle, characteristics: []]

  @doc """
  Build a service from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Convert to the wire `Proto.BluetoothGATTService`.
  """
  @spec to_proto(t()) :: Proto.BluetoothGATTService.t()
  def to_proto(%__MODULE__{} = service) do
    {uuid, short_uuid} = BluetoothProxy.encode_uuid(service.uuid)

    %Proto.BluetoothGATTService{
      uuid: uuid,
      handle: service.handle,
      characteristics: Enum.map(service.characteristics, &Characteristic.to_proto/1),
      short_uuid: short_uuid
    }
  end
end
