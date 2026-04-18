# Interactive manual verification of mDNS auto-discovery.
#
# Run with:
#
#   mix run test/manual/mdns_demo.exs
#
# Starts an Espex server with the shipped Espex.Mdns.MdnsLite adapter
# and an empty EntityProvider. Home Assistant should discover the
# device automatically via its ESPHome integration's mDNS browser
# without the user typing in the IP/port.
#
# Expected flow:
#   1. This script starts, prints the device name and advertised port.
#   2. In HA: Settings → Devices & Services → "Discovered". A new
#      ESPHome device named "espex-mdns-demo" should appear within a
#      few seconds.
#   3. Click "Add Integration" — HA prefills the host/port from the
#      mDNS record.
#   4. Confirm in this terminal that you saw the discovered card.
#
# Uses port 6053 (the ESPHome default) because some ESPHome client
# implementations hard-code that port. Using an ephemeral port works
# too — HA reads the port out of the TXT record — but 6053 matches
# production deployments most closely.

Logger.configure(level: :info)

defmodule Espex.MdnsDemo do
  @moduledoc false

  @server_name :espex_mdns_demo_server
  @sup_name :espex_mdns_demo_supervisor

  def run do
    # mdns_lite is pulled in under :dev/:test. Its application is
    # already started via `mix run`, but confirm for clarity.
    {:ok, _} = Application.ensure_all_started(:mdns_lite)

    {:ok, sup_pid} =
      Espex.start_link(
        name: @sup_name,
        server_name: @server_name,
        port: 6053,
        device_config: [
          name: "espex-mdns-demo",
          friendly_name: "Espex mDNS Demo",
          project_name: "espex.mdns_demo",
          project_version: "0.1.0"
        ],
        mdns: Espex.Mdns.MdnsLite
      )

    {:ok, bound} = Espex.Supervisor.bound_port(sup_pid)
    ip = local_ipv4()

    IO.puts("""

    ╔════════════════════════════════════════════════════════════════════╗
                         Espex mDNS auto-discovery demo
    ╠════════════════════════════════════════════════════════════════════╣

      Device name:     espex-mdns-demo
      Friendly name:   Espex mDNS Demo
      IP / port:       #{ip}:#{bound}
      mDNS service:    _esphomelib._tcp

      In Home Assistant, open:

        Settings → Devices & Services → Discovered

      You should see "Espex mDNS Demo" (or "espex-mdns-demo") show up
      within a few seconds under the ESPHome integration. Click it to
      confirm HA prefills the host and port from mDNS — you should NOT
      need to type anything except the encryption key prompt (leave
      blank; this demo is plaintext).

      This terminal will wait for your confirmation.

    ╚════════════════════════════════════════════════════════════════════╝
    """)

    answer = IO.gets("Did Home Assistant auto-discover the device? (y/n) ")

    case answer && String.trim(answer) |> String.downcase() do
      "y" ->
        IO.puts("    ✓ mDNS auto-discovery verified")

      _ ->
        IO.puts("    ✗ mDNS auto-discovery NOT verified — check that:")
        IO.puts("       - your machine is on the same LAN as HA")
        IO.puts("       - multicast traffic isn't blocked by firewall/VPN")
        IO.puts("       - MdnsLite picked up the right network interface")
    end

    try do
      Supervisor.stop(sup_pid, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end

    System.halt(0)
  end

  defp local_ipv4 do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.find_value(fn {name, opts} ->
          if name != ~c"lo" do
            Enum.find_value(opts, fn
              {:addr, {a, b, c, d}} when a != 127 -> "#{a}.#{b}.#{c}.#{d}"
              _ -> nil
            end)
          end
        end) || "127.0.0.1"

      _ ->
        "127.0.0.1"
    end
  end
end

Espex.MdnsDemo.run()
