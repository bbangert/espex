defmodule Espex.HomeAssistantStates.Table do
  @moduledoc false

  # The server-wide Home Assistant state subscription table: each entry
  # (a %Subscription{}) maps to the set of owners that asked for it.
  # Owners are :host (the adapter's subscriptions/0), :runtime
  # (Espex.subscribe_home_assistant_state/2) and {:wizard, key} (a linked
  # wizard input).
  #
  # Every change returns {table, added, removed}, listing only entries
  # that entered or left the table. An entry gaining a second owner is
  # not "added", and one losing an owner while another remains is not
  # "removed": that one rule dedupes host and wizard entries and keeps
  # resends to entries the client has not seen.

  alias Espex.HomeAssistantStates.Subscription

  @type owner :: :host | :runtime | {:wizard, non_neg_integer()}
  @type t :: %{Subscription.t() => MapSet.t(owner())}
  @type change :: {t(), added :: [Subscription.t()], removed :: [Subscription.t()]}

  @spec new() :: t()
  def new, do: %{}

  @doc "The entries, sorted."
  @spec entries(t()) :: [Subscription.t()]
  def entries(table), do: table |> Map.keys() |> sort()

  @spec sort([Subscription.t()]) :: [Subscription.t()]
  def sort(entries), do: Enum.sort_by(entries, &{&1.entity_id, &1.attribute || "", &1.once})

  @spec put(t(), owner(), Subscription.t()) :: change()
  def put(table, owner, entry) do
    {table, added?} = add_owner(table, owner, entry)
    {table, if(added?, do: [entry], else: []), []}
  end

  @spec delete(t(), owner(), Subscription.t()) :: change()
  def delete(table, owner, entry) do
    {table, removed?} = remove_owner(table, owner, entry)
    {table, [], if(removed?, do: [entry], else: [])}
  end

  @doc "Make `owner` own exactly `entries`."
  @spec replace(t(), owner(), [Subscription.t()]) :: change()
  def replace(table, owner, entries) do
    wanted = MapSet.new(entries)
    owned = table |> owned_by(&(&1 == owner)) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    {table, removed} =
      owned
      |> MapSet.difference(wanted)
      |> Enum.reduce({table, []}, fn entry, {table, removed} ->
        {table, removed?} = remove_owner(table, owner, entry)
        {table, if(removed?, do: [entry | removed], else: removed)}
      end)

    {table, added} =
      wanted
      |> MapSet.difference(owned)
      |> Enum.reduce({table, []}, fn entry, {table, added} ->
        {table, added?} = add_owner(table, owner, entry)
        {table, if(added?, do: [entry | added], else: added)}
      end)

    {table, sort(added), sort(removed)}
  end

  @doc "Drop every owner matching `owner?` from every entry."
  @spec drop_owners(t(), (owner() -> boolean())) :: change()
  def drop_owners(table, owner?) do
    {table, removed} =
      table
      |> owned_by(owner?)
      |> Enum.reduce({table, []}, fn {entry, owner}, {table, removed} ->
        {table, removed?} = remove_owner(table, owner, entry)
        {table, if(removed?, do: [entry | removed], else: removed)}
      end)

    {table, [], sort(removed)}
  end

  defp owned_by(table, owner?) do
    for {entry, owners} <- table, owner <- owners, owner?.(owner), do: {entry, owner}
  end

  defp add_owner(table, owner, entry) do
    case table do
      %{^entry => owners} -> {Map.put(table, entry, MapSet.put(owners, owner)), false}
      _ -> {Map.put(table, entry, MapSet.new([owner])), true}
    end
  end

  defp remove_owner(table, owner, entry) do
    case table do
      %{^entry => owners} ->
        owners = MapSet.delete(owners, owner)

        if MapSet.size(owners) == 0,
          do: {Map.delete(table, entry), true},
          else: {Map.put(table, entry, owners), false}

      _ ->
        {table, false}
    end
  end
end
