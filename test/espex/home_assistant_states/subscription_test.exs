defmodule Espex.HomeAssistantStates.SubscriptionTest do
  use ExUnit.Case, async: true

  alias Espex.HomeAssistantStates.Subscription

  doctest Subscription

  test "an empty attribute means none" do
    assert {:ok, %Subscription{attribute: nil}} = Subscription.new(entity_id: "a.b", attribute: "")
  end

  test "accepts a map and a hand-built struct" do
    assert {:ok, %Subscription{entity_id: "a.b"}} = Subscription.new(%{entity_id: "a.b"})
    assert {:ok, %Subscription{once: true}} = Subscription.new(%Subscription{entity_id: "a.b", once: true})
  end

  test "refuses a bad entity id, attribute, once or key" do
    long = String.duplicate("a", 254) <> ".b"

    for fields <- [
          [entity_id: "nodot"],
          [entity_id: ""],
          [entity_id: long],
          [entity_id: nil],
          [entity_id: "a.b", attribute: 1],
          [entity_id: "a.b", attribute: String.duplicate("x", 256)],
          [entity_id: "a.b", once: "yes"],
          [entity_id: "a.b", typo: true],
          [:not_a_keyword],
          %Subscription{entity_id: <<0xFF, ?.>>}
        ] do
      assert Subscription.new(fields) == {:error, :invalid_subscription}, inspect(fields)
    end
  end

  test "new!/1 names the bad field" do
    assert_raise ArgumentError, ~r/entity_id must be/, fn -> Subscription.new!(entity_id: "nodot") end
  end
end
