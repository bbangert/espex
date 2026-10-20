defmodule Espex.Wizard.Input do
  @moduledoc since: "0.12.0"
  @moduledoc """
  A wizard input: the user picks a Home Assistant entity, and the client
  sends its entity id to the device.

    * `id` — a string you choose, unique in the document. Its key on the
      wire is `Espex.Wizard.fnv1_hash(id)`, which
      `Espex.Wizard.Document.new/1` fills in as `key`.
    * `description` — optional text shown with it, up to 255 bytes
    * `multiple` — the user may pick several entities (default `false`)
    * `max_length` — only with `multiple: true`: the longest list, in
      bytes joined by `,`, the device accepts. 255-4095; 255 when `nil`.
    * `entity_filters` — `Espex.Wizard.EntityFilter` structs limiting
      what the user may pick; any entity when empty

  espex hands the chosen ids to `c:Espex.Wizard.input_set/2` by `key`.
  """

  alias Espex.Wizard.EntityFilter

  @type t :: %__MODULE__{
          id: String.t(),
          key: non_neg_integer() | nil,
          description: String.t() | nil,
          multiple: boolean(),
          max_length: 255..4095 | nil,
          entity_filters: [EntityFilter.t()]
        }

  @enforce_keys [:id]
  defstruct [:id, key: nil, description: nil, multiple: false, max_length: nil, entity_filters: []]

  # Home Assistant entity ids are at most 255 bytes (api_wizard.h); no
  # input accepts more than 4095 (api.proto max_data_length).
  @entity_id_max_length 255
  @value_max_length 4095

  @doc false
  # Validate the entity_id of a WizardInputSetRequest as ESPHome's
  # api_wizard.cpp does. A single input takes one id of 1-255 bytes with a
  # '.'. A multiple input takes a ','-separated list: each id is trimmed of
  # spaces, must be non-empty with a '.', and the list joined without the
  # spaces must fit max_length.
  @spec parse_entity_ids(t(), String.t()) :: {:ok, [String.t()]} | :error
  def parse_entity_ids(%__MODULE__{}, value) when byte_size(value) > @value_max_length, do: :error

  def parse_entity_ids(%__MODULE__{multiple: false}, value) do
    if entity_id?(value) and byte_size(value) <= @entity_id_max_length, do: {:ok, [value]}, else: :error
  end

  def parse_entity_ids(%__MODULE__{multiple: true} = input, value) do
    ids = value |> String.split(",") |> Enum.map(&String.trim(&1, " "))

    if Enum.all?(ids, &entity_id?/1) and
         byte_size(Enum.join(ids, ",")) <= (input.max_length || @entity_id_max_length) do
      {:ok, ids}
    else
      :error
    end
  end

  defp entity_id?(id), do: id != "" and String.contains?(id, ".")
end
