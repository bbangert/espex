defmodule Espex.ZWaveProxy do
  @moduledoc """
  Behaviour for Z-Wave proxy adapters.

  Implement this to proxy a Z-Wave Serial API controller over the ESPHome
  Native API. Subscribers receive:

      {:espex_zwave_frame, binary}                    # raw Z-Wave Serial API frame
      {:espex_zwave_home_id_changed, <<_::32>>}       # new home ID (4-byte binary)

  `home_id/0` returns the 32-bit home ID as an integer. Espex advertises
  it inside `DeviceInfoResponse.zwave_home_id`. Return `0` when no
  controller is present.

  `feature_flags/0` returns the `zwave_proxy_feature_flags` bitfield;
  bit 0 (`0x01`) signals the feature is available.
  """

  @doc """
  Is the Z-Wave controller currently reachable?
  """
  @callback available?() :: boolean()

  @doc """
  Current Z-Wave home ID as a 32-bit integer (`0` if none).
  """
  @callback home_id() :: non_neg_integer()

  @doc """
  Feature flags reported to ESPHome clients. See
  `DeviceInfoResponse.zwave_proxy_feature_flags`.
  """
  @callback feature_flags() :: non_neg_integer()

  @doc """
  Subscribe the given pid to Z-Wave frames.

  Returns the current home ID as a 4-byte binary so the subscriber can
  decide whether to emit an initial change event.
  """
  @callback subscribe(subscriber :: pid()) ::
              {:ok, home_id_bytes :: <<_::32>>} | {:error, term()}

  @doc """
  Unsubscribe a previously subscribed pid. Idempotent.
  """
  @callback unsubscribe(subscriber :: pid()) :: :ok

  @doc """
  Send a raw Z-Wave Serial API frame to the controller.
  """
  @callback send_frame(data :: binary()) :: :ok | {:error, term()}
end
