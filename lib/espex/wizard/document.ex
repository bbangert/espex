defmodule Espex.Wizard.Document do
  @moduledoc since: "0.12.0"
  @moduledoc """
  The device wizard: the pages Home Assistant shows when the device is
  added. Build it with `new/1` and return it from `c:Espex.Wizard.wizard/0`.

      alias Espex.Wizard.{Document, Entity, EntityFilter, Input, Page}

      Document.new!(
        pages: [
          %Page{
            title: "Calendars",
            description: "Pick the calendars to show on the display.",
            inputs: [
              %Input{
                id: "calendars",
                multiple: true,
                entity_filters: [%EntityFilter{domain: ["calendar"]}]
              }
            ]
          },
          %Page{
            title: "Backlight",
            entities: [%Entity{key: 1001, description: "Turn it on to test the display."}]
          }
        ]
      )

  `new/1` checks the document against ESPHome's limits, so a mistake
  shows up when the host builds it rather than when a client connects:

    * at least one page, and each page has an entity or an input
    * page titles up to 127 bytes, descriptions up to 255
    * each filter sets at least one field; filter strings are 1-63 bytes,
      `supported_features` entries 1-127
    * `max_length` is 255-4095 and only on a `multiple: true` input
    * input ids are unique and their hashes do not collide
    * the compressed document fits one API message (65511 bytes)

  It also fills each input's `key` from its `id`.

  Strings are passed to Home Assistant verbatim, so they may be
  translation placeholders such as `"[%key:component::light::title%]"`.

  On the wire the document is compact UTF-8 JSON, version 1, compressed
  into one zstd frame. Empty and unset values are left out. Building it
  needs OTP 28 or newer for `:zstd`.
  """

  import Bitwise, only: [<<<: 2]

  alias Espex.Wizard
  alias Espex.Wizard.{Entity, EntityFilter, Input, Page}

  @type t :: %__MODULE__{pages: [Page.t()], blob: binary() | nil}

  @derive {Inspect, except: [:blob]}
  @enforce_keys [:pages]
  defstruct [:pages, blob: nil]

  @json_version 1
  @zstd_level 19

  # A Noise frame's 16-bit size covers the inner header (4), the
  # DeviceWizardResponse encoding (a 1-byte tag and a 3-byte length ahead
  # of the blob) and the MAC (16). aioesphomeapi refuses more than 1 MiB
  # of decompressed JSON.
  @blob_max_size 65_535 - 4 - 4 - 16
  @json_max_size 1 <<< 20

  @title_max 127
  @description_max 255
  @filter_max 63
  @supported_feature_max 127
  @uint32_max 0xFFFFFFFF

  @doc since: "0.12.0"
  @doc """
  Build and check a document from `pages:`, a list of `Espex.Wizard.Page`
  structs. Returns `{:error, message}` naming the first problem.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts) when is_list(opts) do
    pages = Keyword.get(opts, :pages, [])
    if not is_list(pages) or pages == [], do: invalid("a wizard needs at least one page")

    pages = pages |> Enum.with_index(1) |> Enum.map(&check_page/1)
    check_unique_inputs(pages)
    document = %__MODULE__{pages: pages}
    {:ok, %{document | blob: encode(document)}}
  catch
    {:invalid_wizard, message} -> {:error, message}
  end

  @doc since: "0.12.0"
  @doc """
  Like `new/1`, but raises `ArgumentError` on a problem.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, document} -> document
      {:error, message} -> raise ArgumentError, "invalid device wizard: " <> message
    end
  end

  @doc since: "0.12.0"
  @doc """
  The document as sent in `DeviceWizardResponse.data`: compact JSON in
  one zstd frame. Built once by `new/1`.
  """
  @spec to_blob(t()) :: binary()
  def to_blob(%__MODULE__{blob: blob}) when is_binary(blob), do: blob
  def to_blob(%__MODULE__{} = document), do: document |> to_json() |> compress()

  @doc false
  @spec find_input(t(), non_neg_integer()) :: Input.t() | nil
  def find_input(%__MODULE__{pages: pages}, key) do
    Enum.find_value(pages, fn page -> Enum.find(page.inputs, &(&1.key == key)) end)
  end

  # -- Checks --

  @spec invalid(String.t()) :: no_return()
  defp invalid(message), do: throw({:invalid_wizard, message})

  defp check_page({%Page{} = page, n}) do
    where = "page #{n}"
    check_text(page.title, @title_max, "#{where} title")
    check_text(page.description, @description_max, "#{where} description")
    check_list(page.entities, "#{where} entities")
    check_list(page.inputs, "#{where} inputs")
    if page.entities == [] and page.inputs == [], do: invalid("#{where} has no entities or inputs")

    Enum.each(page.entities, &check_entity(&1, where))
    %{page | inputs: Enum.map(page.inputs, &check_input(&1, where))}
  end

  defp check_page({other, n}), do: invalid("page #{n} is not an %Espex.Wizard.Page{}: #{inspect(other)}")

  defp check_entity(%Entity{} = entity, where) do
    where = "#{where} entity #{inspect(entity.key)}"
    check_uint32(entity.key, "#{where} key")
    check_uint32(entity.device_id, "#{where} device_id")
    check_text(entity.description, @description_max, "#{where} description")
  end

  defp check_entity(other, where), do: invalid("#{where}: #{inspect(other)} is not an %Espex.Wizard.Entity{}")

  defp check_input(%Input{id: id} = input, where) do
    if not (is_binary(id) and id != "" and String.valid?(id)), do: invalid("#{where}: input id must be a string")
    where = "#{where} input #{inspect(id)}"
    check_text(input.description, @description_max, "#{where} description")
    if not is_boolean(input.multiple), do: invalid("#{where} multiple must be a boolean")
    check_max_length(input, where)
    check_list(input.entity_filters, "#{where} entity_filters")
    Enum.each(input.entity_filters, &check_filter(&1, where))
    %{input | key: Wizard.fnv1_hash(id)}
  end

  defp check_input(other, where), do: invalid("#{where}: #{inspect(other)} is not an %Espex.Wizard.Input{}")

  defp check_max_length(%Input{max_length: nil}, _where), do: :ok

  defp check_max_length(%Input{multiple: false}, where),
    do: invalid("#{where} max_length only applies to an input with multiple: true")

  defp check_max_length(%Input{max_length: max}, _where) when max in 255..4095//1, do: :ok

  defp check_max_length(%Input{max_length: max}, where),
    do: invalid("#{where} max_length #{inspect(max)} is not 255-4095")

  defp check_filter(%EntityFilter{} = filter, where) do
    where = "#{where} filter"

    if filter.integration in [nil, ""] and filter.domain == [] and filter.device_class == [] and
         filter.supported_features == [] do
      invalid("#{where} sets no field")
    end

    if filter.integration != nil, do: check_string(filter.integration, @filter_max, "#{where} integration")
    check_strings(filter.domain, @filter_max, "#{where} domain")
    check_strings(filter.device_class, @filter_max, "#{where} device_class")
    check_strings(filter.supported_features, @supported_feature_max, "#{where} supported_features")
  end

  defp check_filter(other, where), do: invalid("#{where}: #{inspect(other)} is not an %Espex.Wizard.EntityFilter{}")

  defp check_text(nil, _max, _what), do: :ok

  defp check_text(text, max, what) when is_binary(text) do
    if not String.valid?(text), do: invalid("#{what} is not valid UTF-8")
    if byte_size(text) > max, do: invalid("#{what} is #{byte_size(text)} bytes, at most #{max}")
    :ok
  end

  defp check_text(other, _max, what), do: invalid("#{what} must be a string, got #{inspect(other)}")

  defp check_string(string, max, what) do
    if string == "", do: invalid("#{what} is empty")
    check_text(string, max, what)
  end

  defp check_strings(strings, max, what) do
    check_list(strings, what)
    Enum.each(strings, &check_string(&1, max, what))
  end

  defp check_list(list, _what) when is_list(list), do: :ok
  defp check_list(other, what), do: invalid("#{what} must be a list, got #{inspect(other)}")

  defp check_uint32(value, _what) when is_integer(value) and value in 0..@uint32_max//1, do: :ok
  defp check_uint32(value, what), do: invalid("#{what} #{inspect(value)} is not a 32-bit unsigned integer")

  defp check_unique_inputs(pages) do
    for page <- pages, %Input{key: key, id: id} <- page.inputs, reduce: %{} do
      seen ->
        case seen do
          %{^key => ^id} -> invalid("input #{inspect(id)} is used more than once")
          %{^key => other} -> invalid("inputs #{inspect(other)} and #{inspect(id)} have the same hash, rename one")
          _ -> Map.put(seen, key, id)
        end
    end
  end

  defp encode(document) do
    if not Wizard.available?(), do: invalid("the device wizard needs OTP 28 or newer for :zstd")

    json = to_json(document)
    if byte_size(json) > @json_max_size, do: invalid("the wizard is #{byte_size(json)} bytes of JSON, at most 1 MiB")

    blob = compress(json)

    if byte_size(blob) > @blob_max_size do
      invalid("the compressed wizard is #{byte_size(blob)} bytes, at most #{@blob_max_size} fit one API message")
    end

    blob
  end

  # -- Encoding --

  defp compress(json), do: json |> :zstd.compress(%{compressionLevel: @zstd_level}) |> IO.iodata_to_binary()

  defp to_json(%__MODULE__{pages: pages}) do
    JSON.encode!(%{"version" => @json_version, "pages" => Enum.map(pages, &page_json/1)})
  end

  defp page_json(%Page{} = page) do
    compact(
      title: page.title,
      description: page.description,
      entities: Enum.map(page.entities, &entity_json/1),
      inputs: Enum.map(page.inputs, &input_json/1)
    )
  end

  defp entity_json(%Entity{} = entity) do
    compact(
      key: entity.key,
      device_id: if(entity.device_id != 0, do: entity.device_id),
      description: entity.description
    )
  end

  defp input_json(%Input{} = input) do
    compact(
      key: Wizard.fnv1_hash(input.id),
      description: input.description,
      multiple: input.multiple,
      max_length: input.max_length,
      entity_filters: Enum.map(input.entity_filters, &filter_json/1)
    )
  end

  defp filter_json(%EntityFilter{} = filter) do
    compact(
      integration: filter.integration,
      domain: filter.domain,
      device_class: filter.device_class,
      supported_features: filter.supported_features
    )
  end

  # Empty and unset values are left out, as upstream; `multiple` only
  # appears when true.
  defp compact(fields) do
    for {key, value} <- fields, value not in [nil, "", [], false], into: %{}, do: {Atom.to_string(key), value}
  end
end
