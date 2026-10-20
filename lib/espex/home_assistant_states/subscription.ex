defmodule Espex.HomeAssistantStates.Subscription do
  @moduledoc since: "0.12.0"
  @moduledoc """
  One Home Assistant entity (or one of its attributes) the device asks
  Home Assistant to send the state of.

    * `entity_id` — the Home Assistant entity, such as `"sun.sun"`:
      1 to 255 bytes, containing a `.`.
    * `attribute` — an attribute of that entity, such as `"elevation"`,
      up to 255 bytes, or `nil` for the entity's state.
    * `once` — `true` asks Home Assistant for the current value only,
      instead of every change. It is a hint to the client: espex passes
      every matching state to `c:Espex.HomeAssistantStates.handle_state/3`
      either way.

  Build one with `new/1` or `new!/1`, which check the fields:

      iex> Espex.HomeAssistantStates.Subscription.new!(entity_id: "sun.sun", attribute: "elevation")
      %Espex.HomeAssistantStates.Subscription{entity_id: "sun.sun", attribute: "elevation", once: false}

  A wizard input link (see `Espex.Wizard.Input`) is a subscription with
  `entity_id: nil`; the input's value fills it in.
  """

  @max_bytes 255

  @type t :: %__MODULE__{
          entity_id: String.t() | nil,
          attribute: String.t() | nil,
          once: boolean()
        }

  defstruct entity_id: nil, attribute: nil, once: false

  @doc """
  Build a subscription from a keyword list, a map, or a subscription
  built by hand, checking each field.

  An empty `attribute` is the same as `nil`. Returns
  `{:error, :invalid_subscription}` for an unknown key or a bad value.
  """
  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, :invalid_subscription}
  def new(fields) do
    case build(fields) do
      {:ok, subscription} -> {:ok, subscription}
      {:error, _message} -> {:error, :invalid_subscription}
    end
  end

  @doc """
  Like `new/1`, but raises `ArgumentError` naming the bad field.
  """
  @spec new!(keyword() | map() | t()) :: t()
  def new!(fields) do
    case build(fields) do
      {:ok, subscription} -> subscription
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc false
  # Shared with Espex.Wizard.Document: a link carries no entity_id.
  @spec build(term(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(fields, opts \\ []) do
    link? = Keyword.get(opts, :link, false)

    with {:ok, fields} <- to_map(fields),
         :ok <- check_keys(fields),
         {:ok, entity_id} <- check_entity_id(Map.get(fields, :entity_id), link?),
         {:ok, attribute} <- check_attribute(Map.get(fields, :attribute)),
         {:ok, once} <- check_once(Map.get(fields, :once, false)) do
      {:ok, %__MODULE__{entity_id: entity_id, attribute: attribute, once: once}}
    end
  end

  @doc false
  # A Home Assistant entity id as both the subscription table and the
  # wizard accept it.
  @spec valid_entity_id?(term()) :: boolean()
  def valid_entity_id?(entity_id) do
    is_binary(entity_id) and byte_size(entity_id) in 1..@max_bytes and String.valid?(entity_id) and
      String.contains?(entity_id, ".")
  end

  defp to_map(%__MODULE__{} = subscription), do: {:ok, Map.from_struct(subscription)}
  defp to_map(fields) when is_map(fields) and not is_struct(fields), do: {:ok, fields}

  defp to_map(fields) when is_list(fields) do
    if Keyword.keyword?(fields), do: {:ok, Map.new(fields)}, else: not_fields(fields)
  end

  defp to_map(fields), do: not_fields(fields)

  defp not_fields(fields), do: {:error, "subscription fields must be a keyword list or map, got: #{inspect(fields)}"}

  defp check_keys(fields) do
    case Map.keys(fields) -- [:entity_id, :attribute, :once] do
      [] -> :ok
      [key | _] -> {:error, "unknown subscription key #{inspect(key)}"}
    end
  end

  defp check_entity_id(nil, true = _link?), do: {:ok, nil}

  defp check_entity_id(entity_id, true = _link?),
    do: {:error, "a wizard input link takes its entity_id from the input, got: #{inspect(entity_id)}"}

  defp check_entity_id(entity_id, false) do
    if valid_entity_id?(entity_id),
      do: {:ok, entity_id},
      else: {:error, "entity_id must be 1-#{@max_bytes} bytes containing a \".\", got: #{inspect(entity_id)}"}
  end

  defp check_attribute(nil), do: {:ok, nil}
  defp check_attribute(""), do: {:ok, nil}

  defp check_attribute(attribute) when is_binary(attribute) and byte_size(attribute) <= @max_bytes do
    if String.valid?(attribute), do: {:ok, attribute}, else: invalid_attribute(attribute)
  end

  defp check_attribute(attribute), do: invalid_attribute(attribute)

  defp invalid_attribute(attribute),
    do: {:error, "attribute must be nil or a string of up to #{@max_bytes} bytes, got: #{inspect(attribute)}"}

  defp check_once(once) when is_boolean(once), do: {:ok, once}
  defp check_once(once), do: {:error, "once must be a boolean, got: #{inspect(once)}"}
end
