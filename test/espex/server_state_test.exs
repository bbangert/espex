defmodule Espex.ServerStateTest do
  use ExUnit.Case, async: true

  alias Espex.{DeviceConfig, ServerState}

  defp base_state(overrides \\ []) do
    defaults = [device_config: %DeviceConfig{}]
    ServerState.new(Keyword.merge(defaults, overrides))
  end

  test "new/1 requires :device_config" do
    assert_raise ArgumentError, fn -> ServerState.new([]) end
  end

  test "new/1 defaults every adapter to nil" do
    state = base_state()

    assert state.adapters == %{
             serial_proxy: nil,
             zwave_proxy: nil,
             infrared_proxy: nil,
             bluetooth_scanner: nil,
             bluetooth_proxy: nil,
             entity_provider: nil,
             psk_store: nil,
             connection_listener: nil
           }
  end

  test "put_adapters/2 merges partial updates" do
    state =
      base_state()
      |> ServerState.put_adapters(%{serial_proxy: MyApp.Serial})
      |> ServerState.put_adapters(%{zwave_proxy: MyApp.ZWave})

    assert state.adapters.serial_proxy == MyApp.Serial
    assert state.adapters.zwave_proxy == MyApp.ZWave
    assert state.adapters.infrared_proxy == nil
  end

  test "adapter/2 looks up configured adapter" do
    state = base_state() |> ServerState.put_adapters(%{serial_proxy: MyApp.Serial})
    assert ServerState.adapter(state, :serial_proxy) == MyApp.Serial
    assert ServerState.adapter(state, :zwave_proxy) == nil
  end

  test "put_device_config/2 replaces the config" do
    new_config = %DeviceConfig{name: "renamed"}
    state = base_state() |> ServerState.put_device_config(new_config)
    assert state.device_config == new_config
  end

  describe "ble_owners" do
    test "put_ble_owner/3 records the owner; ble_owner/2 reads it" do
      pid = self()
      state = base_state() |> ServerState.put_ble_owner(0xAABB, pid)

      assert ServerState.ble_owner(state, 0xAABB) == pid
      assert ServerState.ble_owner(state, 0xCCDD) == nil
    end

    test "drop_ble_owner/3 only drops when pid matches; reports whether it dropped" do
      pid_a = self()
      pid_b = spawn(fn -> :ok end)
      state = base_state() |> ServerState.put_ble_owner(0xAABB, pid_a)

      {state, false} = ServerState.drop_ble_owner(state, 0xAABB, pid_b)
      assert ServerState.ble_owner(state, 0xAABB) == pid_a

      {state, true} = ServerState.drop_ble_owner(state, 0xAABB, pid_a)
      assert ServerState.ble_owner(state, 0xAABB) == nil
    end

    test "drop_ble_owner/3 for an unowned address is a no-op" do
      state = base_state()
      {^state, false} = ServerState.drop_ble_owner(state, 0xCAFE, self())
    end

    test "drop_all_ble_owners/2 sweeps every address for the pid, returns them, keeps the monitor" do
      pid_a = self()
      pid_b = spawn(fn -> :ok end)
      ref_a = make_ref()

      state =
        base_state()
        |> ServerState.put_ble_owner(1, pid_a)
        |> ServerState.put_ble_owner(2, pid_a)
        |> ServerState.put_ble_owner(3, pid_b)
        |> ServerState.put_owner_monitor(pid_a, ref_a)

      {state, addresses} = ServerState.drop_all_ble_owners(state, pid_a)
      assert Enum.sort(addresses) == [1, 2]
      assert ServerState.ble_owner(state, 1) == nil
      assert ServerState.ble_owner(state, 2) == nil
      assert ServerState.ble_owner(state, 3) == pid_b
      # The monitor is shared with serial ownership; the Server drops it.
      assert ServerState.owner_monitor(state, pid_a) == ref_a
    end
  end

  describe "serial_owners" do
    test "put_serial_owner/3 records the owner; serial_owner/2 reads it" do
      pid = self()
      state = base_state() |> ServerState.put_serial_owner(0, pid)

      assert ServerState.serial_owner(state, 0) == pid
      assert ServerState.serial_owner(state, 1) == nil
    end

    test "drop_serial_owner/3 only drops when pid matches; reports whether it dropped" do
      pid_a = self()
      pid_b = spawn(fn -> :ok end)
      state = base_state() |> ServerState.put_serial_owner(0, pid_a)

      {state, false} = ServerState.drop_serial_owner(state, 0, pid_b)
      assert ServerState.serial_owner(state, 0) == pid_a

      {state, true} = ServerState.drop_serial_owner(state, 0, pid_a)
      assert ServerState.serial_owner(state, 0) == nil

      {^state, false} = ServerState.drop_serial_owner(state, 0, pid_a)
    end

    test "drop_all_serial_owners/2 sweeps every instance for the pid and returns them" do
      pid_a = self()
      pid_b = spawn(fn -> :ok end)

      state =
        base_state()
        |> ServerState.put_serial_owner(0, pid_a)
        |> ServerState.put_serial_owner(1, pid_a)
        |> ServerState.put_serial_owner(2, pid_b)

      {state, instances} = ServerState.drop_all_serial_owners(state, pid_a)
      assert Enum.sort(instances) == [0, 1]
      assert ServerState.serial_owner(state, 0) == nil
      assert ServerState.serial_owner(state, 2) == pid_b
    end

    test "pid_owns_any?/2 considers both kinds" do
      pid = self()
      refute ServerState.pid_owns_any?(base_state(), pid)
      assert base_state() |> ServerState.put_ble_owner(1, pid) |> ServerState.pid_owns_any?(pid)
      assert base_state() |> ServerState.put_serial_owner(1, pid) |> ServerState.pid_owns_any?(pid)
    end
  end

  describe "owner_monitors" do
    test "put_owner_monitor/3 keeps the first ref for a pid" do
      pid = self()
      ref1 = make_ref()
      ref2 = make_ref()

      state =
        base_state()
        |> ServerState.put_owner_monitor(pid, ref1)
        |> ServerState.put_owner_monitor(pid, ref2)

      assert ServerState.owner_monitor(state, pid) == ref1
    end

    test "pop_owner_monitor/2 returns and removes the ref" do
      pid = self()
      ref = make_ref()
      state = base_state() |> ServerState.put_owner_monitor(pid, ref)

      {^ref, state} = ServerState.pop_owner_monitor(state, pid)
      assert ServerState.owner_monitor(state, pid) == nil

      {nil, _} = ServerState.pop_owner_monitor(state, pid)
    end
  end
end
