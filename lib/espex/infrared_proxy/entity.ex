defmodule Espex.InfraredProxy.Entity do
  @moduledoc """
  Description of an infrared device exposed as an ESPHome entity.

  Adapters return a list of these from `c:Espex.InfraredProxy.list_entities/0`.
  The `:key` is the stable identifier used by clients for state reporting and
  commands — the adapter is responsible for generating keys that remain
  consistent across restarts (e.g., hash of a serial number or MAC).
  """

  alias Espex.Proto

  @type capability :: :transmit | :receive

  @type t :: %__MODULE__{
          key: non_neg_integer(),
          object_id: String.t(),
          name: String.t(),
          icon: String.t(),
          disabled_by_default: boolean(),
          entity_category: atom(),
          capabilities: [capability()]
        }

  @enforce_keys [:key, :object_id, :name, :capabilities]
  defstruct [
    :key,
    :object_id,
    :name,
    :capabilities,
    icon: "",
    disabled_by_default: false,
    entity_category: :ENTITY_CATEGORY_NONE
  ]

  @capability_transmit 0x01
  @capability_receive 0x02

  @doc """
  Build an entity from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Convert to the protobuf message sent during `ListEntitiesRequest`.
  """
  @spec to_proto(t()) :: Proto.ListEntitiesInfraredResponse.t()
  def to_proto(%__MODULE__{} = entity) do
    %Proto.ListEntitiesInfraredResponse{
      object_id: entity.object_id,
      key: entity.key,
      name: entity.name,
      icon: entity.icon,
      disabled_by_default: entity.disabled_by_default,
      entity_category: entity.entity_category,
      capabilities: capabilities_to_bitfield(entity.capabilities)
    }
  end

  @spec can_receive?(t()) :: boolean()
  def can_receive?(%__MODULE__{capabilities: caps}), do: :receive in caps

  @spec can_transmit?(t()) :: boolean()
  def can_transmit?(%__MODULE__{capabilities: caps}), do: :transmit in caps

  defp capabilities_to_bitfield(caps) do
    Enum.reduce(caps, 0, fn
      :transmit, acc -> Bitwise.bor(acc, @capability_transmit)
      :receive, acc -> Bitwise.bor(acc, @capability_receive)
      _, acc -> acc
    end)
  end
end
