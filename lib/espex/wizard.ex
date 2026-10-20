defmodule Espex.Wizard do
  @moduledoc since: "0.12.0"
  @moduledoc """
  Behaviour for device wizard adapters (API 1.18).

  The device wizard is the set of pages Home Assistant shows when the
  device is added. A page can show entities of this device, for example
  a switch to test, and ask the user to pick Home Assistant entities, for
  example the calendars a display should show. The client sends each
  pick back to the device, and espex hands it to `c:input_set/2`.

  Without a `:wizard` adapter espex reports no wizard and ignores the
  wizard messages, as ESPHome firmware built without one.

  ## Callbacks

  | Callback | Purpose |
  |----------|---------|
  | `c:wizard/0` | Return the `Espex.Wizard.Document` |
  | `c:input_set/2` | Receive the entity ids the user picked for an input |

  ## The document

  Build the document with `Espex.Wizard.Document.new!/1`. It checks the
  document against ESPHome's limits, so build it once, for example in a
  module attribute or at application start, and return it from
  `c:wizard/0`.

  espex calls `c:wizard/0` once per connection, when the connection is
  accepted. Clients read the wizard once, when the device is added, so a
  changed document reaches Home Assistant only when the device is added
  again.

  Strings pass through to Home Assistant verbatim, so they may be
  translation placeholders such as `"[%key:component::light::title%]"`.

  ## Inputs

  Each `Espex.Wizard.Input` has an `id` you choose. Its key on the wire
  is `fnv1_hash/1` of that id, the same hash ESPHome uses, and
  `c:input_set/2` receives that key. Compare against `input.key` from
  the built document, or against `fnv1_hash("my_input")`.

  espex validates each `WizardInputSetRequest` as ESPHome does before it
  calls `c:input_set/2`:

    * A request for an unknown key is ignored.
    * A single input takes one entity id of 1-255 bytes containing a `.`.
    * A `multiple: true` input takes a comma-separated list. Spaces
      around each id are trimmed. The whole request is ignored when any
      id is empty or has no `.`, or when the ids joined by `,` are longer
      than the input's `max_length` (255 by default).

  An ignored request is logged as a warning, without its value, and
  `c:input_set/2` is not called. The client gets no reply either way.

  Every espex input is standalone: it only hands the entity ids to your
  adapter, which decides what they drive. ESPHome's inputs linked to a
  `homeassistant` platform entity need Home Assistant state
  subscriptions, which espex does not implement.

  ## Nothing to persist

  ESPHome keeps the picks in RAM only, and clients are built for that:
  after every connection, and whenever the user changes a pick, the
  client sends a `WizardInputSetRequest` for every input. So
  `c:input_set/2` is called again after each reconnect, and the adapter
  need not store the picks across restarts.

  ## OTP 28

  The document is compressed with OTP's `:zstd` module, which OTP 28
  added. `Espex.Supervisor` refuses to start with a `:wizard` adapter on
  an older OTP, and `available?/0` reports whether this runtime can serve
  a wizard.

  ## Example

      defmodule MyApp.Wizard do
        @behaviour Espex.Wizard

        alias Espex.Wizard.{Document, EntityFilter, Input, Page}

        @impl true
        def wizard do
          Document.new!(
            pages: [
              %Page{
                title: "Calendars",
                inputs: [
                  %Input{
                    id: "calendars",
                    description: "The calendars to show",
                    multiple: true,
                    entity_filters: [%EntityFilter{domain: ["calendar"]}]
                  }
                ]
              }
            ]
          )
        end

        @calendars Espex.Wizard.fnv1_hash("calendars")

        @impl true
        def input_set(@calendars, entity_ids), do: MyApp.Display.show_calendars(entity_ids)
        def input_set(_key, _entity_ids), do: :ok
      end

  ## Wiring

      Espex.start_link(
        device_config: [name: "display"],
        wizard: MyApp.Wizard
      )
  """

  import Bitwise

  alias Espex.Wizard.Document

  @fnv1_offset_basis 2_166_136_261
  @fnv1_prime 16_777_619

  @doc """
  Return the wizard document. Called once per connection, at accept.
  """
  @callback wizard() :: Document.t()

  @doc """
  The user picked `entity_ids` for the input with `key`. A single input
  always gets a one-element list. Return `{:error, reason}` to have espex
  log a warning; the client gets no reply either way.
  """
  @callback input_set(key :: non_neg_integer(), entity_ids :: [String.t(), ...]) :: :ok | {:error, term()}

  @doc since: "0.12.0"
  @doc """
  The 32-bit FNV-1 hash (multiply, then xor) of `string`'s code points.
  The same as ESPHome's `fnv1_hash`, which keys wizard inputs by the hash
  of their id.

      iex> Espex.Wizard.fnv1_hash("calendar_input")
      1341199854
  """
  @spec fnv1_hash(String.t()) :: non_neg_integer()
  def fnv1_hash(string) when is_binary(string) do
    for <<code_point::utf8 <- string>>, reduce: @fnv1_offset_basis do
      hash -> bxor(hash * @fnv1_prime &&& 0xFFFFFFFF, code_point)
    end
  end

  @doc since: "0.12.0"
  @doc """
  Whether this runtime can serve a wizard: true on OTP 28 or newer,
  which has the `:zstd` module.
  """
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(:zstd)
end
