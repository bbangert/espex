defmodule Espex.Mdns do
  @moduledoc """
  Behaviour for mDNS advertising adapters.

  Implement this to publish the running ESPHome device as a
  `_esphomelib._tcp` service over mDNS — that's what Home Assistant and
  other ESPHome clients use to auto-discover devices on the LAN without
  the user typing an IP.

  The `service` map matches `Espex.DeviceConfig.to_mdns_service/1`:
  `id`, `instance_name`, `protocol`, `transport`, `port`, `txt_payload`.

  `Espex.Mdns.Advertiser` (started as the last child of
  `Espex.Supervisor` when the `:mdns` option is set) invokes
  `c:advertise/1` once the TCP listener is bound and `c:withdraw/1`
  when the supervisor terminates.

  For the common Nerves case, `Espex.Mdns.MdnsLite` is a shipped
  implementation over the `:mdns_lite` library that consumers can wire
  directly without writing their own adapter — see its moduledoc for
  the one-line setup.
  """

  @doc """
  Register the service with the underlying mDNS responder.

  Called once, from `Espex.Mdns.Advertiser`'s `handle_continue/2`, after
  the TCP listener has bound and the ephemeral port (if any) has been
  resolved.
  """
  @callback advertise(service :: map()) :: :ok | {:error, term()}

  @doc """
  Deregister the previously advertised service. Called from
  `Espex.Mdns.Advertiser`'s `terminate/2`. Idempotent — may be invoked
  on an adapter that never successfully advertised (e.g. if `advertise/1`
  returned `{:error, _}`).
  """
  @callback withdraw(service_id :: term()) :: :ok
end
