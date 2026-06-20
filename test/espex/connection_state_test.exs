defmodule Espex.ConnectionStateTest do
  use ExUnit.Case, async: true

  alias Espex.{ConnectionState, DeviceConfig, SerialProxy}

  defp base_state(overrides \\ []) do
    defaults = [device_config: %DeviceConfig{}, peer: "127.0.0.1:1234"]
    ConnectionState.new(Keyword.merge(defaults, overrides))
  end

  describe "new/1" do
    test "requires :device_config and :peer" do
      assert_raise ArgumentError, fn -> ConnectionState.new([]) end
    end

    test "starts with empty buffer, no ports, no subscriptions" do
      state = base_state()
      assert state.buffer == <<>>
      assert state.opened_ports == %{}
      assert state.serial_proxies == []
      assert state.infrared_entities == []
      assert state.entities == []
      refute state.zwave_subscribed
      refute state.infrared_subscribed
      refute state.bluetooth_scanner_subscribed
      refute state.bluetooth_connections_free_subscribed
      assert state.bluetooth_owned == MapSet.new()
      assert state.server_name == nil
    end

    test "entity lists are frozen at construction time (passed via new/1)" do
      ir = Espex.InfraredProxy.Entity.new(key: 1, object_id: "a", name: "A", capabilities: [:transmit])
      state = base_state(infrared_entities: [ir], entities: [%{tag: :custom}])
      assert state.infrared_entities == [ir]
      assert state.entities == [%{tag: :custom}]
    end

    test "adapter map has all features defaulting to nil" do
      state = base_state()

      assert state.adapters == %{
               serial_proxy: nil,
               zwave_proxy: nil,
               infrared_proxy: nil,
               bluetooth_scanner: nil,
               bluetooth_proxy: nil,
               entity_provider: nil,
               psk_store: nil
             }
    end

    test "server_name can be set via new/1" do
      state = base_state(server_name: MyApp.EspexServer)
      assert state.server_name == MyApp.EspexServer
    end
  end

  describe "buffer" do
    test "append_buffer concatenates" do
      state = base_state() |> ConnectionState.append_buffer(<<1, 2>>) |> ConnectionState.append_buffer(<<3>>)
      assert state.buffer == <<1, 2, 3>>
    end

    test "put_buffer replaces" do
      state = base_state() |> ConnectionState.append_buffer(<<1, 2, 3>>) |> ConnectionState.put_buffer(<<9>>)
      assert state.buffer == <<9>>
    end
  end

  describe "ports" do
    test "put_port then port_handle returns {:ok, handle}" do
      state = base_state() |> ConnectionState.put_port(5, :some_handle)
      assert ConnectionState.port_handle(state, 5) == {:ok, :some_handle}
    end

    test "port_handle returns :error for unknown instance" do
      assert ConnectionState.port_handle(base_state(), 42) == :error
    end

    test "drop_port returns the handle and removes it" do
      state = base_state() |> ConnectionState.put_port(1, :h1) |> ConnectionState.put_port(2, :h2)
      {state, handle} = ConnectionState.drop_port(state, 1)
      assert handle == :h1
      assert ConnectionState.port_handle(state, 1) == :error
      assert ConnectionState.port_handle(state, 2) == {:ok, :h2}
    end

    test "drop_port returns {state, nil} when instance wasn't open" do
      state = base_state()
      assert {^state, nil} = ConnectionState.drop_port(state, 99)
    end

    test "instance_for_handle reverse-lookups" do
      state = base_state() |> ConnectionState.put_port(7, :hX) |> ConnectionState.put_port(8, :hY)
      assert ConnectionState.instance_for_handle(state, :hX) == 7
      assert ConnectionState.instance_for_handle(state, :hY) == 8
      assert ConnectionState.instance_for_handle(state, :nope) == nil
    end
  end

  describe "find_serial_proxy/2" do
    test "returns the matching Info struct" do
      info = SerialProxy.Info.new(instance: 3, name: "zigbee", port_type: :ttl)
      state = base_state(serial_proxies: [info])
      assert ConnectionState.find_serial_proxy(state, 3) == info
      assert ConnectionState.find_serial_proxy(state, 4) == nil
    end
  end

  describe "pending subscriptions" do
    test "starts empty" do
      assert base_state().pending_subscriptions == MapSet.new()
    end

    test "put / pending? / drop round-trip" do
      state = base_state() |> ConnectionState.put_pending_subscription(2)
      assert ConnectionState.pending_subscription?(state, 2)
      refute ConnectionState.pending_subscription?(state, 3)

      state = ConnectionState.drop_pending_subscription(state, 2)
      refute ConnectionState.pending_subscription?(state, 2)
    end

    test "put_pending_subscription is idempotent" do
      state =
        base_state()
        |> ConnectionState.put_pending_subscription(7)
        |> ConnectionState.put_pending_subscription(7)

      assert MapSet.size(state.pending_subscriptions) == 1
    end
  end

  describe "subscription flags" do
    test "put_zwave_subscribed / put_infrared_subscribed toggle" do
      state =
        base_state() |> ConnectionState.put_zwave_subscribed(true) |> ConnectionState.put_infrared_subscribed(true)

      assert state.zwave_subscribed
      assert state.infrared_subscribed
      state = state |> ConnectionState.put_zwave_subscribed(false)
      refute state.zwave_subscribed
      assert state.infrared_subscribed
    end

    test "put_bluetooth_scanner_subscribed toggles" do
      state = base_state() |> ConnectionState.put_bluetooth_scanner_subscribed(true)
      assert state.bluetooth_scanner_subscribed
      state = ConnectionState.put_bluetooth_scanner_subscribed(state, false)
      refute state.bluetooth_scanner_subscribed
    end

    test "put_bluetooth_connections_free_subscribed toggles" do
      state = base_state() |> ConnectionState.put_bluetooth_connections_free_subscribed(true)
      assert state.bluetooth_connections_free_subscribed
      state = ConnectionState.put_bluetooth_connections_free_subscribed(state, false)
      refute state.bluetooth_connections_free_subscribed
    end
  end

  describe "bluetooth_owned" do
    test "add / bluetooth_owns? / drop round-trip" do
      address_a = 0x0000_AABB_CCDD_EE01
      address_b = 0x0000_AABB_CCDD_EE02

      state = base_state() |> ConnectionState.add_bluetooth_owned(address_a)
      assert ConnectionState.bluetooth_owns?(state, address_a)
      refute ConnectionState.bluetooth_owns?(state, address_b)

      state = ConnectionState.drop_bluetooth_owned(state, address_a)
      refute ConnectionState.bluetooth_owns?(state, address_a)
    end

    test "add_bluetooth_owned is idempotent" do
      address = 0x0000_AABB_CCDD_EE01

      state =
        base_state()
        |> ConnectionState.add_bluetooth_owned(address)
        |> ConnectionState.add_bluetooth_owned(address)

      assert MapSet.size(state.bluetooth_owned) == 1
    end

    test "put_bluetooth_owned replaces the entire set" do
      replacement = MapSet.new([1, 2, 3])

      state =
        base_state()
        |> ConnectionState.add_bluetooth_owned(0xDEAD)
        |> ConnectionState.put_bluetooth_owned(replacement)

      assert state.bluetooth_owned == replacement
    end

    test "drop_bluetooth_owned for an unowned address is a no-op" do
      state = base_state() |> ConnectionState.drop_bluetooth_owned(0xCAFE)
      assert state.bluetooth_owned == MapSet.new()
    end
  end

  describe "adapter lookup" do
    test "adapter/2 returns nil when unconfigured, module when configured" do
      adapters = %{
        serial_proxy: MyApp.Serial,
        zwave_proxy: nil,
        infrared_proxy: nil,
        bluetooth_scanner: MyApp.BLEScanner,
        bluetooth_proxy: nil,
        entity_provider: nil
      }

      state = base_state(adapters: adapters)

      assert ConnectionState.adapter(state, :serial_proxy) == MyApp.Serial
      assert ConnectionState.adapter(state, :zwave_proxy) == nil
      assert ConnectionState.adapter(state, :bluetooth_scanner) == MyApp.BLEScanner
      assert ConnectionState.adapter(state, :bluetooth_proxy) == nil
      assert ConnectionState.adapter?(state, :serial_proxy)
      refute ConnectionState.adapter?(state, :zwave_proxy)
      assert ConnectionState.adapter?(state, :bluetooth_scanner)
      refute ConnectionState.adapter?(state, :bluetooth_proxy)
    end
  end

  describe "clock_fun" do
    test "defaults to wall-clock seconds" do
      state = base_state()
      now = state.clock_fun.()
      assert is_integer(now)
      assert now > 0
    end

    test "can be overridden for tests" do
      state = base_state(clock_fun: fn -> 42 end)
      assert state.clock_fun.() == 42
    end
  end
end
