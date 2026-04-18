# Interactive end-to-end demo of the Espex library.
#
# Run with:
#
#   mix run test/manual/live_demo.exs              # plaintext
#   ESPEX_ENCRYPT=1 mix run test/manual/live_demo.exs  # Noise-encrypted
#
# Starts an Espex server advertising a Switch, a Button, and a Sensor. Walks
# you through connecting an ESPHome client (e.g. Home Assistant) to it and
# verifying that:
#
#   1. flipping the switch on the client side reaches the server,
#   2. pushing the button on the client side reaches the server,
#   3. a sensor value pushed from the server side shows up on the client.
#
# When ESPEX_ENCRYPT=1 is set, a random 32-byte PSK is generated on
# startup and printed as a base64 string; paste it into HA's ESPHome
# integration dialog under "Encryption key".
#
# Prompts are interactive — expect to paste IP/port into Home Assistant and
# then press Enter in this terminal to advance through the checklist.

Logger.configure(level: :debug)

defmodule Espex.DemoEntityProvider do
  @moduledoc false
  @behaviour Espex.EntityProvider

  use GenServer

  alias Espex.Proto

  @switch_key 1001
  @button_key 1002
  @sensor_key 1003

  @switch_device_id 1
  @button_device_id 2

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def subscribe_events(pid \\ self()), do: GenServer.call(__MODULE__, {:subscribe_events, pid})
  def sensor_value, do: GenServer.call(__MODULE__, :sensor_value)
  def set_sensor_value(value), do: GenServer.call(__MODULE__, {:set_sensor_value, value})
  def switch_value, do: GenServer.call(__MODULE__, :switch_value)

  # ----- EntityProvider callbacks -----

  @impl Espex.EntityProvider
  def list_entities do
    [
      %Proto.ListEntitiesSwitchResponse{
        object_id: "demo_switch",
        key: @switch_key,
        name: "Demo Switch",
        icon: "mdi:light-switch",
        disabled_by_default: false,
        entity_category: :ENTITY_CATEGORY_NONE,
        device_id: @switch_device_id
      },
      %Proto.ListEntitiesButtonResponse{
        object_id: "demo_button",
        key: @button_key,
        name: "Demo Button",
        icon: "mdi:gesture-tap-button",
        disabled_by_default: false,
        entity_category: :ENTITY_CATEGORY_NONE,
        device_id: @button_device_id
      },
      %Proto.ListEntitiesSensorResponse{
        object_id: "demo_sensor",
        key: @sensor_key,
        name: "Demo Sensor",
        unit_of_measurement: "°C",
        accuracy_decimals: 1,
        state_class: :STATE_CLASS_MEASUREMENT,
        icon: "mdi:thermometer",
        disabled_by_default: false,
        entity_category: :ENTITY_CATEGORY_NONE
      }
    ]
  end

  @impl Espex.EntityProvider
  def initial_states do
    snapshot = GenServer.call(__MODULE__, :snapshot)

    [
      %Proto.SwitchStateResponse{key: @switch_key, state: snapshot.switch, device_id: @switch_device_id},
      %Proto.SensorStateResponse{key: @sensor_key, state: snapshot.sensor, missing_state: false}
    ]
  end

  @impl Espex.EntityProvider
  def handle_command(cmd) do
    GenServer.cast(__MODULE__, {:command, cmd})
    :ok
  end

  # ----- GenServer -----

  @impl GenServer
  def init(opts) do
    server = Keyword.get(opts, :server, Espex.Server)
    {:ok, %{switch: false, sensor: 20.0, observers: MapSet.new(), server: server}}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}
  def handle_call(:sensor_value, _from, state), do: {:reply, state.sensor, state}
  def handle_call(:switch_value, _from, state), do: {:reply, state.switch, state}

  def handle_call({:subscribe_events, pid}, _from, state) do
    {:reply, :ok, %{state | observers: MapSet.put(state.observers, pid)}}
  end

  def handle_call({:set_sensor_value, value}, _from, state) do
    Espex.push_state(state.server, %Proto.SensorStateResponse{
      key: @sensor_key,
      state: value,
      missing_state: false
    })

    {:reply, :ok, %{state | sensor: value}}
  end

  @impl GenServer
  def handle_cast({:command, %Proto.SwitchCommandRequest{key: @switch_key, state: new_state}}, state) do
    Espex.push_state(state.server, %Proto.SwitchStateResponse{
      key: @switch_key,
      state: new_state,
      device_id: @switch_device_id
    })

    notify(state.observers, {:switch_flipped, new_state})
    {:noreply, %{state | switch: new_state}}
  end

  def handle_cast({:command, %Proto.ButtonCommandRequest{key: @button_key}}, state) do
    notify(state.observers, :button_pressed)
    {:noreply, state}
  end

  def handle_cast({:command, _other}, state), do: {:noreply, state}

  defp notify(observers, event) do
    Enum.each(observers, &send(&1, {:demo_event, event}))
  end
end

defmodule Espex.DemoRunner do
  @moduledoc false

  @server_name :espex_demo_server
  @sup_name :espex_demo_supervisor

  def run do
    {:ok, provider_pid} = Espex.DemoEntityProvider.start_link(server: @server_name)

    psk = maybe_generate_psk()

    device_config =
      [
        name: "espex-demo",
        friendly_name: "Espex Demo",
        project_name: "espex.demo",
        project_version: "0.1.0",
        devices: [
          Espex.DeviceConfig.Device.new(id: 1, name: "Switch Pod"),
          Espex.DeviceConfig.Device.new(id: 2, name: "Button Pod")
        ]
      ]
      |> then(fn cfg -> if psk, do: Keyword.put(cfg, :psk, psk), else: cfg end)

    {:ok, sup_pid} =
      Espex.start_link(
        name: @sup_name,
        server_name: @server_name,
        port: 6053,
        device_config: device_config,
        entity_provider: Espex.DemoEntityProvider
      )

    {:ok, bound} = Espex.Supervisor.bound_port(sup_pid)

    Espex.DemoEntityProvider.subscribe_events()

    banner(bound, psk)
    await_connect()
    verify_switch()
    verify_button()
    verify_sensor_push()

    IO.puts("""

      All three flows verified. Stopping the server.
    """)

    try do
      Supervisor.stop(sup_pid, :normal, 5_000)
      GenServer.stop(provider_pid, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end

    System.halt(0)
  end

  defp banner(port, psk) do
    ip = local_ipv4()

    encryption_line =
      case psk do
        nil -> "Encryption key:    (leave blank — this demo is plaintext)"
        bin -> "Encryption key:    #{Base.encode64(bin)}"
      end

    IO.puts("""

    ╔════════════════════════════════════════════════════════════════════╗
                              Espex live demo
    ╠════════════════════════════════════════════════════════════════════╣

      Device name:       espex-demo
      Friendly name:     Espex Demo
      Listening on:      #{ip}:#{port}

      In Home Assistant, add a new "ESPHome" integration and use:

        Host:              #{ip}
        Port:              #{port}
        #{encryption_line}

    ╚════════════════════════════════════════════════════════════════════╝
    """)
  end

  defp maybe_generate_psk do
    case System.get_env("ESPEX_ENCRYPT") do
      env when env in [nil, "", "0", "false"] -> nil
      _ -> :crypto.strong_rand_bytes(32)
    end
  end

  defp await_connect do
    _ = IO.gets("Once the device shows as connected in HA, press Enter... ")
  end

  defp verify_switch do
    IO.puts("\nStep 1/3 — flip the 'Demo Switch' entity in Home Assistant.")
    IO.puts("         (waiting for a SwitchCommandRequest)\n")

    receive do
      {:demo_event, {:switch_flipped, new_state}} ->
        IO.puts("    ✓ received: SwitchCommandRequest state=#{new_state}")
    after
      120_000 ->
        raise "timed out waiting for switch command"
    end
  end

  defp verify_button do
    IO.puts("\nStep 2/3 — press the 'Demo Button' entity in Home Assistant.")
    IO.puts("         (waiting for a ButtonCommandRequest)\n")

    receive do
      {:demo_event, :button_pressed} ->
        IO.puts("    ✓ received: ButtonCommandRequest")
    after
      120_000 ->
        raise "timed out waiting for button press"
    end
  end

  defp verify_sensor_push do
    current = Espex.DemoEntityProvider.sensor_value()
    new_value = 42.5

    IO.puts("\nStep 3/3 — in Home Assistant, note that 'Demo Sensor' reads #{current} °C.")
    _ = IO.gets("         Press Enter once you've confirmed the current value... ")

    :ok = Espex.DemoEntityProvider.set_sensor_value(new_value)
    IO.puts("    ✓ pushed new sensor value: #{new_value} °C")

    answer = IO.gets("         Does Home Assistant now show #{new_value} °C? (y/n) ")

    case answer && String.trim(answer) |> String.downcase() do
      "y" -> IO.puts("    ✓ sensor push verified")
      _ -> raise "sensor push not verified"
    end
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

Espex.DemoRunner.run()
