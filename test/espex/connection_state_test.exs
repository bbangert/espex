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
      refute state.zwave_subscribed
      refute state.infrared_subscribed
    end

    test "adapter map has all features defaulting to nil" do
      state = base_state()
      assert state.adapters == %{serial_proxy: nil, zwave_proxy: nil, infrared_proxy: nil, entity_provider: nil}
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

  describe "subscription flags" do
    test "put_zwave_subscribed / put_infrared_subscribed toggle" do
      state = base_state() |> ConnectionState.put_zwave_subscribed(true) |> ConnectionState.put_infrared_subscribed(true)
      assert state.zwave_subscribed
      assert state.infrared_subscribed
      state = state |> ConnectionState.put_zwave_subscribed(false)
      refute state.zwave_subscribed
      assert state.infrared_subscribed
    end
  end

  describe "adapter lookup" do
    test "adapter/2 returns nil when unconfigured, module when configured" do
      state =
        base_state(
          adapters: %{serial_proxy: MyApp.Serial, zwave_proxy: nil, infrared_proxy: nil, entity_provider: nil}
        )

      assert ConnectionState.adapter(state, :serial_proxy) == MyApp.Serial
      assert ConnectionState.adapter(state, :zwave_proxy) == nil
      assert ConnectionState.adapter?(state, :serial_proxy)
      refute ConnectionState.adapter?(state, :zwave_proxy)
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
