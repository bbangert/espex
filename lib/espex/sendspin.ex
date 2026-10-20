defmodule Espex.Sendspin do
  @moduledoc since: "0.12.0"
  @moduledoc """
  Behaviour for Sendspin adapters (API 1.18).

  Sendspin is a protocol for synchronized audio playback. A device that
  runs a Sendspin client pairs with a Sendspin server using a pairing
  token. Home Assistant reads that token from the device over the native
  API and hands it to the server, so the user never types it.

  Implement this module when the host runs a Sendspin client. espex
  reports the client in `DeviceCapabilitiesResponse.sendspin` and
  answers `SendspinPairingTokenRequest` from your callbacks. Without a
  `:sendspin` adapter, espex reports no Sendspin capability and does not
  answer the token request, as ESPHome firmware built without Sendspin.

  ## Callbacks

  | Callback | Purpose |
  |----------|---------|
  | `c:client_id/0` | The client's id, `nil` before it has started |
  | `c:pairing_token/0` | The pairing token, or why there is none |
  | `c:feature_flags/0` | Optional. Supported features, default `pairing_token_feature/0` |

  ## Values change at runtime

  The client id and token do not exist until the Sendspin client has
  started once. espex calls the callbacks on every request instead of
  capturing them when a connection is accepted, so return the current
  values each time. Keep the callbacks fast: they run in the connection
  process.

  ## Pairing token

  `c:pairing_token/0` returns one of these, sent as
  `SendspinPairingTokenResponse.status`:

  | Return | Status | Meaning |
  |--------|--------|---------|
  | `{:ok, token}` | `OK` | The token, sent to the client |
  | `:not_ready` | `NOT_READY` | The client has not started yet; ask again later |
  | `:disabled` | `DISABLED` | Sendspin is off and has not started since boot |
  | `:failed` | `FAILED` | The client failed to start and will not until restart |

  If the callback raises or returns anything else, espex logs it and
  answers `FAILED`.

  ## Encryption is required

  The token is a long-lived secret. espex sends it only on a connection
  encrypted with the Noise protocol. On a plaintext connection, espex
  answers `ENCRYPTION_REQUIRED` without calling `c:pairing_token/0`. A
  key provisioned at runtime applies to later connections only, so a
  client must reconnect after provisioning before it can read the token.

  espex never logs the token. Your adapter must not log it either.

  ## Example

      defmodule MyApp.SendspinAdapter do
        @behaviour Espex.Sendspin

        @impl true
        def client_id, do: MyApp.Sendspin.client_id()

        @impl true
        def pairing_token do
          case MyApp.Sendspin.status() do
            :running -> {:ok, MyApp.Sendspin.pairing_token()}
            :starting -> :not_ready
            :off -> :disabled
            :crashed -> :failed
          end
        end
      end

  ## Wiring

      Espex.start_link(
        device_config: [name: "speaker", psk: psk],
        sendspin: MyApp.SendspinAdapter
      )
  """

  import Bitwise

  @typedoc "What `c:pairing_token/0` returns; see the moduledoc table."
  @type pairing_token_result :: {:ok, String.t()} | :not_ready | :disabled | :failed

  @doc """
  The Sendspin client's id: the base64url encoding of its static public
  key, 43 characters. Return `nil` or `""` before the client has started.
  """
  @callback client_id() :: String.t() | nil

  @doc """
  The pairing token, or why there is none. Called only on an encrypted
  connection. Never log the token.
  """
  @callback pairing_token() :: pairing_token_result()

  @doc """
  Bitmask of the Sendspin features the client supports. Optional; the
  default is `pairing_token_feature/0`, the only feature defined.
  """
  @callback feature_flags() :: non_neg_integer()

  @optional_callbacks feature_flags: 0

  @doc since: "0.12.0"
  @doc """
  The `PAIRING_TOKEN` feature bit (`1 <<< 0`): the device answers
  `SendspinPairingTokenRequest`. Clients send the request only when this
  bit is set.
  """
  @spec pairing_token_feature() :: non_neg_integer()
  def pairing_token_feature, do: 1 <<< 0
end
