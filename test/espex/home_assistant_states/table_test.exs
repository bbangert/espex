defmodule Espex.HomeAssistantStates.TableTest do
  use ExUnit.Case, async: true

  alias Espex.HomeAssistantStates.{Subscription, Table}

  defp sub(entity_id, opts \\ []), do: Subscription.new!([entity_id: entity_id] ++ opts)

  test "an entry gaining a second owner is not added, and losing one of two is not removed" do
    {table, [_], []} = Table.put(Table.new(), :host, sub("sun.sun"))
    assert {table, [], []} = Table.put(table, :runtime, sub("sun.sun"))
    assert Table.entries(table) == [sub("sun.sun")]

    assert {table, [], []} = Table.delete(table, :host, sub("sun.sun"))
    assert {table, [], [removed]} = Table.delete(table, :runtime, sub("sun.sun"))
    assert removed == sub("sun.sun")
    assert table == %{}
  end

  test "putting an owned entry again, or deleting an unowned one, changes nothing" do
    {table, _, _} = Table.put(Table.new(), :runtime, sub("a.b"))
    assert {^table, [], []} = Table.put(table, :runtime, sub("a.b"))
    assert {^table, [], []} = Table.delete(table, :host, sub("a.b"))
    assert {^table, [], []} = Table.delete(table, :runtime, sub("c.d"))
  end

  test "entries differ by attribute and once" do
    {table, _, _} = Table.replace(Table.new(), :host, [sub("a.b"), sub("a.b", attribute: "x"), sub("a.b", once: true)])

    assert Table.entries(table) == [sub("a.b"), sub("a.b", once: true), sub("a.b", attribute: "x")]
  end

  test "replace reports only what entered or left the table" do
    {table, added, []} = Table.replace(Table.new(), :host, [sub("a.b"), sub("c.d")])
    assert added == [sub("a.b"), sub("c.d")]

    {table, _, _} = Table.put(table, {:wizard, 1}, sub("e.f"))

    # c.d leaves, e.f gains an owner, g.h enters.
    {table, added, removed} = Table.replace(table, :host, [sub("a.b"), sub("e.f"), sub("g.h")])
    assert added == [sub("g.h")]
    assert removed == [sub("c.d")]

    # The wizard still owns e.f after the host lets go of it.
    assert {_table, [], []} = Table.replace(table, :host, [sub("a.b"), sub("g.h")])
  end

  test "a wizard link moving from A to B and back re-adds A" do
    {table, [_], []} = Table.replace(Table.new(), {:wizard, 7}, [sub("a.a")])
    {table, [b], [a]} = Table.replace(table, {:wizard, 7}, [sub("b.b")])
    assert {a, b} == {sub("a.a"), sub("b.b")}
    assert {_table, [^a], [^b]} = Table.replace(table, {:wizard, 7}, [sub("a.a")])
  end

  test "drop_owners removes the matching owners only" do
    {table, _, _} = Table.replace(Table.new(), :host, [sub("a.b")])
    {table, _, _} = Table.put(table, {:wizard, 1}, sub("a.b"))
    {table, _, _} = Table.put(table, {:wizard, 2}, sub("c.d"))

    {table, [], removed} = Table.drop_owners(table, &match?({:wizard, _}, &1))
    assert removed == [sub("c.d")]
    assert Table.entries(table) == [sub("a.b")]
  end
end
