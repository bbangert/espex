defmodule Espex.BluetoothProxy.ErrorCodes do
  @moduledoc false

  # Integers placed in the `error` field of Bluetooth proxy responses
  # (`BluetoothDeviceConnectionResponse`, `BluetoothDevicePairingResponse`,
  # `BluetoothDeviceUnpairingResponse`, `BluetoothDeviceClearCacheResponse`,
  # `BluetoothGATTErrorResponse`, …).
  #
  # `api.proto` doesn't define these — the C++ proxy implementation
  # uses ESP-IDF / Bluedroid error numbers. We mirror enough of them
  # for a Home Assistant client to surface a sensible message: HA
  # treats `error != 0` as failure generically and the exact value
  # mostly drives the log line. Refine against
  # `esphome/components/bluetooth_proxy/bluetooth_connection.h` if a
  # client surfaces a specific code we want to special-case.

  @doc "OK / no error."
  def ok, do: 0

  @doc "Generic failure (catch-all)."
  def generic_error, do: -1

  @doc "Peripheral not connected — used by GATT operations on an unowned address."
  def not_connected, do: -2

  @doc "Slot busy — address is already owned by a different client connection."
  def busy, do: -3

  @doc "Optional callback not implemented by the adapter."
  def not_supported, do: -1
end
