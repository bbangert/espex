defmodule Espex.ServerTest do
  use ExUnit.Case, async: true

  alias Espex.{DeviceConfig, Server}

  defp start_server(_context) do
    name = :"espex_server_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({Server, name: name, device_config: %DeviceConfig{}})
    %{server: name, server_pid: pid}
  end

  setup :start_server

  describe "claim_ble_owner/3" do
    test "succeeds for an unowned address", %{server: server} do
      assert Server.claim_ble_owner(server, 0x1122, self()) == :ok
      assert Server.ble_owner(server, 0x1122) == self()
    end

    test "is idempotent for the same pid", %{server: server} do
      assert Server.claim_ble_owner(server, 0x1122, self()) == :ok
      assert Server.claim_ble_owner(server, 0x1122, self()) == :ok
    end

    test "returns {:busy, other_pid} when another connection holds it", %{server: server} do
      other = spawn_link(fn -> Process.sleep(:infinity) end)
      assert Server.claim_ble_owner(server, 0x1122, other) == :ok
      assert Server.claim_ble_owner(server, 0x1122, self()) == {:busy, other}
    end
  end

  describe "release_ble_owner/3" do
    test "drops the address when pid matches", %{server: server} do
      :ok = Server.claim_ble_owner(server, 0x1122, self())
      assert Server.release_ble_owner(server, 0x1122, self()) == :ok
      assert Server.ble_owner(server, 0x1122) == nil
    end

    test "is a no-op when pid is not the owner", %{server: server} do
      other = spawn_link(fn -> Process.sleep(:infinity) end)
      :ok = Server.claim_ble_owner(server, 0x1122, other)

      assert Server.release_ble_owner(server, 0x1122, self()) == :ok
      assert Server.ble_owner(server, 0x1122) == other
    end

    test "is idempotent on an unowned address", %{server: server} do
      assert Server.release_ble_owner(server, 0xCAFE, self()) == :ok
    end
  end

  describe "release_all_ble_owners/2" do
    test "returns the list of released addresses and clears them", %{server: server} do
      :ok = Server.claim_ble_owner(server, 1, self())
      :ok = Server.claim_ble_owner(server, 2, self())
      other = spawn_link(fn -> Process.sleep(:infinity) end)
      :ok = Server.claim_ble_owner(server, 3, other)

      released = Server.release_all_ble_owners(server, self())
      assert Enum.sort(released) == [1, 2]

      assert Server.ble_owner(server, 1) == nil
      assert Server.ble_owner(server, 2) == nil
      assert Server.ble_owner(server, 3) == other
    end
  end

  describe "update_device_config/2" do
    @psk :crypto.hash(:sha256, "server-test-psk")

    test "keyword form merges: unspecified keys (the PSK) keep their value", %{server: server} do
      :ok = Server.update_psk(server, @psk)

      assert Server.update_device_config(server, name: "renamed", friendly_name: "Renamed") == :ok

      config = Server.device_config(server)
      assert config.name == "renamed"
      assert config.friendly_name == "Renamed"
      assert config.psk == @psk
    end

    test "struct form replaces wholesale", %{server: server} do
      :ok = Server.update_psk(server, @psk)
      replacement = %DeviceConfig{name: "fresh"}

      assert Server.update_device_config(server, replacement) == :ok
      assert Server.device_config(server) == replacement
      assert Server.device_config(server).psk == nil
    end

    test "struct form normalises a base64 PSK and rejects a bad one", %{server: server} do
      assert Server.update_device_config(server, %DeviceConfig{psk: Base.encode64(@psk)}) == :ok
      assert Server.device_config(server).psk == @psk

      before = Server.device_config(server)
      assert Server.update_device_config(server, %DeviceConfig{psk: "short"}) == {:error, :invalid_psk_length}
      assert Server.device_config(server) == before
    end

    test "invalid :psk in keyword form is rejected and leaves the config untouched", %{server: server} do
      before = Server.device_config(server)

      assert Server.update_device_config(server, name: "renamed", psk: "too-short") ==
               {:error, :invalid_psk_length}

      assert Server.device_config(server) == before
    end

    test "unknown key is rejected and leaves the config untouched", %{server: server} do
      before = Server.device_config(server)

      assert Server.update_device_config(server, name: "renamed", bogus: 1) == {:error, {:unknown_key, :bogus}}
      assert Server.device_config(server) == before
    end
  end

  describe "update_adapters/2" do
    test "merges known keys and keeps the rest", %{server: server} do
      assert Server.update_adapters(server, entity_provider: Espex.Test.FakeEntityProvider) == :ok
      assert Server.update_adapters(server, %{zwave_proxy: Espex.Test.FakeZWaveProxy}) == :ok

      adapters = Server.adapters(server)
      assert adapters.entity_provider == Espex.Test.FakeEntityProvider
      assert adapters.zwave_proxy == Espex.Test.FakeZWaveProxy
      assert adapters.serial_proxy == nil
    end

    test "nil disables a feature", %{server: server} do
      :ok = Server.update_adapters(server, entity_provider: Espex.Test.FakeEntityProvider)
      :ok = Server.update_adapters(server, entity_provider: nil)
      assert Server.adapters(server).entity_provider == nil
    end

    test "an unknown key or non-module value is rejected and nothing is applied", %{server: server} do
      before = Server.adapters(server)

      assert Server.update_adapters(server, entity_provider: Espex.Test.FakeEntityProvider, bogus: Foo) ==
               {:error, {:unknown_adapter, :bogus}}

      assert Server.update_adapters(server, zwave_proxy: "not a module") ==
               {:error, {:invalid_adapter, :zwave_proxy, "not a module"}}

      assert Server.adapters(server) == before
    end
  end

  describe "DOWN monitor sweep" do
    test "an owner's death releases its addresses without an explicit release call", %{server: server} do
      {:ok, owner} = Task.start(fn -> Process.sleep(:infinity) end)

      :ok = Server.claim_ble_owner(server, 0x1122, owner)
      :ok = Server.claim_ble_owner(server, 0x3344, owner)
      assert Server.ble_owner(server, 0x1122) == owner

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 1_000

      # Poll for the Server's `:DOWN` handler to drop ownership.
      # Observing our own `:DOWN` doesn't guarantee the Server's
      # handler has run yet — different scheduler, different mailbox.
      wait_until(fn -> Server.ble_owner(server, 0x1122) == nil end)
      wait_until(fn -> Server.ble_owner(server, 0x3344) == nil end)
    end
  end

  defp wait_until(check, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_until(check, deadline)
  end

  defp do_wait_until(check, deadline) do
    if check.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(5)
        do_wait_until(check, deadline)
      end
    end
  end
end
