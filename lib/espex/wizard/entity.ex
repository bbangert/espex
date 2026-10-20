defmodule Espex.Wizard.Entity do
  @moduledoc since: "0.12.0"
  @moduledoc """
  An entity of this device that a wizard page shows the user, for
  example a switch to turn on.

    * `key` — the key the entity has in its `ListEntities*Response`
    * `device_id` — the `device_id` of that response; `0` (the default)
      for the main device
    * `description` — optional text shown with it, up to 255 bytes
  """

  @type t :: %__MODULE__{
          key: non_neg_integer(),
          device_id: non_neg_integer(),
          description: String.t() | nil
        }

  @enforce_keys [:key]
  defstruct [:key, device_id: 0, description: nil]
end
