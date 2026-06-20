defmodule Espex.ClientInfo do
  @moduledoc """
  A snapshot of one currently-connected ESPHome native-API client.

  Returned by `Espex.connected_clients/1`. Each struct describes a live
  TCP connection to the server:

    * `:id` — the connection handler pid; unique and stable for the
      lifetime of the connection, suitable as a UI row key.
    * `:peer` — the remote `"ip:port"` string.
    * `:client_info` — the `client_info` the client sent in its
      `HelloRequest` (e.g. `"Home Assistant 2026.1.0"`), or `nil` before
      the client has completed its hello.
    * `:api_version` — `{major, minor}` from the client's hello, or `nil`
      before hello.
    * `:encrypted?` — whether the connection negotiated the Noise
      encrypted transport.
    * `:connected_at` — epoch seconds when the TCP connection was
      accepted.
    * `:last_activity_at` — epoch seconds of the most recent inbound
      frame; advances as the client sends data and is the basis for an
      idle-time display.
  """

  alias Espex.ConnectionState

  @type t :: %__MODULE__{
          id: pid(),
          peer: String.t(),
          client_info: String.t() | nil,
          api_version: {non_neg_integer(), non_neg_integer()} | nil,
          encrypted?: boolean(),
          connected_at: integer() | nil,
          last_activity_at: integer() | nil
        }

  @enforce_keys [:id, :peer]
  defstruct [
    :id,
    :peer,
    :client_info,
    :api_version,
    :connected_at,
    :last_activity_at,
    encrypted?: false
  ]

  @doc """
  Build a `ClientInfo` snapshot for `pid` from its `ConnectionState`.

  Stored as the connection's Registry value so `Espex.connected_clients/1`
  is a plain Registry read.
  """
  @spec new(pid(), ConnectionState.t()) :: t()
  def new(pid, %ConnectionState{} = state) when is_pid(pid) do
    %__MODULE__{
      id: pid,
      peer: state.peer,
      client_info: state.client_info,
      api_version: state.api_version,
      encrypted?: match?({:active, _, _}, state.encryption),
      connected_at: state.connected_at,
      last_activity_at: state.last_activity_at
    }
  end
end
