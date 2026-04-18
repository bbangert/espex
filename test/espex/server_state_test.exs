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
             entity_provider: nil
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
end
