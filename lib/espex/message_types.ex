defmodule Espex.MessageTypes do
  @moduledoc """
  Registry mapping ESPHome Native API message type IDs to their
  protobuf modules and back.

  Message type IDs are defined via `option (id) = N` in `api.proto`.
  All modules live under `Espex.Proto`.
  """

  alias Espex.Proto

  @message_types %{
    1 => Proto.HelloRequest,
    2 => Proto.HelloResponse,
    3 => Proto.AuthenticationRequest,
    4 => Proto.AuthenticationResponse,
    5 => Proto.DisconnectRequest,
    6 => Proto.DisconnectResponse,
    7 => Proto.PingRequest,
    8 => Proto.PingResponse,
    9 => Proto.DeviceInfoRequest,
    10 => Proto.DeviceInfoResponse,
    11 => Proto.ListEntitiesRequest,
    12 => Proto.ListEntitiesBinarySensorResponse,
    13 => Proto.ListEntitiesCoverResponse,
    14 => Proto.ListEntitiesFanResponse,
    15 => Proto.ListEntitiesLightResponse,
    16 => Proto.ListEntitiesSensorResponse,
    17 => Proto.ListEntitiesSwitchResponse,
    18 => Proto.ListEntitiesTextSensorResponse,
    19 => Proto.ListEntitiesDoneResponse,
    20 => Proto.SubscribeStatesRequest,
    21 => Proto.BinarySensorStateResponse,
    22 => Proto.CoverStateResponse,
    23 => Proto.FanStateResponse,
    24 => Proto.LightStateResponse,
    25 => Proto.SensorStateResponse,
    26 => Proto.SwitchStateResponse,
    27 => Proto.TextSensorStateResponse,
    28 => Proto.SubscribeLogsRequest,
    29 => Proto.SubscribeLogsResponse,
    30 => Proto.CoverCommandRequest,
    31 => Proto.FanCommandRequest,
    32 => Proto.LightCommandRequest,
    33 => Proto.SwitchCommandRequest,
    34 => Proto.SubscribeHomeassistantServicesRequest,
    35 => Proto.HomeassistantActionRequest,
    36 => Proto.GetTimeRequest,
    37 => Proto.GetTimeResponse,
    38 => Proto.SubscribeHomeAssistantStatesRequest,
    39 => Proto.SubscribeHomeAssistantStateResponse,
    40 => Proto.HomeAssistantStateResponse,
    41 => Proto.ListEntitiesServicesResponse,
    42 => Proto.ExecuteServiceRequest,
    43 => Proto.ListEntitiesCameraResponse,
    44 => Proto.CameraImageResponse,
    45 => Proto.CameraImageRequest,
    46 => Proto.ListEntitiesClimateResponse,
    47 => Proto.ClimateStateResponse,
    48 => Proto.ClimateCommandRequest,
    49 => Proto.ListEntitiesNumberResponse,
    50 => Proto.NumberStateResponse,
    51 => Proto.NumberCommandRequest,
    52 => Proto.ListEntitiesSelectResponse,
    53 => Proto.SelectStateResponse,
    54 => Proto.SelectCommandRequest,
    55 => Proto.ListEntitiesSirenResponse,
    56 => Proto.SirenStateResponse,
    57 => Proto.SirenCommandRequest,
    58 => Proto.ListEntitiesLockResponse,
    59 => Proto.LockStateResponse,
    60 => Proto.LockCommandRequest,
    61 => Proto.ListEntitiesButtonResponse,
    62 => Proto.ButtonCommandRequest,
    63 => Proto.ListEntitiesMediaPlayerResponse,
    64 => Proto.MediaPlayerStateResponse,
    65 => Proto.MediaPlayerCommandRequest,
    66 => Proto.SubscribeBluetoothLEAdvertisementsRequest,
    68 => Proto.BluetoothDeviceRequest,
    69 => Proto.BluetoothDeviceConnectionResponse,
    70 => Proto.BluetoothGATTGetServicesRequest,
    71 => Proto.BluetoothGATTGetServicesResponse,
    72 => Proto.BluetoothGATTGetServicesDoneResponse,
    73 => Proto.BluetoothGATTReadRequest,
    74 => Proto.BluetoothGATTReadResponse,
    75 => Proto.BluetoothGATTWriteRequest,
    76 => Proto.BluetoothGATTReadDescriptorRequest,
    77 => Proto.BluetoothGATTWriteDescriptorRequest,
    78 => Proto.BluetoothGATTNotifyRequest,
    79 => Proto.BluetoothGATTNotifyDataResponse,
    80 => Proto.SubscribeBluetoothConnectionsFreeRequest,
    81 => Proto.BluetoothConnectionsFreeResponse,
    82 => Proto.BluetoothGATTErrorResponse,
    83 => Proto.BluetoothGATTWriteResponse,
    84 => Proto.BluetoothGATTNotifyResponse,
    85 => Proto.BluetoothDevicePairingResponse,
    86 => Proto.BluetoothDeviceUnpairingResponse,
    87 => Proto.UnsubscribeBluetoothLEAdvertisementsRequest,
    88 => Proto.BluetoothDeviceClearCacheResponse,
    89 => Proto.SubscribeVoiceAssistantRequest,
    90 => Proto.VoiceAssistantRequest,
    91 => Proto.VoiceAssistantResponse,
    92 => Proto.VoiceAssistantEventResponse,
    93 => Proto.BluetoothLERawAdvertisementsResponse,
    94 => Proto.ListEntitiesAlarmControlPanelResponse,
    95 => Proto.AlarmControlPanelStateResponse,
    96 => Proto.AlarmControlPanelCommandRequest,
    97 => Proto.ListEntitiesTextResponse,
    98 => Proto.TextStateResponse,
    99 => Proto.TextCommandRequest,
    100 => Proto.ListEntitiesDateResponse,
    101 => Proto.DateStateResponse,
    102 => Proto.DateCommandRequest,
    103 => Proto.ListEntitiesTimeResponse,
    104 => Proto.TimeStateResponse,
    105 => Proto.TimeCommandRequest,
    106 => Proto.VoiceAssistantAudio,
    107 => Proto.ListEntitiesEventResponse,
    108 => Proto.EventResponse,
    109 => Proto.ListEntitiesValveResponse,
    110 => Proto.ValveStateResponse,
    111 => Proto.ValveCommandRequest,
    112 => Proto.ListEntitiesDateTimeResponse,
    113 => Proto.DateTimeStateResponse,
    114 => Proto.DateTimeCommandRequest,
    115 => Proto.VoiceAssistantTimerEventResponse,
    116 => Proto.ListEntitiesUpdateResponse,
    117 => Proto.UpdateStateResponse,
    118 => Proto.UpdateCommandRequest,
    119 => Proto.VoiceAssistantAnnounceRequest,
    120 => Proto.VoiceAssistantAnnounceFinished,
    121 => Proto.VoiceAssistantConfigurationRequest,
    122 => Proto.VoiceAssistantConfigurationResponse,
    123 => Proto.VoiceAssistantSetConfiguration,
    124 => Proto.NoiseEncryptionSetKeyRequest,
    125 => Proto.NoiseEncryptionSetKeyResponse,
    126 => Proto.BluetoothScannerStateResponse,
    127 => Proto.BluetoothScannerSetModeRequest,
    128 => Proto.ZWaveProxyFrame,
    129 => Proto.ZWaveProxyRequest,
    130 => Proto.HomeassistantActionResponse,
    131 => Proto.ExecuteServiceResponse,
    132 => Proto.ListEntitiesWaterHeaterResponse,
    133 => Proto.WaterHeaterStateResponse,
    134 => Proto.WaterHeaterCommandRequest,
    135 => Proto.ListEntitiesInfraredResponse,
    136 => Proto.InfraredRFTransmitRawTimingsRequest,
    137 => Proto.InfraredRFReceiveEvent,
    138 => Proto.SerialProxyConfigureRequest,
    139 => Proto.SerialProxyDataReceived,
    140 => Proto.SerialProxyWriteRequest,
    141 => Proto.SerialProxySetModemPinsRequest,
    142 => Proto.SerialProxyGetModemPinsRequest,
    143 => Proto.SerialProxyGetModemPinsResponse,
    144 => Proto.SerialProxyRequest
  }

  @reverse_types Map.new(@message_types, fn {id, mod} -> {mod, id} end)

  @doc """
  Return the protobuf module for a given message type ID.

  Returns `{:ok, module}` or `:error`.
  """
  @spec module_for_id(non_neg_integer()) :: {:ok, module()} | :error
  def module_for_id(id) do
    Map.fetch(@message_types, id)
  end

  @doc """
  Return the message type ID for a given protobuf module.

  Returns `{:ok, id}` or `:error`.
  """
  @spec id_for_module(module()) :: {:ok, non_neg_integer()} | :error
  def id_for_module(module) do
    Map.fetch(@reverse_types, module)
  end

  @doc """
  Decode a protobuf binary given its message type ID.

  Returns `{:ok, struct}` or `{:error, reason}`.
  """
  @spec decode_message(non_neg_integer(), binary()) :: {:ok, struct()} | {:error, term()}
  def decode_message(type_id, payload) do
    case module_for_id(type_id) do
      {:ok, module} ->
        {:ok, module.decode(payload)}

      :error ->
        {:error, {:unknown_message_type, type_id}}
    end
  rescue
    e -> {:error, {:decode_failed, e}}
  end

  @doc """
  Encode a protobuf struct to its wire frame (indicator + varints + payload).

  Looks up the message type ID from the struct's module and delegates
  to `Espex.Frame.encode_frame/2`.
  """
  @spec encode_message(struct()) :: {:ok, binary()} | {:error, term()}
  def encode_message(%mod{} = message) do
    case id_for_module(mod) do
      {:ok, type_id} ->
        payload = mod.encode(message)
        frame = Espex.Frame.encode_frame(type_id, payload)
        {:ok, frame}

      :error ->
        {:error, {:unknown_module, mod}}
    end
  end
end
