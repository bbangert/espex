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

This guide is a per-type reference — entries are listed alphabetically.
See `Espex.EntityProvider` for the behaviour itself and the GenServer
pattern for stateful providers.

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

## AlarmControlPanel

A security-panel entity with named arm modes and an optional code.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesAlarmControlPanelResponse` | Advertisement |
| `AlarmControlPanelStateResponse` | State (`state` enum) |
| `AlarmControlPanelCommandRequest` | Command (`command` enum, bare `code` string) |

Advertisement: `supported_features` (bitmask), `requires_code`,
`requires_code_to_arm`.

State `state` uses `Espex.Proto.AlarmControlPanelState` (10 values):
`:ALARM_STATE_DISARMED`, `:ALARM_STATE_ARMED_HOME`,
`:ALARM_STATE_ARMED_AWAY`, `:ALARM_STATE_ARMED_NIGHT`,
`:ALARM_STATE_ARMED_VACATION`, `:ALARM_STATE_ARMED_CUSTOM_BYPASS`,
`:ALARM_STATE_PENDING`, `:ALARM_STATE_ARMING`,
`:ALARM_STATE_DISARMING`, `:ALARM_STATE_TRIGGERED`.

Command `command` uses `Espex.Proto.AlarmControlPanelStateCommand` (7
values): `:ALARM_CONTROL_PANEL_DISARM`, `:ALARM_CONTROL_PANEL_ARM_AWAY`,
`:ALARM_CONTROL_PANEL_ARM_HOME`, `:ALARM_CONTROL_PANEL_ARM_NIGHT`,
`:ALARM_CONTROL_PANEL_ARM_VACATION`,
`:ALARM_CONTROL_PANEL_ARM_CUSTOM_BYPASS`,
`:ALARM_CONTROL_PANEL_TRIGGER`.

No `has_*` flags — `code` is a bare string, empty when not set.

```elixir
%Proto.AlarmControlPanelStateResponse{
  key: 8201, state: :ALARM_STATE_ARMED_HOME
}

# Client sends:
%Proto.AlarmControlPanelCommandRequest{
  key: 8201, command: :ALARM_CONTROL_PANEL_DISARM, code: "1234"
}
```

## BinarySensor

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

## Camera

An image source. Different shape from other entities — no regular
state push; the client explicitly requests a frame (or opens a
stream) via `CameraImageRequest`, and the server replies with one or
more `CameraImageResponse` frames.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesCameraResponse` | Advertisement (standard fields only) |
| `CameraImageRequest` | Client request (`single: bool`, `stream: bool`) |
| `CameraImageResponse` | Image data (`data: bytes`, `done: bool`) |

`CameraImageRequest` is **not** routed through `c:handle_command/1` by
espex today — it's a top-level RPC handled in `Espex.Dispatch`, and
there's no built-in camera adapter. If you want to expose a camera,
you'll need to handle the incoming request at a lower level or wait
for a future `CameraProvider` behaviour.

For protocol reference:

```elixir
%Proto.ListEntitiesCameraResponse{
  object_id: "front_porch", key: 8501, name: "Front Porch"
}

# Response frame(s) — `done: true` signals end of stream:
%Proto.CameraImageResponse{key: 8501, data: jpeg_bytes, done: true}
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

## Date

A calendar-date input (year/month/day, no time of day).

| Struct | Purpose |
|--------|---------|
| `ListEntitiesDateResponse` | Advertisement (standard fields only) |
| `DateStateResponse` | `year`, `month`, `day`, `missing_state` |
| `DateCommandRequest` | `year`, `month`, `day` |

No `has_*` flags — all three components are always set. Same
`missing_state` semantics as `Sensor`: set to `false` explicitly when
a real value is present.

```elixir
%Proto.DateStateResponse{
  key: 7801, year: 2026, month: 4, day: 15, missing_state: false
}
```

## DateTime

A combined date-and-time as a single epoch-seconds integer.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesDateTimeResponse` | Advertisement (standard fields only) |
| `DateTimeStateResponse` | `epoch_seconds: fixed32`, `missing_state` |
| `DateTimeCommandRequest` | `epoch_seconds: fixed32` |

Note the `fixed32` wraps at 2106; the protocol is scoped to Unix
timestamps that fit in 32 bits.

```elixir
%Proto.DateTimeStateResponse{
  key: 8001,
  epoch_seconds: DateTime.utc_now() |> DateTime.to_unix(),
  missing_state: false
}
```

## Event

Fires named event types — momentary, stateless, originating on the
server side (a server-side analog of `Button`).

| Struct | Purpose |
|--------|---------|
| `ListEntitiesEventResponse` | Advertisement (`event_types: [String.t()]`) |
| `EventResponse` | Event (`event_type: string`) |

Event has no command (it's server→client only) and no persistent
state. Advertise the list of event type strings you'll fire, then call
`Espex.push_state/2` with an `EventResponse` whenever one happens.

```elixir
%Proto.ListEntitiesEventResponse{
  object_id: "doorbell", key: 8401, name: "Doorbell",
  event_types: ["single_press", "double_press", "long_press"],
  device_class: "doorbell"
}

# When the doorbell fires:
Espex.push_state(server_name, %Proto.EventResponse{
  key: 8401, event_type: "single_press"
})
```

## Fan

On/off plus speed, oscillation, direction, and optional named preset
modes. Uses the `has_*` flag pattern like Light and Climate.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesFanResponse` | Advertisement |
| `FanStateResponse` | State |
| `FanCommandRequest` | Command |

Key advertisement fields:

- `supports_oscillation` / `supports_speed` / `supports_direction` —
  capability flags, mirror HA's UI
- `supported_speed_count` — integer; HA splits the slider into this
  many steps. State and commands use `speed_level` 1..N (not a percent).
- `supported_preset_modes` — list of string preset names (e.g.
  `["Sleep", "Whoosh"]`)

State/command `direction` uses `Espex.Proto.FanDirection`:
`:FAN_DIRECTION_FORWARD`, `:FAN_DIRECTION_REVERSE`.

```elixir
%Proto.ListEntitiesFanResponse{
  object_id: "ceiling_fan", key: 7001, name: "Ceiling Fan",
  supports_speed: true, supports_oscillation: true, supports_direction: true,
  supported_speed_count: 5
}

%Proto.FanStateResponse{
  key: 7001, state: true, speed_level: 3, oscillating: false,
  direction: :FAN_DIRECTION_FORWARD
}
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

## Lock

A deadbolt-style lock. State is an enum, command is a separate enum,
optional per-command code (for keypads).

| Struct | Purpose |
|--------|---------|
| `ListEntitiesLockResponse` | Advertisement |
| `LockStateResponse` | State (`state: LockState` enum) |
| `LockCommandRequest` | Command (`command: LockCommand` enum, `has_code` + `code`) |

Advertisement flags: `supports_open` (does the lock differentiate
"unlock" from "open"?), `requires_code` (client must always collect a
code), `code_format` (regex/mask to hint the UI).

`Espex.Proto.LockState`:
`:LOCK_STATE_NONE`, `:LOCK_STATE_LOCKED`, `:LOCK_STATE_UNLOCKED`,
`:LOCK_STATE_JAMMED`, `:LOCK_STATE_LOCKING`, `:LOCK_STATE_UNLOCKING`.

`Espex.Proto.LockCommand`:
`:LOCK_UNLOCK`, `:LOCK_LOCK`, `:LOCK_OPEN`.

```elixir
%Proto.ListEntitiesLockResponse{
  object_id: "front_door", key: 7201, name: "Front Door",
  supports_open: false, requires_code: true
}

%Proto.LockStateResponse{key: 7201, state: :LOCK_STATE_LOCKED}

# Client sends:
%Proto.LockCommandRequest{
  key: 7201, command: :LOCK_UNLOCK, has_code: true, code: "1234"
}
```

## MediaPlayer

A music / audio source entity. Rich state (idle/playing/paused/etc.)
plus volume, mute, and URL-based media loading.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesMediaPlayerResponse` | Advertisement |
| `MediaPlayerStateResponse` | State |
| `MediaPlayerCommandRequest` | Command (uses `has_*` flags) |

Advertisement fields: `supports_pause`, `supported_formats` (list of
`MediaPlayerSupportedFormat` structs declaring sample rate / channels
/ format strings HA can stream to you), `feature_flags`.

State `state` uses `Espex.Proto.MediaPlayerState`:
`:MEDIA_PLAYER_STATE_NONE`, `:MEDIA_PLAYER_STATE_IDLE`,
`:MEDIA_PLAYER_STATE_PLAYING`, `:MEDIA_PLAYER_STATE_PAUSED`,
`:MEDIA_PLAYER_STATE_ANNOUNCING`, `:MEDIA_PLAYER_STATE_OFF`,
`:MEDIA_PLAYER_STATE_ON`.

Command `command` uses `Espex.Proto.MediaPlayerCommand`:
`:MEDIA_PLAYER_COMMAND_PLAY`, `:MEDIA_PLAYER_COMMAND_PAUSE`,
`:MEDIA_PLAYER_COMMAND_STOP`, `:MEDIA_PLAYER_COMMAND_MUTE`,
`:MEDIA_PLAYER_COMMAND_UNMUTE`, `:MEDIA_PLAYER_COMMAND_TOGGLE`,
`:MEDIA_PLAYER_COMMAND_VOLUME_UP`, `:MEDIA_PLAYER_COMMAND_VOLUME_DOWN`,
`:MEDIA_PLAYER_COMMAND_TURN_ON`, `:MEDIA_PLAYER_COMMAND_TURN_OFF`, and
a handful more (enqueue, repeat_one, repeat_off, clear_playlist).

```elixir
%Proto.ListEntitiesMediaPlayerResponse{
  object_id: "living_speaker", key: 8101, name: "Living Room Speaker",
  supports_pause: true
}

%Proto.MediaPlayerStateResponse{
  key: 8101,
  state: :MEDIA_PLAYER_STATE_PLAYING,
  volume: 0.5,
  muted: false
}

# Client sends:
%Proto.MediaPlayerCommandRequest{
  key: 8101,
  has_media_url: true, media_url: "https://example.com/song.mp3",
  has_volume: true, volume: 0.7
}
```

## Number

An editable numeric setpoint — temperature preset, volume slider, etc.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesNumberResponse` | Advertisement |
| `NumberStateResponse` | State (`state: float`, `missing_state`) |
| `NumberCommandRequest` | Command (`state: float`) |

Advertisement fields: `min_value`, `max_value`, `step`,
`unit_of_measurement`, `device_class`, `mode` (`Espex.Proto.NumberMode`:
`:NUMBER_MODE_AUTO`, `:NUMBER_MODE_BOX`, `:NUMBER_MODE_SLIDER` — hints
HA's UI). No `has_*` flag on the command — `state` is always required.

```elixir
%Proto.ListEntitiesNumberResponse{
  object_id: "target_temp", key: 7401, name: "Target Temperature",
  min_value: 10.0, max_value: 30.0, step: 0.5,
  unit_of_measurement: "°C", mode: :NUMBER_MODE_SLIDER
}

%Proto.NumberStateResponse{key: 7401, state: 20.0, missing_state: false}
```

## Select

A dropdown picking from a fixed list of named options.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesSelectResponse` | Advertisement (`options: [String.t()]`) |
| `SelectStateResponse` | State (`state: string`, `missing_state`) |
| `SelectCommandRequest` | Command (`state: string`) |

The `state` string on state/command must be one of the advertised
`options`. No `has_*` flag.

```elixir
%Proto.ListEntitiesSelectResponse{
  object_id: "brew_profile", key: 7501, name: "Brew Profile",
  options: ["Espresso", "Lungo", "Americano"]
}

%Proto.SelectStateResponse{key: 7501, state: "Espresso", missing_state: false}
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

## Siren

An audible/visible alarm. Supports optional named tones, variable
duration, and variable volume.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesSirenResponse` | Advertisement |
| `SirenStateResponse` | State (`state: bool`) |
| `SirenCommandRequest` | Command (`has_*` flags) |

Advertisement fields: `tones` (list of strings), `supports_duration`,
`supports_volume`.

```elixir
%Proto.ListEntitiesSirenResponse{
  object_id: "burglar_alarm", key: 7301, name: "Burglar Alarm",
  tones: ["fire", "burglar", "chime"],
  supports_duration: true, supports_volume: true
}

# Client sends:
%Proto.SirenCommandRequest{
  key: 7301, has_state: true, state: true,
  has_tone: true, tone: "burglar",
  has_duration: true, duration: 30_000,
  has_volume: true, volume: 0.8
}
```

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

## Text

A free-form text input (short strings, passwords, patterns).

| Struct | Purpose |
|--------|---------|
| `ListEntitiesTextResponse` | Advertisement |
| `TextStateResponse` | State (`state: string`, `missing_state`) |
| `TextCommandRequest` | Command (`state: string`) |

Advertisement fields: `min_length`, `max_length`, `pattern` (regex
the HA UI can validate against), `mode` (`Espex.Proto.TextMode`:
`:TEXT_MODE_TEXT`, `:TEXT_MODE_PASSWORD`).

```elixir
%Proto.ListEntitiesTextResponse{
  object_id: "wifi_ssid", key: 7601, name: "Wi-Fi SSID",
  min_length: 1, max_length: 32, mode: :TEXT_MODE_TEXT
}
```

## TextSensor

The string cousin of `Sensor` — read-only, reports a string value.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesTextSensorResponse` | Advertisement |
| `TextSensorStateResponse` | State (`state: string`, `missing_state`) |

Same `missing_state` gotcha as `Sensor` — set it to `false` explicitly
when you have a real reading.

```elixir
%Proto.ListEntitiesTextSensorResponse{
  object_id: "current_mode", key: 7701, name: "Current Mode"
}

%Proto.TextSensorStateResponse{
  key: 7701, state: "Running", missing_state: false
}
```

## Time

A time-of-day input (hour/minute/second, no date).

| Struct | Purpose |
|--------|---------|
| `ListEntitiesTimeResponse` | Advertisement (standard fields only) |
| `TimeStateResponse` | `hour`, `minute`, `second`, `missing_state` |
| `TimeCommandRequest` | `hour`, `minute`, `second` |

No `has_*` flags — all three components are always set.

```elixir
%Proto.TimeStateResponse{
  key: 7901, hour: 14, minute: 30, second: 0, missing_state: false
}
```

## Update

A firmware/software update entity — lets HA trigger an update and see
progress.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesUpdateResponse` | Advertisement |
| `UpdateStateResponse` | State (`in_progress`, `has_progress`, `progress`, version strings) |
| `UpdateCommandRequest` | Command (`command: UpdateCommand` enum) |

State fields of note: `current_version` / `latest_version` (strings,
arbitrary format), `in_progress` (bool), `has_progress` +
`progress` (float 0.0–1.0; only valid when `has_progress` is true),
`title` / `release_summary` / `release_url` (optional metadata shown
in HA's update dialog).

Command `command` uses `Espex.Proto.UpdateCommand`:
`:UPDATE_COMMAND_NONE`, `:UPDATE_COMMAND_UPDATE`,
`:UPDATE_COMMAND_CHECK`.

```elixir
%Proto.UpdateStateResponse{
  key: 8301,
  current_version: "1.2.0",
  latest_version: "1.3.0",
  in_progress: false,
  has_progress: false,
  release_url: "https://example.com/changelog/1.3.0"
}
```

## Valve

Mirrors `Cover` almost exactly but scoped to valves (water, gas).

| Struct | Purpose |
|--------|---------|
| `ListEntitiesValveResponse` | Advertisement |
| `ValveStateResponse` | State |
| `ValveCommandRequest` | Command (`has_position` flag, `stop` boolean) |

Capability flags: `supports_position`, `supports_stop`, `assumed_state`.
`ValveStateResponse.current_operation` uses `Espex.Proto.ValveOperation`:
`:VALVE_OPERATION_IDLE`, `:VALVE_OPERATION_IS_OPENING`,
`:VALVE_OPERATION_IS_CLOSING`.

```elixir
%Proto.ListEntitiesValveResponse{
  object_id: "garden_valve", key: 7101, name: "Garden Valve",
  supports_position: true, supports_stop: true, device_class: "water"
}

%Proto.ValveStateResponse{
  key: 7101, position: 0.0, current_operation: :VALVE_OPERATION_IDLE
}
```

## WaterHeater

HVAC's sibling for water heaters. Similar in shape to `Climate` but
uses a **bitmask `has_fields` integer** on the command instead of
individual `has_*` booleans.

| Struct | Purpose |
|--------|---------|
| `ListEntitiesWaterHeaterResponse` | Advertisement |
| `WaterHeaterStateResponse` | State |
| `WaterHeaterCommandRequest` | Command (uses `has_fields` bitmask) |

Advertisement: `min_temperature`, `max_temperature`,
`target_temperature_step`, `supported_modes` (list of
`Espex.Proto.WaterHeaterMode` atoms: `:WATER_HEATER_MODE_OFF`,
`:WATER_HEATER_MODE_ECO`, `:WATER_HEATER_MODE_ELECTRIC`,
`:WATER_HEATER_MODE_PERFORMANCE`, `:WATER_HEATER_MODE_HIGH_DEMAND`,
`:WATER_HEATER_MODE_HEAT_PUMP`, `:WATER_HEATER_MODE_GAS`),
`supported_features` (bitmask).

Command `has_fields` is a bitmask — see
`Espex.Proto.WaterHeaterCommandHasField` for the bit positions
(`..._HAS_MODE = 1`, `..._HAS_TARGET_TEMPERATURE = 2`, `..._HAS_STATE = 4`,
and so on). Unpack by AND-ing rather than checking individual booleans:

```elixir
import Bitwise

def handle_command(%Proto.WaterHeaterCommandRequest{key: @wh} = cmd) do
  if (cmd.has_fields &&& 1) != 0, do: MyApp.WH.set_mode(cmd.mode)
  if (cmd.has_fields &&& 2) != 0, do: MyApp.WH.set_target(cmd.target_temperature)
  :ok
end
```
