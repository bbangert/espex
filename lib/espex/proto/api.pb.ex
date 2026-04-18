defmodule Espex.Proto.SerialProxyPortType do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :SERIAL_PROXY_PORT_TYPE_TTL, 0
  field :SERIAL_PROXY_PORT_TYPE_RS232, 1
  field :SERIAL_PROXY_PORT_TYPE_RS485, 2
end

defmodule Espex.Proto.EntityCategory do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :ENTITY_CATEGORY_NONE, 0
  field :ENTITY_CATEGORY_CONFIG, 1
  field :ENTITY_CATEGORY_DIAGNOSTIC, 2
end

defmodule Espex.Proto.LegacyCoverState do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :LEGACY_COVER_STATE_OPEN, 0
  field :LEGACY_COVER_STATE_CLOSED, 1
end

defmodule Espex.Proto.CoverOperation do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :COVER_OPERATION_IDLE, 0
  field :COVER_OPERATION_IS_OPENING, 1
  field :COVER_OPERATION_IS_CLOSING, 2
end

defmodule Espex.Proto.LegacyCoverCommand do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :LEGACY_COVER_COMMAND_OPEN, 0
  field :LEGACY_COVER_COMMAND_CLOSE, 1
  field :LEGACY_COVER_COMMAND_STOP, 2
end

defmodule Espex.Proto.FanSpeed do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :FAN_SPEED_LOW, 0
  field :FAN_SPEED_MEDIUM, 1
  field :FAN_SPEED_HIGH, 2
end

defmodule Espex.Proto.FanDirection do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :FAN_DIRECTION_FORWARD, 0
  field :FAN_DIRECTION_REVERSE, 1
end

defmodule Espex.Proto.ColorMode do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :COLOR_MODE_UNKNOWN, 0
  field :COLOR_MODE_ON_OFF, 1
  field :COLOR_MODE_LEGACY_BRIGHTNESS, 2
  field :COLOR_MODE_BRIGHTNESS, 3
  field :COLOR_MODE_WHITE, 7
  field :COLOR_MODE_COLOR_TEMPERATURE, 11
  field :COLOR_MODE_COLD_WARM_WHITE, 19
  field :COLOR_MODE_RGB, 35
  field :COLOR_MODE_RGB_WHITE, 39
  field :COLOR_MODE_RGB_COLOR_TEMPERATURE, 47
  field :COLOR_MODE_RGB_COLD_WARM_WHITE, 51
end

defmodule Espex.Proto.SensorStateClass do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :STATE_CLASS_NONE, 0
  field :STATE_CLASS_MEASUREMENT, 1
  field :STATE_CLASS_TOTAL_INCREASING, 2
  field :STATE_CLASS_TOTAL, 3
  field :STATE_CLASS_MEASUREMENT_ANGLE, 4
end

defmodule Espex.Proto.SensorLastResetType do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :LAST_RESET_NONE, 0
  field :LAST_RESET_NEVER, 1
  field :LAST_RESET_AUTO, 2
end

defmodule Espex.Proto.LogLevel do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :LOG_LEVEL_NONE, 0
  field :LOG_LEVEL_ERROR, 1
  field :LOG_LEVEL_WARN, 2
  field :LOG_LEVEL_INFO, 3
  field :LOG_LEVEL_CONFIG, 4
  field :LOG_LEVEL_DEBUG, 5
  field :LOG_LEVEL_VERBOSE, 6
  field :LOG_LEVEL_VERY_VERBOSE, 7
end

defmodule Espex.Proto.ServiceArgType do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :SERVICE_ARG_TYPE_BOOL, 0
  field :SERVICE_ARG_TYPE_INT, 1
  field :SERVICE_ARG_TYPE_FLOAT, 2
  field :SERVICE_ARG_TYPE_STRING, 3
  field :SERVICE_ARG_TYPE_BOOL_ARRAY, 4
  field :SERVICE_ARG_TYPE_INT_ARRAY, 5
  field :SERVICE_ARG_TYPE_FLOAT_ARRAY, 6
  field :SERVICE_ARG_TYPE_STRING_ARRAY, 7
end

defmodule Espex.Proto.SupportsResponseType do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :SUPPORTS_RESPONSE_NONE, 0
  field :SUPPORTS_RESPONSE_OPTIONAL, 1
  field :SUPPORTS_RESPONSE_ONLY, 2
  field :SUPPORTS_RESPONSE_STATUS, 100
end

defmodule Espex.Proto.ClimateMode do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :CLIMATE_MODE_OFF, 0
  field :CLIMATE_MODE_HEAT_COOL, 1
  field :CLIMATE_MODE_COOL, 2
  field :CLIMATE_MODE_HEAT, 3
  field :CLIMATE_MODE_FAN_ONLY, 4
  field :CLIMATE_MODE_DRY, 5
  field :CLIMATE_MODE_AUTO, 6
end

defmodule Espex.Proto.ClimateFanMode do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :CLIMATE_FAN_ON, 0
  field :CLIMATE_FAN_OFF, 1
  field :CLIMATE_FAN_AUTO, 2
  field :CLIMATE_FAN_LOW, 3
  field :CLIMATE_FAN_MEDIUM, 4
  field :CLIMATE_FAN_HIGH, 5
  field :CLIMATE_FAN_MIDDLE, 6
  field :CLIMATE_FAN_FOCUS, 7
  field :CLIMATE_FAN_DIFFUSE, 8
  field :CLIMATE_FAN_QUIET, 9
end

defmodule Espex.Proto.ClimateSwingMode do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :CLIMATE_SWING_OFF, 0
  field :CLIMATE_SWING_BOTH, 1
  field :CLIMATE_SWING_VERTICAL, 2
  field :CLIMATE_SWING_HORIZONTAL, 3
end

defmodule Espex.Proto.ClimateAction do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :CLIMATE_ACTION_OFF, 0
  field :CLIMATE_ACTION_COOLING, 2
  field :CLIMATE_ACTION_HEATING, 3
  field :CLIMATE_ACTION_IDLE, 4
  field :CLIMATE_ACTION_DRYING, 5
  field :CLIMATE_ACTION_FAN, 6
end

defmodule Espex.Proto.ClimatePreset do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :CLIMATE_PRESET_NONE, 0
  field :CLIMATE_PRESET_HOME, 1
  field :CLIMATE_PRESET_AWAY, 2
  field :CLIMATE_PRESET_BOOST, 3
  field :CLIMATE_PRESET_COMFORT, 4
  field :CLIMATE_PRESET_ECO, 5
  field :CLIMATE_PRESET_SLEEP, 6
  field :CLIMATE_PRESET_ACTIVITY, 7
end

defmodule Espex.Proto.WaterHeaterMode do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :WATER_HEATER_MODE_OFF, 0
  field :WATER_HEATER_MODE_ECO, 1
  field :WATER_HEATER_MODE_ELECTRIC, 2
  field :WATER_HEATER_MODE_PERFORMANCE, 3
  field :WATER_HEATER_MODE_HIGH_DEMAND, 4
  field :WATER_HEATER_MODE_HEAT_PUMP, 5
  field :WATER_HEATER_MODE_GAS, 6
end

defmodule Espex.Proto.WaterHeaterCommandHasField do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :WATER_HEATER_COMMAND_HAS_NONE, 0
  field :WATER_HEATER_COMMAND_HAS_MODE, 1
  field :WATER_HEATER_COMMAND_HAS_TARGET_TEMPERATURE, 2
  field :WATER_HEATER_COMMAND_HAS_STATE, 4
  field :WATER_HEATER_COMMAND_HAS_TARGET_TEMPERATURE_LOW, 8
  field :WATER_HEATER_COMMAND_HAS_TARGET_TEMPERATURE_HIGH, 16
  field :WATER_HEATER_COMMAND_HAS_ON_STATE, 32
  field :WATER_HEATER_COMMAND_HAS_AWAY_STATE, 64
end

defmodule Espex.Proto.NumberMode do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :NUMBER_MODE_AUTO, 0
  field :NUMBER_MODE_BOX, 1
  field :NUMBER_MODE_SLIDER, 2
end

defmodule Espex.Proto.LockState do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :LOCK_STATE_NONE, 0
  field :LOCK_STATE_LOCKED, 1
  field :LOCK_STATE_UNLOCKED, 2
  field :LOCK_STATE_JAMMED, 3
  field :LOCK_STATE_LOCKING, 4
  field :LOCK_STATE_UNLOCKING, 5
end

defmodule Espex.Proto.LockCommand do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :LOCK_UNLOCK, 0
  field :LOCK_LOCK, 1
  field :LOCK_OPEN, 2
end

defmodule Espex.Proto.MediaPlayerState do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :MEDIA_PLAYER_STATE_NONE, 0
  field :MEDIA_PLAYER_STATE_IDLE, 1
  field :MEDIA_PLAYER_STATE_PLAYING, 2
  field :MEDIA_PLAYER_STATE_PAUSED, 3
  field :MEDIA_PLAYER_STATE_ANNOUNCING, 4
  field :MEDIA_PLAYER_STATE_OFF, 5
  field :MEDIA_PLAYER_STATE_ON, 6
end

defmodule Espex.Proto.MediaPlayerCommand do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :MEDIA_PLAYER_COMMAND_PLAY, 0
  field :MEDIA_PLAYER_COMMAND_PAUSE, 1
  field :MEDIA_PLAYER_COMMAND_STOP, 2
  field :MEDIA_PLAYER_COMMAND_MUTE, 3
  field :MEDIA_PLAYER_COMMAND_UNMUTE, 4
  field :MEDIA_PLAYER_COMMAND_TOGGLE, 5
  field :MEDIA_PLAYER_COMMAND_VOLUME_UP, 6
  field :MEDIA_PLAYER_COMMAND_VOLUME_DOWN, 7
  field :MEDIA_PLAYER_COMMAND_ENQUEUE, 8
  field :MEDIA_PLAYER_COMMAND_REPEAT_ONE, 9
  field :MEDIA_PLAYER_COMMAND_REPEAT_OFF, 10
  field :MEDIA_PLAYER_COMMAND_CLEAR_PLAYLIST, 11
  field :MEDIA_PLAYER_COMMAND_TURN_ON, 12
  field :MEDIA_PLAYER_COMMAND_TURN_OFF, 13
end

defmodule Espex.Proto.MediaPlayerFormatPurpose do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :MEDIA_PLAYER_FORMAT_PURPOSE_DEFAULT, 0
  field :MEDIA_PLAYER_FORMAT_PURPOSE_ANNOUNCEMENT, 1
end

defmodule Espex.Proto.BluetoothDeviceRequestType do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT, 0
  field :BLUETOOTH_DEVICE_REQUEST_TYPE_DISCONNECT, 1
  field :BLUETOOTH_DEVICE_REQUEST_TYPE_PAIR, 2
  field :BLUETOOTH_DEVICE_REQUEST_TYPE_UNPAIR, 3
  field :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITH_CACHE, 4
  field :BLUETOOTH_DEVICE_REQUEST_TYPE_CONNECT_V3_WITHOUT_CACHE, 5
  field :BLUETOOTH_DEVICE_REQUEST_TYPE_CLEAR_CACHE, 6
end

defmodule Espex.Proto.BluetoothScannerState do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :BLUETOOTH_SCANNER_STATE_IDLE, 0
  field :BLUETOOTH_SCANNER_STATE_STARTING, 1
  field :BLUETOOTH_SCANNER_STATE_RUNNING, 2
  field :BLUETOOTH_SCANNER_STATE_FAILED, 3
  field :BLUETOOTH_SCANNER_STATE_STOPPING, 4
  field :BLUETOOTH_SCANNER_STATE_STOPPED, 5
end

defmodule Espex.Proto.BluetoothScannerMode do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :BLUETOOTH_SCANNER_MODE_PASSIVE, 0
  field :BLUETOOTH_SCANNER_MODE_ACTIVE, 1
end

defmodule Espex.Proto.VoiceAssistantSubscribeFlag do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :VOICE_ASSISTANT_SUBSCRIBE_NONE, 0
  field :VOICE_ASSISTANT_SUBSCRIBE_API_AUDIO, 1
end

defmodule Espex.Proto.VoiceAssistantRequestFlag do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :VOICE_ASSISTANT_REQUEST_NONE, 0
  field :VOICE_ASSISTANT_REQUEST_USE_VAD, 1
  field :VOICE_ASSISTANT_REQUEST_USE_WAKE_WORD, 2
end

defmodule Espex.Proto.VoiceAssistantEvent do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :VOICE_ASSISTANT_ERROR, 0
  field :VOICE_ASSISTANT_RUN_START, 1
  field :VOICE_ASSISTANT_RUN_END, 2
  field :VOICE_ASSISTANT_STT_START, 3
  field :VOICE_ASSISTANT_STT_END, 4
  field :VOICE_ASSISTANT_INTENT_START, 5
  field :VOICE_ASSISTANT_INTENT_END, 6
  field :VOICE_ASSISTANT_TTS_START, 7
  field :VOICE_ASSISTANT_TTS_END, 8
  field :VOICE_ASSISTANT_WAKE_WORD_START, 9
  field :VOICE_ASSISTANT_WAKE_WORD_END, 10
  field :VOICE_ASSISTANT_STT_VAD_START, 11
  field :VOICE_ASSISTANT_STT_VAD_END, 12
  field :VOICE_ASSISTANT_TTS_STREAM_START, 98
  field :VOICE_ASSISTANT_TTS_STREAM_END, 99
  field :VOICE_ASSISTANT_INTENT_PROGRESS, 100
end

defmodule Espex.Proto.VoiceAssistantTimerEvent do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :VOICE_ASSISTANT_TIMER_STARTED, 0
  field :VOICE_ASSISTANT_TIMER_UPDATED, 1
  field :VOICE_ASSISTANT_TIMER_CANCELLED, 2
  field :VOICE_ASSISTANT_TIMER_FINISHED, 3
end

defmodule Espex.Proto.AlarmControlPanelState do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :ALARM_STATE_DISARMED, 0
  field :ALARM_STATE_ARMED_HOME, 1
  field :ALARM_STATE_ARMED_AWAY, 2
  field :ALARM_STATE_ARMED_NIGHT, 3
  field :ALARM_STATE_ARMED_VACATION, 4
  field :ALARM_STATE_ARMED_CUSTOM_BYPASS, 5
  field :ALARM_STATE_PENDING, 6
  field :ALARM_STATE_ARMING, 7
  field :ALARM_STATE_DISARMING, 8
  field :ALARM_STATE_TRIGGERED, 9
end

defmodule Espex.Proto.AlarmControlPanelStateCommand do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :ALARM_CONTROL_PANEL_DISARM, 0
  field :ALARM_CONTROL_PANEL_ARM_AWAY, 1
  field :ALARM_CONTROL_PANEL_ARM_HOME, 2
  field :ALARM_CONTROL_PANEL_ARM_NIGHT, 3
  field :ALARM_CONTROL_PANEL_ARM_VACATION, 4
  field :ALARM_CONTROL_PANEL_ARM_CUSTOM_BYPASS, 5
  field :ALARM_CONTROL_PANEL_TRIGGER, 6
end

defmodule Espex.Proto.TextMode do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :TEXT_MODE_TEXT, 0
  field :TEXT_MODE_PASSWORD, 1
end

defmodule Espex.Proto.ValveOperation do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :VALVE_OPERATION_IDLE, 0
  field :VALVE_OPERATION_IS_OPENING, 1
  field :VALVE_OPERATION_IS_CLOSING, 2
end

defmodule Espex.Proto.UpdateCommand do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :UPDATE_COMMAND_NONE, 0
  field :UPDATE_COMMAND_UPDATE, 1
  field :UPDATE_COMMAND_CHECK, 2
end

defmodule Espex.Proto.ZWaveProxyRequestType do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE, 0
  field :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE, 1
  field :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE, 2
end

defmodule Espex.Proto.SerialProxyParity do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :SERIAL_PROXY_PARITY_NONE, 0
  field :SERIAL_PROXY_PARITY_EVEN, 1
  field :SERIAL_PROXY_PARITY_ODD, 2
end

defmodule Espex.Proto.SerialProxyRequestType do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :SERIAL_PROXY_REQUEST_TYPE_FLUSH, 0
end

defmodule Espex.Proto.HelloRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :client_info, 1, type: :string, json_name: "clientInfo"
  field :api_version_major, 2, type: :uint32, json_name: "apiVersionMajor"
  field :api_version_minor, 3, type: :uint32, json_name: "apiVersionMinor"
end

defmodule Espex.Proto.HelloResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :api_version_major, 1, type: :uint32, json_name: "apiVersionMajor"
  field :api_version_minor, 2, type: :uint32, json_name: "apiVersionMinor"
  field :server_info, 3, type: :string, json_name: "serverInfo"
  field :name, 4, type: :string
end

defmodule Espex.Proto.AuthenticationRequest do
  @moduledoc false
  use Protobuf, deprecated: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :password, 1, type: :string
end

defmodule Espex.Proto.AuthenticationResponse do
  @moduledoc false
  use Protobuf, deprecated: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :invalid_password, 1, type: :bool, json_name: "invalidPassword"
end

defmodule Espex.Proto.DisconnectRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.DisconnectResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.PingRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.PingResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.DeviceInfoRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.AreaInfo do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :area_id, 1, type: :uint32, json_name: "areaId"
  field :name, 2, type: :string
end

defmodule Espex.Proto.DeviceInfo do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :device_id, 1, type: :uint32, json_name: "deviceId"
  field :name, 2, type: :string
  field :area_id, 3, type: :uint32, json_name: "areaId"
end

defmodule Espex.Proto.SerialProxyInfo do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :name, 1, type: :string
  field :port_type, 2, type: Espex.Proto.SerialProxyPortType, json_name: "portType", enum: true
end

defmodule Espex.Proto.DeviceInfoResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :uses_password, 1, type: :bool, json_name: "usesPassword", deprecated: true
  field :name, 2, type: :string
  field :mac_address, 3, type: :string, json_name: "macAddress"
  field :esphome_version, 4, type: :string, json_name: "esphomeVersion"
  field :compilation_time, 5, type: :string, json_name: "compilationTime"
  field :model, 6, type: :string
  field :has_deep_sleep, 7, type: :bool, json_name: "hasDeepSleep", deprecated: false
  field :project_name, 8, type: :string, json_name: "projectName", deprecated: false
  field :project_version, 9, type: :string, json_name: "projectVersion", deprecated: false
  field :webserver_port, 10, type: :uint32, json_name: "webserverPort", deprecated: false

  field :legacy_bluetooth_proxy_version, 11,
    type: :uint32,
    json_name: "legacyBluetoothProxyVersion",
    deprecated: true

  field :bluetooth_proxy_feature_flags, 15,
    type: :uint32,
    json_name: "bluetoothProxyFeatureFlags",
    deprecated: false

  field :manufacturer, 12, type: :string
  field :friendly_name, 13, type: :string, json_name: "friendlyName"

  field :legacy_voice_assistant_version, 14,
    type: :uint32,
    json_name: "legacyVoiceAssistantVersion",
    deprecated: true

  field :voice_assistant_feature_flags, 17,
    type: :uint32,
    json_name: "voiceAssistantFeatureFlags",
    deprecated: false

  field :suggested_area, 16, type: :string, json_name: "suggestedArea", deprecated: false

  field :bluetooth_mac_address, 18,
    type: :string,
    json_name: "bluetoothMacAddress",
    deprecated: false

  field :api_encryption_supported, 19,
    type: :bool,
    json_name: "apiEncryptionSupported",
    deprecated: false

  field :devices, 20, repeated: true, type: Espex.Proto.DeviceInfo, deprecated: false
  field :areas, 21, repeated: true, type: Espex.Proto.AreaInfo, deprecated: false
  field :area, 22, type: Espex.Proto.AreaInfo, deprecated: false

  field :zwave_proxy_feature_flags, 23,
    type: :uint32,
    json_name: "zwaveProxyFeatureFlags",
    deprecated: false

  field :zwave_home_id, 24, type: :uint32, json_name: "zwaveHomeId", deprecated: false

  field :serial_proxies, 25,
    repeated: true,
    type: Espex.Proto.SerialProxyInfo,
    json_name: "serialProxies",
    deprecated: false
end

defmodule Espex.Proto.ListEntitiesRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.ListEntitiesDoneResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.SubscribeStatesRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.ListEntitiesBinarySensorResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :device_class, 5, type: :string, json_name: "deviceClass"
  field :is_status_binary_sensor, 6, type: :bool, json_name: "isStatusBinarySensor"
  field :disabled_by_default, 7, type: :bool, json_name: "disabledByDefault"
  field :icon, 8, type: :string, deprecated: false

  field :entity_category, 9,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 10, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.BinarySensorStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :bool
  field :missing_state, 3, type: :bool, json_name: "missingState"
  field :device_id, 4, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesCoverResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :assumed_state, 5, type: :bool, json_name: "assumedState"
  field :supports_position, 6, type: :bool, json_name: "supportsPosition"
  field :supports_tilt, 7, type: :bool, json_name: "supportsTilt"
  field :device_class, 8, type: :string, json_name: "deviceClass"
  field :disabled_by_default, 9, type: :bool, json_name: "disabledByDefault"
  field :icon, 10, type: :string, deprecated: false

  field :entity_category, 11,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :supports_stop, 12, type: :bool, json_name: "supportsStop"
  field :device_id, 13, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.CoverStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32

  field :legacy_state, 2,
    type: Espex.Proto.LegacyCoverState,
    json_name: "legacyState",
    enum: true,
    deprecated: true

  field :position, 3, type: :float
  field :tilt, 4, type: :float

  field :current_operation, 5,
    type: Espex.Proto.CoverOperation,
    json_name: "currentOperation",
    enum: true

  field :device_id, 6, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.CoverCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :has_legacy_command, 2, type: :bool, json_name: "hasLegacyCommand", deprecated: true

  field :legacy_command, 3,
    type: Espex.Proto.LegacyCoverCommand,
    json_name: "legacyCommand",
    enum: true,
    deprecated: true

  field :has_position, 4, type: :bool, json_name: "hasPosition"
  field :position, 5, type: :float
  field :has_tilt, 6, type: :bool, json_name: "hasTilt"
  field :tilt, 7, type: :float
  field :stop, 8, type: :bool
  field :device_id, 9, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesFanResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :supports_oscillation, 5, type: :bool, json_name: "supportsOscillation"
  field :supports_speed, 6, type: :bool, json_name: "supportsSpeed"
  field :supports_direction, 7, type: :bool, json_name: "supportsDirection"
  field :supported_speed_count, 8, type: :int32, json_name: "supportedSpeedCount"
  field :disabled_by_default, 9, type: :bool, json_name: "disabledByDefault"
  field :icon, 10, type: :string, deprecated: false

  field :entity_category, 11,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :supported_preset_modes, 12,
    repeated: true,
    type: :string,
    json_name: "supportedPresetModes",
    deprecated: false

  field :device_id, 13, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.FanStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :bool
  field :oscillating, 3, type: :bool
  field :speed, 4, type: Espex.Proto.FanSpeed, enum: true, deprecated: true
  field :direction, 5, type: Espex.Proto.FanDirection, enum: true
  field :speed_level, 6, type: :int32, json_name: "speedLevel"
  field :preset_mode, 7, type: :string, json_name: "presetMode"
  field :device_id, 8, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.FanCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :has_state, 2, type: :bool, json_name: "hasState"
  field :state, 3, type: :bool
  field :has_speed, 4, type: :bool, json_name: "hasSpeed", deprecated: true
  field :speed, 5, type: Espex.Proto.FanSpeed, enum: true, deprecated: true
  field :has_oscillating, 6, type: :bool, json_name: "hasOscillating"
  field :oscillating, 7, type: :bool
  field :has_direction, 8, type: :bool, json_name: "hasDirection"
  field :direction, 9, type: Espex.Proto.FanDirection, enum: true
  field :has_speed_level, 10, type: :bool, json_name: "hasSpeedLevel"
  field :speed_level, 11, type: :int32, json_name: "speedLevel"
  field :has_preset_mode, 12, type: :bool, json_name: "hasPresetMode"
  field :preset_mode, 13, type: :string, json_name: "presetMode"
  field :device_id, 14, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesLightResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string

  field :supported_color_modes, 12,
    repeated: true,
    type: Espex.Proto.ColorMode,
    json_name: "supportedColorModes",
    enum: true,
    deprecated: false

  field :legacy_supports_brightness, 5,
    type: :bool,
    json_name: "legacySupportsBrightness",
    deprecated: true

  field :legacy_supports_rgb, 6, type: :bool, json_name: "legacySupportsRgb", deprecated: true

  field :legacy_supports_white_value, 7,
    type: :bool,
    json_name: "legacySupportsWhiteValue",
    deprecated: true

  field :legacy_supports_color_temperature, 8,
    type: :bool,
    json_name: "legacySupportsColorTemperature",
    deprecated: true

  field :min_mireds, 9, type: :float, json_name: "minMireds"
  field :max_mireds, 10, type: :float, json_name: "maxMireds"
  field :effects, 11, repeated: true, type: :string, deprecated: false
  field :disabled_by_default, 13, type: :bool, json_name: "disabledByDefault"
  field :icon, 14, type: :string, deprecated: false

  field :entity_category, 15,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 16, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.LightStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :bool
  field :brightness, 3, type: :float
  field :color_mode, 11, type: Espex.Proto.ColorMode, json_name: "colorMode", enum: true
  field :color_brightness, 10, type: :float, json_name: "colorBrightness"
  field :red, 4, type: :float
  field :green, 5, type: :float
  field :blue, 6, type: :float
  field :white, 7, type: :float
  field :color_temperature, 8, type: :float, json_name: "colorTemperature"
  field :cold_white, 12, type: :float, json_name: "coldWhite"
  field :warm_white, 13, type: :float, json_name: "warmWhite"
  field :effect, 9, type: :string
  field :device_id, 14, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.LightCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :has_state, 2, type: :bool, json_name: "hasState"
  field :state, 3, type: :bool
  field :has_brightness, 4, type: :bool, json_name: "hasBrightness"
  field :brightness, 5, type: :float
  field :has_color_mode, 22, type: :bool, json_name: "hasColorMode"
  field :color_mode, 23, type: Espex.Proto.ColorMode, json_name: "colorMode", enum: true
  field :has_color_brightness, 20, type: :bool, json_name: "hasColorBrightness"
  field :color_brightness, 21, type: :float, json_name: "colorBrightness"
  field :has_rgb, 6, type: :bool, json_name: "hasRgb"
  field :red, 7, type: :float
  field :green, 8, type: :float
  field :blue, 9, type: :float
  field :has_white, 10, type: :bool, json_name: "hasWhite"
  field :white, 11, type: :float
  field :has_color_temperature, 12, type: :bool, json_name: "hasColorTemperature"
  field :color_temperature, 13, type: :float, json_name: "colorTemperature"
  field :has_cold_white, 24, type: :bool, json_name: "hasColdWhite"
  field :cold_white, 25, type: :float, json_name: "coldWhite"
  field :has_warm_white, 26, type: :bool, json_name: "hasWarmWhite"
  field :warm_white, 27, type: :float, json_name: "warmWhite"
  field :has_transition_length, 14, type: :bool, json_name: "hasTransitionLength"
  field :transition_length, 15, type: :uint32, json_name: "transitionLength"
  field :has_flash_length, 16, type: :bool, json_name: "hasFlashLength"
  field :flash_length, 17, type: :uint32, json_name: "flashLength"
  field :has_effect, 18, type: :bool, json_name: "hasEffect"
  field :effect, 19, type: :string
  field :device_id, 28, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesSensorResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :unit_of_measurement, 6, type: :string, json_name: "unitOfMeasurement"
  field :accuracy_decimals, 7, type: :int32, json_name: "accuracyDecimals"
  field :force_update, 8, type: :bool, json_name: "forceUpdate"
  field :device_class, 9, type: :string, json_name: "deviceClass"
  field :state_class, 10, type: Espex.Proto.SensorStateClass, json_name: "stateClass", enum: true

  field :legacy_last_reset_type, 11,
    type: Espex.Proto.SensorLastResetType,
    json_name: "legacyLastResetType",
    enum: true,
    deprecated: true

  field :disabled_by_default, 12, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 13,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 14, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.SensorStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :float
  field :missing_state, 3, type: :bool, json_name: "missingState"
  field :device_id, 4, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesSwitchResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :assumed_state, 6, type: :bool, json_name: "assumedState"
  field :disabled_by_default, 7, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 8,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_class, 9, type: :string, json_name: "deviceClass"
  field :device_id, 10, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.SwitchStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :bool
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.SwitchCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :bool
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesTextSensorResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_class, 8, type: :string, json_name: "deviceClass"
  field :device_id, 9, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.TextSensorStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :string
  field :missing_state, 3, type: :bool, json_name: "missingState"
  field :device_id, 4, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.SubscribeLogsRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :level, 1, type: Espex.Proto.LogLevel, enum: true
  field :dump_config, 2, type: :bool, json_name: "dumpConfig"
end

defmodule Espex.Proto.SubscribeLogsResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :level, 1, type: Espex.Proto.LogLevel, enum: true
  field :message, 3, type: :bytes
end

defmodule Espex.Proto.NoiseEncryptionSetKeyRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :bytes
end

defmodule Espex.Proto.NoiseEncryptionSetKeyResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :success, 1, type: :bool
end

defmodule Espex.Proto.SubscribeHomeassistantServicesRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.HomeassistantServiceMap do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Espex.Proto.HomeassistantActionRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :service, 1, type: :string
  field :data, 2, repeated: true, type: Espex.Proto.HomeassistantServiceMap, deprecated: false

  field :data_template, 3,
    repeated: true,
    type: Espex.Proto.HomeassistantServiceMap,
    json_name: "dataTemplate",
    deprecated: false

  field :variables, 4,
    repeated: true,
    type: Espex.Proto.HomeassistantServiceMap,
    deprecated: false

  field :is_event, 5, type: :bool, json_name: "isEvent"
  field :call_id, 6, type: :uint32, json_name: "callId", deprecated: false
  field :wants_response, 7, type: :bool, json_name: "wantsResponse", deprecated: false
  field :response_template, 8, type: :string, json_name: "responseTemplate", deprecated: false
end

defmodule Espex.Proto.HomeassistantActionResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :call_id, 1, type: :uint32, json_name: "callId"
  field :success, 2, type: :bool
  field :error_message, 3, type: :string, json_name: "errorMessage"
  field :response_data, 4, type: :bytes, json_name: "responseData", deprecated: false
end

defmodule Espex.Proto.SubscribeHomeAssistantStatesRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.SubscribeHomeAssistantStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :entity_id, 1, type: :string, json_name: "entityId"
  field :attribute, 2, type: :string
  field :once, 3, type: :bool
end

defmodule Espex.Proto.HomeAssistantStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :entity_id, 1, type: :string, json_name: "entityId"
  field :state, 2, type: :string
  field :attribute, 3, type: :string
end

defmodule Espex.Proto.GetTimeRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.GetTimeResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :epoch_seconds, 1, type: :fixed32, json_name: "epochSeconds"
  field :timezone, 2, type: :string
end

defmodule Espex.Proto.ListEntitiesServicesArgument do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :name, 1, type: :string
  field :type, 2, type: Espex.Proto.ServiceArgType, enum: true
end

defmodule Espex.Proto.ListEntitiesServicesResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :name, 1, type: :string
  field :key, 2, type: :fixed32

  field :args, 3,
    repeated: true,
    type: Espex.Proto.ListEntitiesServicesArgument,
    deprecated: false

  field :supports_response, 4,
    type: Espex.Proto.SupportsResponseType,
    json_name: "supportsResponse",
    enum: true
end

defmodule Espex.Proto.ExecuteServiceArgument do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :bool_, 1, type: :bool, json_name: "bool"
  field :legacy_int, 2, type: :int32, json_name: "legacyInt"
  field :float_, 3, type: :float, json_name: "float"
  field :string_, 4, type: :string, json_name: "string"
  field :int_, 5, type: :sint32, json_name: "int"

  field :bool_array, 6,
    repeated: true,
    type: :bool,
    json_name: "boolArray",
    packed: false,
    deprecated: false

  field :int_array, 7,
    repeated: true,
    type: :sint32,
    json_name: "intArray",
    packed: false,
    deprecated: false

  field :float_array, 8,
    repeated: true,
    type: :float,
    json_name: "floatArray",
    packed: false,
    deprecated: false

  field :string_array, 9,
    repeated: true,
    type: :string,
    json_name: "stringArray",
    deprecated: false
end

defmodule Espex.Proto.ExecuteServiceRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :args, 2, repeated: true, type: Espex.Proto.ExecuteServiceArgument, deprecated: false
  field :call_id, 3, type: :uint32, json_name: "callId", deprecated: false
  field :return_response, 4, type: :bool, json_name: "returnResponse", deprecated: false
end

defmodule Espex.Proto.ExecuteServiceResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :call_id, 1, type: :uint32, json_name: "callId"
  field :success, 2, type: :bool
  field :error_message, 3, type: :string, json_name: "errorMessage"
  field :response_data, 4, type: :bytes, json_name: "responseData", deprecated: false
end

defmodule Espex.Proto.ListEntitiesCameraResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :disabled_by_default, 5, type: :bool, json_name: "disabledByDefault"
  field :icon, 6, type: :string, deprecated: false

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 8, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.CameraImageResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :data, 2, type: :bytes
  field :done, 3, type: :bool
  field :device_id, 4, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.CameraImageRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :single, 1, type: :bool
  field :stream, 2, type: :bool
end

defmodule Espex.Proto.ListEntitiesClimateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :supports_current_temperature, 5, type: :bool, json_name: "supportsCurrentTemperature"

  field :supports_two_point_target_temperature, 6,
    type: :bool,
    json_name: "supportsTwoPointTargetTemperature"

  field :supported_modes, 7,
    repeated: true,
    type: Espex.Proto.ClimateMode,
    json_name: "supportedModes",
    enum: true,
    deprecated: false

  field :visual_min_temperature, 8, type: :float, json_name: "visualMinTemperature"
  field :visual_max_temperature, 9, type: :float, json_name: "visualMaxTemperature"

  field :visual_target_temperature_step, 10,
    type: :float,
    json_name: "visualTargetTemperatureStep"

  field :legacy_supports_away, 11, type: :bool, json_name: "legacySupportsAway", deprecated: true
  field :supports_action, 12, type: :bool, json_name: "supportsAction"

  field :supported_fan_modes, 13,
    repeated: true,
    type: Espex.Proto.ClimateFanMode,
    json_name: "supportedFanModes",
    enum: true,
    deprecated: false

  field :supported_swing_modes, 14,
    repeated: true,
    type: Espex.Proto.ClimateSwingMode,
    json_name: "supportedSwingModes",
    enum: true,
    deprecated: false

  field :supported_custom_fan_modes, 15,
    repeated: true,
    type: :string,
    json_name: "supportedCustomFanModes",
    deprecated: false

  field :supported_presets, 16,
    repeated: true,
    type: Espex.Proto.ClimatePreset,
    json_name: "supportedPresets",
    enum: true,
    deprecated: false

  field :supported_custom_presets, 17,
    repeated: true,
    type: :string,
    json_name: "supportedCustomPresets",
    deprecated: false

  field :disabled_by_default, 18, type: :bool, json_name: "disabledByDefault"
  field :icon, 19, type: :string, deprecated: false

  field :entity_category, 20,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :visual_current_temperature_step, 21,
    type: :float,
    json_name: "visualCurrentTemperatureStep"

  field :supports_current_humidity, 22, type: :bool, json_name: "supportsCurrentHumidity"
  field :supports_target_humidity, 23, type: :bool, json_name: "supportsTargetHumidity"
  field :visual_min_humidity, 24, type: :float, json_name: "visualMinHumidity"
  field :visual_max_humidity, 25, type: :float, json_name: "visualMaxHumidity"
  field :device_id, 26, type: :uint32, json_name: "deviceId", deprecated: false
  field :feature_flags, 27, type: :uint32, json_name: "featureFlags"
end

defmodule Espex.Proto.ClimateStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :mode, 2, type: Espex.Proto.ClimateMode, enum: true
  field :current_temperature, 3, type: :float, json_name: "currentTemperature"
  field :target_temperature, 4, type: :float, json_name: "targetTemperature"
  field :target_temperature_low, 5, type: :float, json_name: "targetTemperatureLow"
  field :target_temperature_high, 6, type: :float, json_name: "targetTemperatureHigh"
  field :unused_legacy_away, 7, type: :bool, json_name: "unusedLegacyAway", deprecated: true
  field :action, 8, type: Espex.Proto.ClimateAction, enum: true
  field :fan_mode, 9, type: Espex.Proto.ClimateFanMode, json_name: "fanMode", enum: true
  field :swing_mode, 10, type: Espex.Proto.ClimateSwingMode, json_name: "swingMode", enum: true
  field :custom_fan_mode, 11, type: :string, json_name: "customFanMode"
  field :preset, 12, type: Espex.Proto.ClimatePreset, enum: true
  field :custom_preset, 13, type: :string, json_name: "customPreset"
  field :current_humidity, 14, type: :float, json_name: "currentHumidity"
  field :target_humidity, 15, type: :float, json_name: "targetHumidity"
  field :device_id, 16, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ClimateCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :has_mode, 2, type: :bool, json_name: "hasMode"
  field :mode, 3, type: Espex.Proto.ClimateMode, enum: true
  field :has_target_temperature, 4, type: :bool, json_name: "hasTargetTemperature"
  field :target_temperature, 5, type: :float, json_name: "targetTemperature"
  field :has_target_temperature_low, 6, type: :bool, json_name: "hasTargetTemperatureLow"
  field :target_temperature_low, 7, type: :float, json_name: "targetTemperatureLow"
  field :has_target_temperature_high, 8, type: :bool, json_name: "hasTargetTemperatureHigh"
  field :target_temperature_high, 9, type: :float, json_name: "targetTemperatureHigh"

  field :unused_has_legacy_away, 10,
    type: :bool,
    json_name: "unusedHasLegacyAway",
    deprecated: true

  field :unused_legacy_away, 11, type: :bool, json_name: "unusedLegacyAway", deprecated: true
  field :has_fan_mode, 12, type: :bool, json_name: "hasFanMode"
  field :fan_mode, 13, type: Espex.Proto.ClimateFanMode, json_name: "fanMode", enum: true
  field :has_swing_mode, 14, type: :bool, json_name: "hasSwingMode"
  field :swing_mode, 15, type: Espex.Proto.ClimateSwingMode, json_name: "swingMode", enum: true
  field :has_custom_fan_mode, 16, type: :bool, json_name: "hasCustomFanMode"
  field :custom_fan_mode, 17, type: :string, json_name: "customFanMode"
  field :has_preset, 18, type: :bool, json_name: "hasPreset"
  field :preset, 19, type: Espex.Proto.ClimatePreset, enum: true
  field :has_custom_preset, 20, type: :bool, json_name: "hasCustomPreset"
  field :custom_preset, 21, type: :string, json_name: "customPreset"
  field :has_target_humidity, 22, type: :bool, json_name: "hasTargetHumidity"
  field :target_humidity, 23, type: :float, json_name: "targetHumidity"
  field :device_id, 24, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesWaterHeaterResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 4, type: :string, deprecated: false
  field :disabled_by_default, 5, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 6,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 7, type: :uint32, json_name: "deviceId", deprecated: false
  field :min_temperature, 8, type: :float, json_name: "minTemperature"
  field :max_temperature, 9, type: :float, json_name: "maxTemperature"
  field :target_temperature_step, 10, type: :float, json_name: "targetTemperatureStep"

  field :supported_modes, 11,
    repeated: true,
    type: Espex.Proto.WaterHeaterMode,
    json_name: "supportedModes",
    enum: true,
    deprecated: false

  field :supported_features, 12, type: :uint32, json_name: "supportedFeatures"
end

defmodule Espex.Proto.WaterHeaterStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :current_temperature, 2, type: :float, json_name: "currentTemperature"
  field :target_temperature, 3, type: :float, json_name: "targetTemperature"
  field :mode, 4, type: Espex.Proto.WaterHeaterMode, enum: true
  field :device_id, 5, type: :uint32, json_name: "deviceId", deprecated: false
  field :state, 6, type: :uint32
  field :target_temperature_low, 7, type: :float, json_name: "targetTemperatureLow"
  field :target_temperature_high, 8, type: :float, json_name: "targetTemperatureHigh"
end

defmodule Espex.Proto.WaterHeaterCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :has_fields, 2, type: :uint32, json_name: "hasFields"
  field :mode, 3, type: Espex.Proto.WaterHeaterMode, enum: true
  field :target_temperature, 4, type: :float, json_name: "targetTemperature"
  field :device_id, 5, type: :uint32, json_name: "deviceId", deprecated: false
  field :state, 6, type: :uint32
  field :target_temperature_low, 7, type: :float, json_name: "targetTemperatureLow"
  field :target_temperature_high, 8, type: :float, json_name: "targetTemperatureHigh"
end

defmodule Espex.Proto.ListEntitiesNumberResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :min_value, 6, type: :float, json_name: "minValue"
  field :max_value, 7, type: :float, json_name: "maxValue"
  field :step, 8, type: :float
  field :disabled_by_default, 9, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 10,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :unit_of_measurement, 11, type: :string, json_name: "unitOfMeasurement"
  field :mode, 12, type: Espex.Proto.NumberMode, enum: true
  field :device_class, 13, type: :string, json_name: "deviceClass"
  field :device_id, 14, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.NumberStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :float
  field :missing_state, 3, type: :bool, json_name: "missingState"
  field :device_id, 4, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.NumberCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :float
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesSelectResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :options, 6, repeated: true, type: :string, deprecated: false
  field :disabled_by_default, 7, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 8,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 9, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.SelectStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :string
  field :missing_state, 3, type: :bool, json_name: "missingState"
  field :device_id, 4, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.SelectCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :string
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesSirenResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"
  field :tones, 7, repeated: true, type: :string, deprecated: false
  field :supports_duration, 8, type: :bool, json_name: "supportsDuration"
  field :supports_volume, 9, type: :bool, json_name: "supportsVolume"

  field :entity_category, 10,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 11, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.SirenStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :bool
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.SirenCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :has_state, 2, type: :bool, json_name: "hasState"
  field :state, 3, type: :bool
  field :has_tone, 4, type: :bool, json_name: "hasTone"
  field :tone, 5, type: :string
  field :has_duration, 6, type: :bool, json_name: "hasDuration"
  field :duration, 7, type: :uint32
  field :has_volume, 8, type: :bool, json_name: "hasVolume"
  field :volume, 9, type: :float
  field :device_id, 10, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesLockResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :assumed_state, 8, type: :bool, json_name: "assumedState"
  field :supports_open, 9, type: :bool, json_name: "supportsOpen"
  field :requires_code, 10, type: :bool, json_name: "requiresCode"
  field :code_format, 11, type: :string, json_name: "codeFormat"
  field :device_id, 12, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.LockStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: Espex.Proto.LockState, enum: true
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.LockCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :command, 2, type: Espex.Proto.LockCommand, enum: true
  field :has_code, 3, type: :bool, json_name: "hasCode"
  field :code, 4, type: :string
  field :device_id, 5, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesButtonResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_class, 8, type: :string, json_name: "deviceClass"
  field :device_id, 9, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ButtonCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :device_id, 2, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.MediaPlayerSupportedFormat do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :format, 1, type: :string
  field :sample_rate, 2, type: :uint32, json_name: "sampleRate"
  field :num_channels, 3, type: :uint32, json_name: "numChannels"
  field :purpose, 4, type: Espex.Proto.MediaPlayerFormatPurpose, enum: true
  field :sample_bytes, 5, type: :uint32, json_name: "sampleBytes"
end

defmodule Espex.Proto.ListEntitiesMediaPlayerResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :supports_pause, 8, type: :bool, json_name: "supportsPause"

  field :supported_formats, 9,
    repeated: true,
    type: Espex.Proto.MediaPlayerSupportedFormat,
    json_name: "supportedFormats"

  field :device_id, 10, type: :uint32, json_name: "deviceId", deprecated: false
  field :feature_flags, 11, type: :uint32, json_name: "featureFlags"
end

defmodule Espex.Proto.MediaPlayerStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: Espex.Proto.MediaPlayerState, enum: true
  field :volume, 3, type: :float
  field :muted, 4, type: :bool
  field :device_id, 5, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.MediaPlayerCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :has_command, 2, type: :bool, json_name: "hasCommand"
  field :command, 3, type: Espex.Proto.MediaPlayerCommand, enum: true
  field :has_volume, 4, type: :bool, json_name: "hasVolume"
  field :volume, 5, type: :float
  field :has_media_url, 6, type: :bool, json_name: "hasMediaUrl"
  field :media_url, 7, type: :string, json_name: "mediaUrl"
  field :has_announcement, 8, type: :bool, json_name: "hasAnnouncement"
  field :announcement, 9, type: :bool
  field :device_id, 10, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.SubscribeBluetoothLEAdvertisementsRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :flags, 1, type: :uint32
end

defmodule Espex.Proto.BluetoothServiceData do
  @moduledoc false
  use Protobuf, deprecated: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :uuid, 1, type: :string
  field :legacy_data, 2, repeated: true, type: :uint32, json_name: "legacyData", deprecated: true
  field :data, 3, type: :bytes
end

defmodule Espex.Proto.BluetoothLEAdvertisementResponse do
  @moduledoc false
  use Protobuf, deprecated: true, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :name, 2, type: :bytes
  field :rssi, 3, type: :sint32
  field :service_uuids, 4, repeated: true, type: :string, json_name: "serviceUuids"

  field :service_data, 5,
    repeated: true,
    type: Espex.Proto.BluetoothServiceData,
    json_name: "serviceData"

  field :manufacturer_data, 6,
    repeated: true,
    type: Espex.Proto.BluetoothServiceData,
    json_name: "manufacturerData"

  field :address_type, 7, type: :uint32, json_name: "addressType"
end

defmodule Espex.Proto.BluetoothLERawAdvertisement do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :rssi, 2, type: :sint32
  field :address_type, 3, type: :uint32, json_name: "addressType"
  field :data, 4, type: :bytes, deprecated: false
end

defmodule Espex.Proto.BluetoothLERawAdvertisementsResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :advertisements, 1,
    repeated: true,
    type: Espex.Proto.BluetoothLERawAdvertisement,
    deprecated: false
end

defmodule Espex.Proto.BluetoothDeviceRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64

  field :request_type, 2,
    type: Espex.Proto.BluetoothDeviceRequestType,
    json_name: "requestType",
    enum: true

  field :has_address_type, 3, type: :bool, json_name: "hasAddressType"
  field :address_type, 4, type: :uint32, json_name: "addressType"
end

defmodule Espex.Proto.BluetoothDeviceConnectionResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :connected, 2, type: :bool
  field :mtu, 3, type: :uint32
  field :error, 4, type: :int32
end

defmodule Espex.Proto.BluetoothGATTGetServicesRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
end

defmodule Espex.Proto.BluetoothGATTDescriptor do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :uuid, 1, repeated: true, type: :uint64, deprecated: false
  field :handle, 2, type: :uint32
  field :short_uuid, 3, type: :uint32, json_name: "shortUuid"
end

defmodule Espex.Proto.BluetoothGATTCharacteristic do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :uuid, 1, repeated: true, type: :uint64, deprecated: false
  field :handle, 2, type: :uint32
  field :properties, 3, type: :uint32

  field :descriptors, 4,
    repeated: true,
    type: Espex.Proto.BluetoothGATTDescriptor,
    deprecated: false

  field :short_uuid, 5, type: :uint32, json_name: "shortUuid"
end

defmodule Espex.Proto.BluetoothGATTService do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :uuid, 1, repeated: true, type: :uint64, deprecated: false
  field :handle, 2, type: :uint32

  field :characteristics, 3,
    repeated: true,
    type: Espex.Proto.BluetoothGATTCharacteristic,
    deprecated: false

  field :short_uuid, 4, type: :uint32, json_name: "shortUuid"
end

defmodule Espex.Proto.BluetoothGATTGetServicesResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :services, 2, repeated: true, type: Espex.Proto.BluetoothGATTService
end

defmodule Espex.Proto.BluetoothGATTGetServicesDoneResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
end

defmodule Espex.Proto.BluetoothGATTReadRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :handle, 2, type: :uint32
end

defmodule Espex.Proto.BluetoothGATTReadResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :handle, 2, type: :uint32
  field :data, 3, type: :bytes
end

defmodule Espex.Proto.BluetoothGATTWriteRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :handle, 2, type: :uint32
  field :response, 3, type: :bool
  field :data, 4, type: :bytes
end

defmodule Espex.Proto.BluetoothGATTReadDescriptorRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :handle, 2, type: :uint32
end

defmodule Espex.Proto.BluetoothGATTWriteDescriptorRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :handle, 2, type: :uint32
  field :data, 3, type: :bytes
end

defmodule Espex.Proto.BluetoothGATTNotifyRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :handle, 2, type: :uint32
  field :enable, 3, type: :bool
end

defmodule Espex.Proto.BluetoothGATTNotifyDataResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :handle, 2, type: :uint32
  field :data, 3, type: :bytes
end

defmodule Espex.Proto.SubscribeBluetoothConnectionsFreeRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.BluetoothConnectionsFreeResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :free, 1, type: :uint32
  field :limit, 2, type: :uint32
  field :allocated, 3, repeated: true, type: :uint64, deprecated: false
end

defmodule Espex.Proto.BluetoothGATTErrorResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :handle, 2, type: :uint32
  field :error, 3, type: :int32
end

defmodule Espex.Proto.BluetoothGATTWriteResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :handle, 2, type: :uint32
end

defmodule Espex.Proto.BluetoothGATTNotifyResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :handle, 2, type: :uint32
end

defmodule Espex.Proto.BluetoothDevicePairingResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :paired, 2, type: :bool
  field :error, 3, type: :int32
end

defmodule Espex.Proto.BluetoothDeviceUnpairingResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :success, 2, type: :bool
  field :error, 3, type: :int32
end

defmodule Espex.Proto.UnsubscribeBluetoothLEAdvertisementsRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3
end

defmodule Espex.Proto.BluetoothDeviceClearCacheResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :address, 1, type: :uint64
  field :success, 2, type: :bool
  field :error, 3, type: :int32
end

defmodule Espex.Proto.BluetoothScannerStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :state, 1, type: Espex.Proto.BluetoothScannerState, enum: true
  field :mode, 2, type: Espex.Proto.BluetoothScannerMode, enum: true

  field :configured_mode, 3,
    type: Espex.Proto.BluetoothScannerMode,
    json_name: "configuredMode",
    enum: true
end

defmodule Espex.Proto.BluetoothScannerSetModeRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :mode, 1, type: Espex.Proto.BluetoothScannerMode, enum: true
end

defmodule Espex.Proto.SubscribeVoiceAssistantRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :subscribe, 1, type: :bool
  field :flags, 2, type: :uint32
end

defmodule Espex.Proto.VoiceAssistantAudioSettings do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :noise_suppression_level, 1, type: :uint32, json_name: "noiseSuppressionLevel"
  field :auto_gain, 2, type: :uint32, json_name: "autoGain"
  field :volume_multiplier, 3, type: :float, json_name: "volumeMultiplier"
end

defmodule Espex.Proto.VoiceAssistantRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :start, 1, type: :bool
  field :conversation_id, 2, type: :string, json_name: "conversationId"
  field :flags, 3, type: :uint32

  field :audio_settings, 4,
    type: Espex.Proto.VoiceAssistantAudioSettings,
    json_name: "audioSettings"

  field :wake_word_phrase, 5, type: :string, json_name: "wakeWordPhrase"
end

defmodule Espex.Proto.VoiceAssistantResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :port, 1, type: :uint32
  field :error, 2, type: :bool
end

defmodule Espex.Proto.VoiceAssistantEventData do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, type: :string
end

defmodule Espex.Proto.VoiceAssistantEventResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :event_type, 1, type: Espex.Proto.VoiceAssistantEvent, json_name: "eventType", enum: true
  field :data, 2, repeated: true, type: Espex.Proto.VoiceAssistantEventData
end

defmodule Espex.Proto.VoiceAssistantAudio do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :data, 1, type: :bytes, deprecated: false
  field :end, 2, type: :bool
end

defmodule Espex.Proto.VoiceAssistantTimerEventResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :event_type, 1,
    type: Espex.Proto.VoiceAssistantTimerEvent,
    json_name: "eventType",
    enum: true

  field :timer_id, 2, type: :string, json_name: "timerId"
  field :name, 3, type: :string
  field :total_seconds, 4, type: :uint32, json_name: "totalSeconds"
  field :seconds_left, 5, type: :uint32, json_name: "secondsLeft"
  field :is_active, 6, type: :bool, json_name: "isActive"
end

defmodule Espex.Proto.VoiceAssistantAnnounceRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :media_id, 1, type: :string, json_name: "mediaId"
  field :text, 2, type: :string
  field :preannounce_media_id, 3, type: :string, json_name: "preannounceMediaId"
  field :start_conversation, 4, type: :bool, json_name: "startConversation"
end

defmodule Espex.Proto.VoiceAssistantAnnounceFinished do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :success, 1, type: :bool
end

defmodule Espex.Proto.VoiceAssistantWakeWord do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :id, 1, type: :string
  field :wake_word, 2, type: :string, json_name: "wakeWord"
  field :trained_languages, 3, repeated: true, type: :string, json_name: "trainedLanguages"
end

defmodule Espex.Proto.VoiceAssistantExternalWakeWord do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :id, 1, type: :string
  field :wake_word, 2, type: :string, json_name: "wakeWord"
  field :trained_languages, 3, repeated: true, type: :string, json_name: "trainedLanguages"
  field :model_type, 4, type: :string, json_name: "modelType"
  field :model_size, 5, type: :uint32, json_name: "modelSize"
  field :model_hash, 6, type: :string, json_name: "modelHash"
  field :url, 7, type: :string
end

defmodule Espex.Proto.VoiceAssistantConfigurationRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :external_wake_words, 1,
    repeated: true,
    type: Espex.Proto.VoiceAssistantExternalWakeWord,
    json_name: "externalWakeWords"
end

defmodule Espex.Proto.VoiceAssistantConfigurationResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :available_wake_words, 1,
    repeated: true,
    type: Espex.Proto.VoiceAssistantWakeWord,
    json_name: "availableWakeWords"

  field :active_wake_words, 2,
    repeated: true,
    type: :string,
    json_name: "activeWakeWords",
    deprecated: false

  field :max_active_wake_words, 3, type: :uint32, json_name: "maxActiveWakeWords"
end

defmodule Espex.Proto.VoiceAssistantSetConfiguration do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :active_wake_words, 1, repeated: true, type: :string, json_name: "activeWakeWords"
end

defmodule Espex.Proto.ListEntitiesAlarmControlPanelResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :supported_features, 8, type: :uint32, json_name: "supportedFeatures"
  field :requires_code, 9, type: :bool, json_name: "requiresCode"
  field :requires_code_to_arm, 10, type: :bool, json_name: "requiresCodeToArm"
  field :device_id, 11, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.AlarmControlPanelStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: Espex.Proto.AlarmControlPanelState, enum: true
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.AlarmControlPanelCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :command, 2, type: Espex.Proto.AlarmControlPanelStateCommand, enum: true
  field :code, 3, type: :string
  field :device_id, 4, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesTextResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :min_length, 8, type: :uint32, json_name: "minLength"
  field :max_length, 9, type: :uint32, json_name: "maxLength"
  field :pattern, 10, type: :string
  field :mode, 11, type: Espex.Proto.TextMode, enum: true
  field :device_id, 12, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.TextStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :string
  field :missing_state, 3, type: :bool, json_name: "missingState"
  field :device_id, 4, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.TextCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :state, 2, type: :string
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesDateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 8, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.DateStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :missing_state, 2, type: :bool, json_name: "missingState"
  field :year, 3, type: :uint32
  field :month, 4, type: :uint32
  field :day, 5, type: :uint32
  field :device_id, 6, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.DateCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :year, 2, type: :uint32
  field :month, 3, type: :uint32
  field :day, 4, type: :uint32
  field :device_id, 5, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesTimeResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 8, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.TimeStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :missing_state, 2, type: :bool, json_name: "missingState"
  field :hour, 3, type: :uint32
  field :minute, 4, type: :uint32
  field :second, 5, type: :uint32
  field :device_id, 6, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.TimeCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :hour, 2, type: :uint32
  field :minute, 3, type: :uint32
  field :second, 4, type: :uint32
  field :device_id, 5, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesEventResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_class, 8, type: :string, json_name: "deviceClass"
  field :event_types, 9, repeated: true, type: :string, json_name: "eventTypes", deprecated: false
  field :device_id, 10, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.EventResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :event_type, 2, type: :string, json_name: "eventType"
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesValveResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_class, 8, type: :string, json_name: "deviceClass"
  field :assumed_state, 9, type: :bool, json_name: "assumedState"
  field :supports_position, 10, type: :bool, json_name: "supportsPosition"
  field :supports_stop, 11, type: :bool, json_name: "supportsStop"
  field :device_id, 12, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ValveStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :position, 2, type: :float

  field :current_operation, 3,
    type: Espex.Proto.ValveOperation,
    json_name: "currentOperation",
    enum: true

  field :device_id, 4, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ValveCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :has_position, 2, type: :bool, json_name: "hasPosition"
  field :position, 3, type: :float
  field :stop, 4, type: :bool
  field :device_id, 5, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesDateTimeResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 8, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.DateTimeStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :missing_state, 2, type: :bool, json_name: "missingState"
  field :epoch_seconds, 3, type: :fixed32, json_name: "epochSeconds"
  field :device_id, 4, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.DateTimeCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :epoch_seconds, 2, type: :fixed32, json_name: "epochSeconds"
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ListEntitiesUpdateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 5, type: :string, deprecated: false
  field :disabled_by_default, 6, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 7,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_class, 8, type: :string, json_name: "deviceClass"
  field :device_id, 9, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.UpdateStateResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :missing_state, 2, type: :bool, json_name: "missingState"
  field :in_progress, 3, type: :bool, json_name: "inProgress"
  field :has_progress, 4, type: :bool, json_name: "hasProgress"
  field :progress, 5, type: :float
  field :current_version, 6, type: :string, json_name: "currentVersion"
  field :latest_version, 7, type: :string, json_name: "latestVersion"
  field :title, 8, type: :string
  field :release_summary, 9, type: :string, json_name: "releaseSummary"
  field :release_url, 10, type: :string, json_name: "releaseUrl"
  field :device_id, 11, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.UpdateCommandRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :key, 1, type: :fixed32
  field :command, 2, type: Espex.Proto.UpdateCommand, enum: true
  field :device_id, 3, type: :uint32, json_name: "deviceId", deprecated: false
end

defmodule Espex.Proto.ZWaveProxyFrame do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :data, 1, type: :bytes
end

defmodule Espex.Proto.ZWaveProxyRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :type, 1, type: Espex.Proto.ZWaveProxyRequestType, enum: true
  field :data, 2, type: :bytes
end

defmodule Espex.Proto.ListEntitiesInfraredResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :object_id, 1, type: :string, json_name: "objectId"
  field :key, 2, type: :fixed32
  field :name, 3, type: :string
  field :icon, 4, type: :string, deprecated: false
  field :disabled_by_default, 5, type: :bool, json_name: "disabledByDefault"

  field :entity_category, 6,
    type: Espex.Proto.EntityCategory,
    json_name: "entityCategory",
    enum: true

  field :device_id, 7, type: :uint32, json_name: "deviceId", deprecated: false
  field :capabilities, 8, type: :uint32
end

defmodule Espex.Proto.InfraredRFTransmitRawTimingsRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :device_id, 1, type: :uint32, json_name: "deviceId", deprecated: false
  field :key, 2, type: :fixed32
  field :carrier_frequency, 3, type: :uint32, json_name: "carrierFrequency"
  field :repeat_count, 4, type: :uint32, json_name: "repeatCount"
  field :timings, 5, repeated: true, type: :sint32, packed: true, deprecated: false
end

defmodule Espex.Proto.InfraredRFReceiveEvent do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :device_id, 1, type: :uint32, json_name: "deviceId", deprecated: false
  field :key, 2, type: :fixed32
  field :timings, 3, repeated: true, type: :sint32, packed: true, deprecated: false
end

defmodule Espex.Proto.SerialProxyConfigureRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :instance, 1, type: :uint32
  field :baudrate, 2, type: :uint32
  field :flow_control, 3, type: :bool, json_name: "flowControl"
  field :parity, 4, type: Espex.Proto.SerialProxyParity, enum: true
  field :stop_bits, 5, type: :uint32, json_name: "stopBits"
  field :data_size, 6, type: :uint32, json_name: "dataSize"
end

defmodule Espex.Proto.SerialProxyDataReceived do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :instance, 1, type: :uint32
  field :data, 2, type: :bytes
end

defmodule Espex.Proto.SerialProxyWriteRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :instance, 1, type: :uint32
  field :data, 2, type: :bytes
end

defmodule Espex.Proto.SerialProxySetModemPinsRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :instance, 1, type: :uint32
  field :rts, 2, type: :bool
  field :dtr, 3, type: :bool
end

defmodule Espex.Proto.SerialProxyGetModemPinsRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :instance, 1, type: :uint32
end

defmodule Espex.Proto.SerialProxyGetModemPinsResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :instance, 1, type: :uint32
  field :rts, 2, type: :bool
  field :dtr, 3, type: :bool
end

defmodule Espex.Proto.SerialProxyRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.16.0", syntax: :proto3

  field :instance, 1, type: :uint32
  field :type, 2, type: Espex.Proto.SerialProxyRequestType, enum: true
end
