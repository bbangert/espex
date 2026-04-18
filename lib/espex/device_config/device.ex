defmodule Espex.DeviceConfig.Device do
  @moduledoc """
  Description of an ESPHome sub-device.

  An ESPHome node can expose multiple logical devices. Each entity
  advertises which sub-device it belongs to via its `device_id` field.
  A top-level entity (attached to the node itself, not a sub-device)
  uses `device_id: 0` — which is the default for protobuf uint32 and
  therefore also the default when the field is omitted.

  Populate `Espex.DeviceConfig`'s `:devices` field with a list of
  these structs to declare the sub-devices exposed by your server.
  """

  alias Espex.Proto

  @type t :: %__MODULE__{
          id: pos_integer(),
          name: String.t(),
          area_id: non_neg_integer()
        }

  @enforce_keys [:id, :name]
  defstruct [:id, :name, area_id: 0]

  @doc """
  Build a `%Device{}` from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Convert to the protobuf `DeviceInfo` message used inside
  `DeviceInfoResponse.devices`.
  """
  @spec to_proto(t()) :: Proto.DeviceInfo.t()
  def to_proto(%__MODULE__{} = device) do
    %Proto.DeviceInfo{device_id: device.id, name: device.name, area_id: device.area_id}
  end
end
