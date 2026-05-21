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

  describe "DOWN monitor sweep" do
    test "an owner's death releases its addresses without an explicit release call", %{server: server} do
      {:ok, owner} = Task.start(fn -> Process.sleep(:infinity) end)

      :ok = Server.claim_ble_owner(server, 0x1122, owner)
      :ok = Server.claim_ble_owner(server, 0x3344, owner)
      assert Server.ble_owner(server, 0x1122) == owner

      Process.exit(owner, :kill)

      # Give the Server's handle_info({:DOWN, ...}) a chance to fire.
      # ble_owner/2 is a GenServer.call so by the time it returns nil
      # any prior :DOWN has been processed.
      Process.sleep(20)

      assert Server.ble_owner(server, 0x1122) == nil
      assert Server.ble_owner(server, 0x3344) == nil
    end
  end
end
