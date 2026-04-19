defmodule Espex.Mdns do
  @moduledoc """
  Behaviour for mDNS advertising adapters.

  Implement this module to publish the running ESPHome device as a
  `_esphomelib._tcp` service over mDNS — that's what Home Assistant and
  other ESPHome clients use to auto-discover devices on the LAN
  without the user typing an IP.

  Advertising is opt-in. Pass `mdns: MyModule` to `Espex.start_link/1`
  and espex will start a GenServer as the last child in the
  supervision tree that calls `c:advertise/1` once the TCP listener
  has bound (so ephemeral ports work) and calls `c:withdraw/1` on
  supervisor shutdown.

  For the common Nerves case, use the shipped `Espex.Mdns.MdnsLite`
  adapter — it wraps the [`mdns_lite`](https://hex.pm/packages/mdns_lite)
  library and needs no subclassing. Write your own adapter only when
  you're on a platform `:mdns_lite` doesn't cover.

  ## Callbacks

  | Callback | Purpose |
  |----------|---------|
  | `c:advertise/1` | Register the service with the mDNS responder |
  | `c:withdraw/1` | Deregister the service (idempotent) |

  ## The service map

  `c:advertise/1` receives a map produced by
  `Espex.DeviceConfig.to_mdns_service/1` with this shape:

      %{
        id: :esphomelib,
        instance_name: :unspecified,
        protocol: "esphomelib",
        transport: "tcp",
        port: 6053,
        txt_payload: [
          "mac=AA:BB:CC:DD:EE:FF",
          "version=2026.1.0",
          "friendly_name=My Device",
          "project_name=mycompany.widget",
          "project_version=1.0.0"
        ]
      }

  The `:id` you store from this map is what espex later hands back to
  `c:withdraw/1` for deregistration.

  ## Example: custom backend

      defmodule MyApp.MdnsAdapter do
        @behaviour Espex.Mdns

        @impl true
        def advertise(service) do
          case MyMdnsLib.publish(
                 type: "_\#{service.protocol}._\#{service.transport}",
                 port: service.port,
                 txt: service.txt_payload
               ) do
            {:ok, _handle} -> :ok
            {:error, _} = err -> err
          end
        end

        @impl true
        def withdraw(_service_id) do
          MyMdnsLib.withdraw_all()
          :ok
        end
      end

  ## Wiring

      Espex.start_link(
        device_config: [name: "my-device"],
        mdns: MyApp.MdnsAdapter
      )

  Or for the shipped `:mdns_lite`-based adapter:

      {:ok, _} = Application.ensure_all_started(:mdns_lite)

      Espex.start_link(
        device_config: [name: "my-device"],
        mdns: Espex.Mdns.MdnsLite
      )
  """

  @doc """
  Register the service with the underlying mDNS responder.

  Called once, from the advertiser's `handle_continue/2`, after the TCP
  listener has bound and the ephemeral port (if any) has been resolved.
  """
  @callback advertise(service :: map()) :: :ok | {:error, term()}

  @doc """
  Deregister the previously advertised service. Called from the
  advertiser's `terminate/2`. Idempotent — may be invoked on an
  adapter that never successfully advertised (e.g. if `advertise/1`
  returned `{:error, _}`).
  """
  @callback withdraw(service_id :: term()) :: :ok
end
