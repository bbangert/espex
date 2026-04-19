# Entity types

Your `Espex.EntityProvider` implementation returns three kinds of
protobuf structs:

- **`Espex.Proto.ListEntities*Response`** — advertises an entity to the
  client at connection time
- **`Espex.Proto.*StateResponse`** — reports state (either as initial
  state at subscription time, or when pushed via `Espex.push_state/2`)
- **`Espex.Proto.*CommandRequest`** — what the client sends when the
  user interacts with the entity; routed to your provider's
  `handle_command/1`

This guide walks through the common types with their key fields and a
short example per type. See `Espex.EntityProvider` for the behaviour
itself and the GenServer pattern for stateful providers.

All entities share a few fields. Unless called out otherwise:

- `object_id` — a stable string id unique within your device
  (snake_case, e.g. `"kitchen_light"`)
- `key` — a `uint32` identifier unique within your device; it's what
  `CommandRequest` and `StateResponse` reference. Pick something stable
  across restarts (a constant module attribute is fine).
- `name` — human-readable label shown in Home Assistant
- `icon` — optional Material Design Icon name (e.g. `"mdi:thermometer"`)
- `device_class` — optional string matching one of Home Assistant's
  built-in device classes for that type (see the Home Assistant docs
  for the canonical list)
- `device_id` — optional `uint32` linking this entity to a sub-device
  declared in `DeviceConfig.Device`

## Switch

A boolean on/off actuator.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesSwitchResponse` | Advertisement |
| `SwitchStateResponse` | State (`state: true \| false`) |
| `SwitchCommandRequest` | Command (`state: true \| false`) |

Extra field of note on the advertisement: `assumed_state` — set `true`
if the switch cannot reliably read back its own state (i.e. the server
is acting blind).

```elixir
@switch_key 1001

def list_entities do
  [
    %Proto.ListEntitiesSwitchResponse{
      object_id: "kitchen_outlet",
      key: @switch_key,
      name: "Kitchen Outlet",
      icon: "mdi:power-socket-us",
      device_class: "outlet"
    }
  ]
end

def initial_states do
  [%Proto.SwitchStateResponse{key: @switch_key, state: false}]
end

def handle_command(%Proto.SwitchCommandRequest{key: @switch_key, state: s}) do
  # Drive the physical relay, then echo the new state back:
  Espex.push_state(server_name, %Proto.SwitchStateResponse{
    key: @switch_key,
    state: s
  })
  :ok
end
```

## Binary sensor

A read-only boolean — motion, door-open, window-contact, etc.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesBinarySensorResponse` | Advertisement |
| `BinarySensorStateResponse` | State (`state`, `missing_state`) |

No command type — binary sensors cannot be commanded. Set
`missing_state: true` if the reading is currently unavailable.

Common `device_class` values: `"motion"`, `"door"`, `"window"`,
`"occupancy"`, `"moisture"`, `"presence"`.

```elixir
@motion_key 2001

def list_entities do
  [
    %Proto.ListEntitiesBinarySensorResponse{
      object_id: "hallway_motion",
      key: @motion_key,
      name: "Hallway Motion",
      device_class: "motion"
    }
  ]
end

def initial_states do
  [%Proto.BinarySensorStateResponse{key: @motion_key, state: false, missing_state: false}]
end

# Pushed from wherever your motion PIR signal enters the system:
Espex.push_state(server_name, %Proto.BinarySensorStateResponse{
  key: @motion_key,
  state: true,
  missing_state: false
})
```

## Sensor

A numeric reading with a unit — temperature, humidity, power, etc.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesSensorResponse` | Advertisement |
| `SensorStateResponse` | State (`state: float`, `missing_state`) |

Key advertisement fields:

- `unit_of_measurement` — string like `"°C"`, `"W"`, `"%"`
- `accuracy_decimals` — how many decimal places HA should round to
- `state_class` — one of `:STATE_CLASS_NONE`, `:STATE_CLASS_MEASUREMENT`,
  `:STATE_CLASS_TOTAL`, `:STATE_CLASS_TOTAL_INCREASING`. Drives how HA
  graphs and aggregates the value.
- `force_update` — emit updates even when the value didn't change
  (useful for heartbeat-style sensors)

**Gotcha**: always set `missing_state: false` when you have a real
reading. The default (`false`) is what you want, but the field is not
`has_state`-style — if you don't populate it you're implicitly saying
"no reading".

```elixir
@temp_key 3001

def list_entities do
  [
    %Proto.ListEntitiesSensorResponse{
      object_id: "room_temperature",
      key: @temp_key,
      name: "Room Temperature",
      unit_of_measurement: "°C",
      accuracy_decimals: 1,
      device_class: "temperature",
      state_class: :STATE_CLASS_MEASUREMENT,
      icon: "mdi:thermometer"
    }
  ]
end

def initial_states do
  [%Proto.SensorStateResponse{key: @temp_key, state: 20.0, missing_state: false}]
end
```

## Button

A stateless action — momentary tap, no "current state".

| Struct | Purpose |
|--------|---------|
| `ListEntitiesButtonResponse` | Advertisement |
| `ButtonCommandRequest` | Command (just `key`) |

No state response — buttons don't have persistent state. The command
carries only the key (and optional `device_id`).

Common `device_class` values: `"restart"`, `"identify"`, `"update"`.

```elixir
@reboot_key 4001

def list_entities do
  [
    %Proto.ListEntitiesButtonResponse{
      object_id: "reboot",
      key: @reboot_key,
      name: "Reboot",
      icon: "mdi:restart",
      device_class: "restart"
    }
  ]
end

def initial_states, do: []  # buttons have no state

def handle_command(%Proto.ButtonCommandRequest{key: @reboot_key}) do
  MyApp.reboot_something()
  :ok
end
```

## Light

On/off plus brightness, color, and effects. The advertisement declares
which color modes the light supports; state and command fields that
don't apply to the selected mode are ignored.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesLightResponse` | Advertisement |
| `LightStateResponse` | State |
| `LightCommandRequest` | Command (uses `has_*` flags) |

Key advertisement fields:

- `supported_color_modes` — list of `Espex.Proto.ColorMode` atoms
  (`:COLOR_MODE_ON_OFF`, `:COLOR_MODE_BRIGHTNESS`, `:COLOR_MODE_RGB`,
  `:COLOR_MODE_COLOR_TEMPERATURE`, `:COLOR_MODE_RGB_WHITE`,
  `:COLOR_MODE_COLD_WARM_WHITE`, etc.)
- `min_mireds` / `max_mireds` — inverse-Kelvin range for the color
  temperature slider (e.g. `154.0` / `500.0` ≈ 6500K / 2000K)
- `effects` — list of effect names the light supports (strings)

### The `has_*` flag pattern

`LightCommandRequest` has paired `has_X` + `X` fields for almost
everything. The client sets `has_X: true` on the fields it actually
wants to change and leaves the others. Always check `has_X` before
reading `X` — otherwise you'll read a zero-value default and treat it
as an intentional setting.

```elixir
def handle_command(%Proto.LightCommandRequest{key: @light_key} = cmd) do
  # Build a partial update from only the fields the client set:
  patch =
    %{}
    |> maybe_put(cmd.has_state, :state, cmd.state)
    |> maybe_put(cmd.has_brightness, :brightness, cmd.brightness)
    |> maybe_put(cmd.has_rgb, :rgb, {cmd.red, cmd.green, cmd.blue})
    |> maybe_put(cmd.has_color_temperature, :color_temperature, cmd.color_temperature)

  MyApp.Light.update(patch)
  :ok
end

defp maybe_put(map, false, _, _), do: map
defp maybe_put(map, true, key, value), do: Map.put(map, key, value)
```

A state push looks like:

```elixir
Espex.push_state(server_name, %Proto.LightStateResponse{
  key: @light_key,
  state: true,
  brightness: 0.8,
  color_mode: :COLOR_MODE_RGB,
  red: 1.0,
  green: 0.5,
  blue: 0.2
})
```

## Cover

Blinds, shutters, garage doors — anything with a position in the range
`0.0` (closed) to `1.0` (open), optionally with tilt.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesCoverResponse` | Advertisement |
| `CoverStateResponse` | State |
| `CoverCommandRequest` | Command (uses `has_*` flags) |

Key advertisement fields:

- `supports_position` — does the cover report/accept a position value?
- `supports_tilt` — does it have tilt-able slats?
- `supports_stop` — should HA show a "stop" button?
- `assumed_state` — set `true` if you can only command it, not read
  back its position

`CoverStateResponse.current_operation` uses `Espex.Proto.CoverOperation`:
`:COVER_OPERATION_IDLE`, `:COVER_OPERATION_IS_OPENING`,
`:COVER_OPERATION_IS_CLOSING`.

```elixir
@blinds_key 5001

def list_entities do
  [
    %Proto.ListEntitiesCoverResponse{
      object_id: "living_room_blinds",
      key: @blinds_key,
      name: "Living Room Blinds",
      supports_position: true,
      supports_stop: true,
      device_class: "blind"
    }
  ]
end

def handle_command(%Proto.CoverCommandRequest{key: @blinds_key} = cmd) do
  cond do
    cmd.stop -> MyApp.Cover.stop()
    cmd.has_position -> MyApp.Cover.move_to(cmd.position)
    true -> :ok
  end
end

# State update while moving:
Espex.push_state(server_name, %Proto.CoverStateResponse{
  key: @blinds_key,
  position: 0.5,
  current_operation: :COVER_OPERATION_IS_OPENING
})
```

## Climate

HVAC control — the richest entity type. The advertisement declares
every supported mode, fan speed, swing mode, and preset upfront; the
state reports the currently active values, and the command sets new
ones (with `has_*` flags).

| Struct | Purpose |
|--------|---------|
| `ListEntitiesClimateResponse` | Advertisement |
| `ClimateStateResponse` | State |
| `ClimateCommandRequest` | Command (uses `has_*` flags) |

Key advertisement fields:

- `supported_modes` — list of `Espex.Proto.ClimateMode` atoms:
  `:CLIMATE_MODE_OFF`, `:CLIMATE_MODE_HEAT_COOL`, `:CLIMATE_MODE_COOL`,
  `:CLIMATE_MODE_HEAT`, `:CLIMATE_MODE_FAN_ONLY`, `:CLIMATE_MODE_DRY`,
  `:CLIMATE_MODE_AUTO`
- `supported_fan_modes` — `Espex.Proto.ClimateFanMode`:
  `:CLIMATE_FAN_ON`, `:CLIMATE_FAN_OFF`, `:CLIMATE_FAN_AUTO`,
  `:CLIMATE_FAN_LOW`, `:CLIMATE_FAN_MEDIUM`, `:CLIMATE_FAN_HIGH`, …
- `supported_swing_modes` — `Espex.Proto.ClimateSwingMode`:
  `:CLIMATE_SWING_OFF`, `:CLIMATE_SWING_BOTH`, `:CLIMATE_SWING_VERTICAL`,
  `:CLIMATE_SWING_HORIZONTAL`
- `supported_presets` — `Espex.Proto.ClimatePreset` (eco, away, boost,
  comfort, home, sleep, activity)
- `visual_min_temperature` / `visual_max_temperature` / `visual_target_temperature_step`
  — UI bounds and resolution (floats in °C)
- `supports_two_point_target_temperature` — set `true` if HEAT_COOL
  mode uses distinct low/high setpoints instead of a single target
- `supports_action` — set `true` if you can report the *action* the
  system is currently taking (heating/cooling/idle) in addition to the
  configured *mode*

### Mode vs action

- **`mode`** is what the user asked for (HEAT, COOL, HEAT_COOL, …).
- **`action`** (`Espex.Proto.ClimateAction`) is what the system is
  currently doing: `:CLIMATE_ACTION_HEATING`, `:CLIMATE_ACTION_COOLING`,
  `:CLIMATE_ACTION_IDLE`, `:CLIMATE_ACTION_DRYING`,
  `:CLIMATE_ACTION_FAN`, `:CLIMATE_ACTION_DEFROSTING`,
  `:CLIMATE_ACTION_OFF`.

A thermostat in `HEAT` mode is `IDLE` when the room's at the setpoint
and `HEATING` while it's ramping up.

```elixir
@thermostat_key 6001

def list_entities do
  [
    %Proto.ListEntitiesClimateResponse{
      object_id: "thermostat",
      key: @thermostat_key,
      name: "Thermostat",
      supports_current_temperature: true,
      supports_action: true,
      supported_modes: [:CLIMATE_MODE_OFF, :CLIMATE_MODE_HEAT, :CLIMATE_MODE_COOL, :CLIMATE_MODE_HEAT_COOL],
      supported_fan_modes: [:CLIMATE_FAN_AUTO, :CLIMATE_FAN_LOW, :CLIMATE_FAN_HIGH],
      visual_min_temperature: 10.0,
      visual_max_temperature: 32.0,
      visual_target_temperature_step: 0.5
    }
  ]
end

def initial_states do
  [
    %Proto.ClimateStateResponse{
      key: @thermostat_key,
      mode: :CLIMATE_MODE_HEAT,
      current_temperature: 21.5,
      target_temperature: 22.0,
      fan_mode: :CLIMATE_FAN_AUTO,
      action: :CLIMATE_ACTION_IDLE
    }
  ]
end

def handle_command(%Proto.ClimateCommandRequest{key: @thermostat_key} = cmd) do
  if cmd.has_mode, do: MyApp.HVAC.set_mode(cmd.mode)
  if cmd.has_target_temperature, do: MyApp.HVAC.set_target(cmd.target_temperature)
  if cmd.has_fan_mode, do: MyApp.HVAC.set_fan(cmd.fan_mode)
  :ok
end
```
