defmodule Espex.Wizard.Page do
  @moduledoc """
  One page of the device wizard. Pages are shown in the order listed.

    * `title` — optional, up to 127 bytes
    * `description` — optional, up to 255 bytes
    * `entities` — `Espex.Wizard.Entity` structs to show
    * `inputs` — `Espex.Wizard.Input` structs for the user to fill in

  A page needs at least one entity or input.
  """

  alias Espex.Wizard.{Entity, Input}

  @type t :: %__MODULE__{
          title: String.t() | nil,
          description: String.t() | nil,
          entities: [Entity.t()],
          inputs: [Input.t()]
        }

  defstruct title: nil, description: nil, entities: [], inputs: []
end
