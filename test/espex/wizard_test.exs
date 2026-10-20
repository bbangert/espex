defmodule Espex.WizardTest do
  use ExUnit.Case, async: true

  alias Espex.Wizard
  alias Espex.Wizard.{Document, Entity, EntityFilter, Input, Page}

  doctest Espex.Wizard

  defp page(fields \\ []), do: struct!(%Page{entities: [%Entity{key: 1}]}, fields)

  defp decode(document) do
    document |> Document.to_blob() |> :zstd.decompress() |> IO.iodata_to_binary() |> JSON.decode!()
  end

  defp error(pages) do
    assert {:error, message} = Document.new(pages: pages)
    message
  end

  describe "fnv1_hash/1" do
    # Reference values from ESPHome's esphome.helpers.fnv1_hash, which
    # hashes code points.
    test "matches ESPHome" do
      assert Wizard.fnv1_hash("") == 2_166_136_261
      assert Wizard.fnv1_hash("a") == 84_696_446
      assert Wizard.fnv1_hash("calendar_input") == 1_341_199_854
      assert Wizard.fnv1_hash("wizard_light") == 188_660_093
      assert Wizard.fnv1_hash("café") == 3_853_951_970
    end
  end

  test "available?/0 is true on OTP 28 or newer" do
    assert Wizard.available?() == String.to_integer(System.otp_release()) >= 28
  end

  describe "Document.new/1" do
    test "fills each input's key from its id" do
      {:ok, document} = Document.new(pages: [%Page{inputs: [%Input{id: "calendar_input"}]}])
      assert [%Page{inputs: [%Input{key: 1_341_199_854}]}] = document.pages
      assert %Input{id: "calendar_input"} = Document.find_input(document, 1_341_199_854)
      assert Document.find_input(document, 1) == nil
    end

    test "needs at least one page, each with an entity or an input" do
      assert error([]) =~ "at least one page"
      assert error([%Page{title: "Empty"}]) =~ "page 1 has no entities or inputs"
    end

    test "limits titles to 127 bytes and descriptions to 255" do
      assert {:ok, _} = Document.new(pages: [page(title: String.duplicate("t", 127))])
      assert error([page(title: String.duplicate("t", 128))]) =~ "page 1 title is 128 bytes, at most 127"
      assert {:ok, _} = Document.new(pages: [page(description: String.duplicate("d", 255))])
      assert error([page(description: String.duplicate("d", 256))]) =~ "page 1 description is 256 bytes"

      long = String.duplicate("d", 256)
      assert error([%Page{entities: [%Entity{key: 1, description: long}]}]) =~ "entity 1 description"
      assert error([%Page{inputs: [%Input{id: "x", description: long}]}]) =~ ~s(input "x" description)
    end

    test "counts bytes, not characters" do
      assert error([page(title: String.duplicate("é", 64))]) =~ "128 bytes"
    end

    test "checks entity keys and device ids are 32-bit" do
      assert error([%Page{entities: [%Entity{key: -1}]}]) =~ "key -1 is not a 32-bit unsigned integer"
      assert error([%Page{entities: [%Entity{key: 1, device_id: 0x1_0000_0000}]}]) =~ "device_id"
    end

    test "max_length is 255-4095 and only on a multiple input" do
      ok = fn max -> Document.new(pages: [%Page{inputs: [%Input{id: "x", multiple: true, max_length: max}]}]) end
      assert {:ok, _} = ok.(255)
      assert {:ok, _} = ok.(4095)
      assert {:error, "page 1 input \"x\" max_length 254 is not 255-4095"} = ok.(254)
      assert {:error, _} = ok.(4096)

      assert error([%Page{inputs: [%Input{id: "x", max_length: 300}]}]) =~
               "max_length only applies to an input with multiple: true"
    end

    test "a filter sets at least one field, with strings of 1-63 bytes (supported_features 1-127)" do
      input = fn filter -> [%Page{inputs: [%Input{id: "x", entity_filters: [filter]}]}] end

      assert error(input.(%EntityFilter{})) =~ "filter sets no field"
      assert error(input.(%EntityFilter{integration: ""})) =~ "filter sets no field"
      assert error(input.(%EntityFilter{domain: [""]})) =~ "domain is empty"
      assert error(input.(%EntityFilter{domain: [nil]})) =~ "domain must be a string, got nil"
      assert error(input.(%EntityFilter{device_class: ["door", 1]})) =~ "device_class must be a string"
      assert error(input.(%EntityFilter{supported_features: [nil]})) =~ "supported_features must be a string"
      assert error(input.(%EntityFilter{integration: String.duplicate("i", 64)})) =~ "integration is 64 bytes"
      assert error(input.(%EntityFilter{device_class: [String.duplicate("c", 64)]})) =~ "device_class"
      assert {:ok, _} = Document.new(pages: input.(%EntityFilter{supported_features: [String.duplicate("f", 127)]}))
      assert error(input.(%EntityFilter{supported_features: [String.duplicate("f", 128)]})) =~ "supported_features"
    end

    test "input ids are unique across pages" do
      assert error([%Page{inputs: [%Input{id: "x"}]}, %Page{inputs: [%Input{id: "x"}]}]) =~
               ~s(input "x" is used more than once)
    end

    test "rejects what is not a page, entity, input or filter" do
      assert error([:page]) =~ "page 1 is not an %Espex.Wizard.Page{}"
      assert error([%Page{entities: [%{key: 1}]}]) =~ "is not an %Espex.Wizard.Entity{}"
      assert error([%Page{inputs: [%Input{id: ""}]}]) =~ "input id must be a string"
    end

    test "rejects a wizard too large for one API message" do
      # Base64 of random bytes compresses to about 6 bits a byte: 400
      # descriptions of 255 bytes come to more than 65512.
      pages =
        for n <- 1..400 do
          description = :crypto.strong_rand_bytes(192) |> Base.encode64() |> binary_part(0, 255)
          %Page{description: description, entities: [%Entity{key: n}]}
        end

      assert error(pages) =~ "fit one API message"
    end

    test "new!/1 raises ArgumentError" do
      assert_raise ArgumentError, ~r/invalid device wizard: a wizard needs at least one page/, fn ->
        Document.new!(pages: [])
      end
    end
  end

  describe "Document.to_blob/1" do
    test "is version 1 JSON with empty and unset values left out" do
      document =
        Document.new!(
          pages: [
            %Page{
              title: "Lights",
              description: "",
              entities: [%Entity{key: 7}, %Entity{key: 8, device_id: 42, description: "Main"}],
              inputs: [
                %Input{id: "single", entity_filters: [%EntityFilter{domain: ["light"], integration: "hue"}]},
                %Input{id: "many", description: "Pick", multiple: true, max_length: 1023}
              ]
            }
          ]
        )

      assert decode(document) == %{
               "version" => 1,
               "pages" => [
                 %{
                   "title" => "Lights",
                   "entities" => [%{"key" => 7}, %{"key" => 8, "device_id" => 42, "description" => "Main"}],
                   "inputs" => [
                     %{
                       "key" => Wizard.fnv1_hash("single"),
                       "entity_filters" => [%{"domain" => ["light"], "integration" => "hue"}]
                     },
                     %{
                       "key" => Wizard.fnv1_hash("many"),
                       "description" => "Pick",
                       "multiple" => true,
                       "max_length" => 1023
                     }
                   ]
                 }
               ]
             }
    end

    test "passes translation placeholders and UTF-8 through verbatim" do
      placeholder = "[%key:component::light::title%]"
      document = Document.new!(pages: [page(title: placeholder, description: "Café ☕")])
      assert [%{"title" => ^placeholder, "description" => "Café ☕"}] = decode(document)["pages"]
    end

    test "is one zstd frame" do
      blob = Document.to_blob(Document.new!(pages: [page()]))
      assert <<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = blob
    end

    test "builds the blob for a struct made without new/1" do
      document = %Document{pages: [%Page{inputs: [%Input{id: "x"}]}]}
      assert [%{"inputs" => [%{"key" => key}]}] = decode(document)["pages"]
      assert key == Wizard.fnv1_hash("x")
    end
  end

  describe "Input.parse_entity_ids/2" do
    @single %Input{id: "single"}
    @multiple %Input{id: "many", multiple: true}

    test "a single input takes one id of 1-255 bytes containing a '.'" do
      assert Input.parse_entity_ids(@single, "light.kitchen") == {:ok, ["light.kitchen"]}
      assert Input.parse_entity_ids(@single, "") == :error
      assert Input.parse_entity_ids(@single, "kitchen") == :error

      at_limit = "light." <> String.duplicate("k", 249)
      assert byte_size(at_limit) == 255
      assert Input.parse_entity_ids(@single, at_limit) == {:ok, [at_limit]}
      assert Input.parse_entity_ids(@single, at_limit <> "k") == :error
    end

    test "a single input is taken as sent, commas and spaces included" do
      assert Input.parse_entity_ids(@single, " light.a,light.b") == {:ok, [" light.a,light.b"]}
    end

    test "a multiple input splits on ',' and trims spaces" do
      assert Input.parse_entity_ids(@multiple, "calendar.a,calendar.b") == {:ok, ["calendar.a", "calendar.b"]}
      assert Input.parse_entity_ids(@multiple, " calendar.a , calendar.b ") == {:ok, ["calendar.a", "calendar.b"]}
      assert Input.parse_entity_ids(@multiple, "calendar.a") == {:ok, ["calendar.a"]}
    end

    test "a multiple input is refused whole for an empty id or one without a '.'" do
      assert Input.parse_entity_ids(@multiple, "") == :error
      assert Input.parse_entity_ids(@multiple, "calendar.a,,calendar.b") == :error
      assert Input.parse_entity_ids(@multiple, "calendar.a, ") == :error
      assert Input.parse_entity_ids(@multiple, "calendar.a,b") == :error
    end

    test "a multiple input counts the joined length without spaces against max_length" do
      # 25 ids of 11 bytes and 24 commas: 299 bytes joined.
      ids = for n <- 1..25, do: "calendar.#{String.pad_leading(Integer.to_string(n), 2, "0")}"
      joined = Enum.join(ids, ",")
      assert byte_size(joined) == 299

      assert Input.parse_entity_ids(@multiple, joined) == :error
      assert Input.parse_entity_ids(%{@multiple | max_length: 299}, joined) == {:ok, ids}
      assert Input.parse_entity_ids(%{@multiple | max_length: 298}, joined) == :error

      spaced = Enum.join(ids, " , ")
      assert Input.parse_entity_ids(%{@multiple | max_length: 299}, spaced) == {:ok, ids}
    end

    test "a value over 4095 bytes is refused before it is split" do
      ids = Enum.map_join(1..400, ",", &"light.l#{&1}")
      assert byte_size(ids) > 4095
      assert Input.parse_entity_ids(%{@multiple | max_length: 4095}, ids) == :error
      assert Input.parse_entity_ids(@single, String.duplicate("a.", 2048)) == :error
    end

    test "a multiple input defaults max_length to 255" do
      at_limit = "calendar." <> String.duplicate("a", 246)
      assert byte_size(at_limit) == 255
      assert Input.parse_entity_ids(@multiple, at_limit) == {:ok, [at_limit]}
      assert Input.parse_entity_ids(@multiple, at_limit <> "a") == :error
    end
  end
end
