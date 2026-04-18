defmodule Espex.MdnsIntegrationTest do
  use ExUnit.Case, async: false

  alias Espex.Test.FakeMdnsAdapter

  setup context do
    # Fresh agent per test. We start it ourselves (not via `start_supervised`)
    # because the advertiser GenServer runs in the espex supervisor tree and
    # the test-owned agent needs to outlive it so `terminate/2` can log.
    {:ok, agent} = FakeMdnsAdapter.start_link()

    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    %{sup_name: sup_name, server_name: server_name}
  end

  defp start_supervisor(opts) do
    {:ok, sup} = Espex.start_link(opts)

    on_exit(fn ->
      if Process.alive?(sup) do
        try do
          Supervisor.stop(sup, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    sup
  end

  describe "no :mdns option" do
    test "no advertiser child is started", %{sup_name: sup, server_name: srv} do
      supervisor =
        start_supervisor(
          name: sup,
          server_name: srv,
          port: 0,
          device_config: [name: "no-mdns"]
        )

      advertiser =
        supervisor
        |> Supervisor.which_children()
        |> Enum.find(fn {id, _, _, _} -> id == Espex.Mdns.Advertiser end)

      assert advertiser == nil
    end
  end

  describe "fake adapter" do
    test "advertises with the bound ephemeral port and correct TXT records", %{sup_name: sup, server_name: srv} do
      start_supervisor(
        name: sup,
        server_name: srv,
        port: 0,
        device_config: [
          name: "mdns-demo",
          friendly_name: "Mdns Demo",
          mac_address: "11:22:33:44:55:66",
          project_name: "espex.demo",
          project_version: "0.0.1"
        ],
        mdns: Espex.Test.FakeMdnsAdapter
      )

      # Wait briefly for the advertiser's handle_continue to fire. A poll
      # beats a blind sleep — we stop as soon as the log has an entry.
      assert await_log(100) |> Enum.any?(&match?({:advertise, _}, &1))

      {:advertise, service} = Enum.find(FakeMdnsAdapter.log(), &match?({:advertise, _}, &1))

      {:ok, bound} = Espex.Supervisor.bound_port(sup)
      assert service.port == bound
      assert service.id == :esphomelib
      assert service.protocol == "esphomelib"
      assert service.transport == "tcp"
      assert "mac=11:22:33:44:55:66" in service.txt_payload
      assert "friendly_name=Mdns Demo" in service.txt_payload
      assert "project_name=espex.demo" in service.txt_payload
    end

    test "withdraws on clean supervisor shutdown", %{sup_name: sup, server_name: srv} do
      supervisor =
        start_supervisor(
          name: sup,
          server_name: srv,
          port: 0,
          device_config: [name: "withdraw-test"],
          mdns: Espex.Test.FakeMdnsAdapter
        )

      # Wait for advertise to land before we tear down.
      assert await_log(100) |> Enum.any?(&match?({:advertise, _}, &1))

      :ok = Supervisor.stop(supervisor, :normal, 2_000)

      log = FakeMdnsAdapter.log()
      assert {:withdraw, :esphomelib} in log
    end
  end

  describe "real MdnsLite adapter" do
    @tag :mdns_live
    test "supervisor starts and stops cleanly with the shipped MdnsLite adapter", %{sup_name: sup, server_name: srv} do
      # MdnsLite (v0.9.1) doesn't expose a getter for registered services,
      # so we settle for the structural check: the advertiser child is
      # alive, its adapter is our MdnsLite wrapper, and supervisor
      # shutdown completes without timing out (which would happen if the
      # adapter's withdraw hung or errored).
      supervisor =
        start_supervisor(
          name: sup,
          server_name: srv,
          port: 0,
          device_config: [
            name: "mdns-live-test",
            friendly_name: "Live Test",
            mac_address: "AA:BB:CC:DD:EE:FF"
          ],
          mdns: Espex.Mdns.MdnsLite
        )

      advertiser_pid =
        supervisor
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {Espex.Mdns.Advertiser, pid, _, _} when is_pid(pid) -> pid
          _ -> nil
        end)

      assert is_pid(advertiser_pid)
      assert Process.alive?(advertiser_pid)

      # Clean shutdown should complete well under the 2s timeout.
      assert :ok = Supervisor.stop(supervisor, :normal, 2_000)
    end
  end

  # Poll the fake adapter log, retrying every 5ms up to `iters` times.
  defp await_log(iters) when iters > 0 do
    log = FakeMdnsAdapter.log()

    if log == [] do
      Process.sleep(5)
      await_log(iters - 1)
    else
      log
    end
  end

  defp await_log(0), do: FakeMdnsAdapter.log()
end
