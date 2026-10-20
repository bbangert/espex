defmodule Espex.OutgoingTargetStore do
  @moduledoc since: "0.12.0"
  @moduledoc """
  Behaviour for persisting the address espex dials back to (API 1.18
  outgoing connection).

  With `:outgoing_connection` configured and no `host` in it, espex
  learns where to dial from the clients: a client whose `HelloRequest`
  sets `outgoing_connection_target` over an encrypted session (Home
  Assistant does this for the device's own config entry) becomes the
  target, and its IP address is remembered. When no target client is
  connected, espex dials that address at the configured port.

  Without a store the learned address lasts until the node restarts
  (espex logs a warning once), and after a restart espex cannot dial
  until a target client connects again. Configure an
  `:outgoing_target_store` adapter to keep it, and pass the saved
  address back as `outgoing_connection: [target: ...]` on boot.

  ## Callback

  `c:store_target/1` is called with the new IP address when a target
  client connects from an address other than the one remembered. Only
  the address is stored, not the port, as in ESPHome firmware. On
  `{:error, reason}` espex keeps using the address and calls again on
  the next target client's hello. It runs in espex's dialer process:
  return promptly.

  ## Example

      defmodule MyApp.FileTargetStore do
        @behaviour Espex.OutgoingTargetStore

        @path "/data/espex_target"

        @impl Espex.OutgoingTargetStore
        def store_target(ip), do: File.write(@path, :inet.ntoa(ip))

        @doc "Call on boot to seed the dialer from the saved address."
        def load_target do
          case File.read(@path) do
            {:ok, ip} -> ip
            {:error, _} -> nil
          end
        end
      end

  ## Wiring

      target = MyApp.FileTargetStore.load_target()

      Espex.start_link(
        device_config: [name: "my-device", psk: psk],
        outgoing_connection: if(target, do: [target: target], else: []),
        outgoing_target_store: MyApp.FileTargetStore
      )
  """

  @doc """
  Persist the IP address of the newest dial-back target client.
  """
  @callback store_target(:inet.ip_address()) :: :ok | {:error, term()}
end
