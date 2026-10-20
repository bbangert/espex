defmodule Espex.Wizard.EntityFilter do
  @moduledoc since: "0.12.0"
  @moduledoc """
  Which Home Assistant entities the user may pick for an
  `Espex.Wizard.Input`. Mirrors Home Assistant's
  `EntityFilterSelectorConfig`.

  An entity matches a filter when it satisfies every field that is set.
  An input accepts an entity that matches any one of its filters. Set at
  least one field.

    * `integration` — the integration that provides the entity, 1-63
      bytes
    * `domain` — entity domains such as `["light", "switch"]`, each 1-63
      bytes
    * `device_class` — device classes, each 1-63 bytes
    * `supported_features` — feature flags such as
      `["light.LightEntityFeature.TRANSITION"]`, each 1-127 bytes
  """

  @type t :: %__MODULE__{
          integration: String.t() | nil,
          domain: [String.t()],
          device_class: [String.t()],
          supported_features: [String.t()]
        }

  defstruct integration: nil, domain: [], device_class: [], supported_features: []
end
