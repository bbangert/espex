defmodule Espex.Test.FakeSerialProxy do
  @moduledoc false
  @behaviour Espex.SerialProxy

  @impl true
  def list_instances, do: []

  @impl true
  def open(_instance, _opts, _subscriber), do: {:ok, :fake_handle}

  @impl true
  def write(_handle, _data), do: :ok

  @impl true
  def close(_handle), do: :ok

  @impl true
  def set_modem_pins(_handle, _rts, _dtr), do: :ok

  @impl true
  def get_modem_pins(_handle), do: {:ok, %{rts: false, dtr: false}}
end

defmodule Espex.Test.FakeSerialProxyWithOne do
  @moduledoc false
  @behaviour Espex.SerialProxy

  @impl true
  def list_instances do
    [Espex.SerialProxy.Info.new(instance: 0, name: "zigbee", port_type: :ttl)]
  end

  @impl true
  def open(_instance, _opts, _subscriber), do: {:ok, :fake_handle}

  @impl true
  def write(_handle, _data), do: :ok

  @impl true
  def close(_handle), do: :ok

  @impl true
  def set_modem_pins(_handle, _rts, _dtr), do: :ok

  @impl true
  def get_modem_pins(_handle), do: {:ok, %{rts: false, dtr: false}}
end

defmodule Espex.Test.TrackingSerialProxy do
  @moduledoc """
  Test adapter that records open/request/close/modem-pins calls. Listeners
  register themselves under a per-test key in `:persistent_term` shaped
  `{__MODULE__, test_name}`; this adapter forwards every callback to every
  registered pid.

  Tests using this adapter MUST run `async: false` — the adapter sends to
  every registered listener, so true parallel isolation would also require
  threading the listener pid through the connection state.
  """
  @behaviour Espex.SerialProxy

  @impl true
  def list_instances do
    [Espex.SerialProxy.Info.new(instance: 0, name: "zigbee", port_type: :ttl)]
  end

  @impl true
  def open(instance, opts, subscriber) do
    notify({:open, instance, opts, subscriber})

    case :persistent_term.get({__MODULE__, :fail_next_open}, false) do
      true ->
        :persistent_term.erase({__MODULE__, :fail_next_open})
        {:error, :test_induced_failure}

      false ->
        {:ok, {:tracking_handle, instance}}
    end
  end

  @impl true
  def write(handle, data) do
    notify({:write, handle, data})
    :ok
  end

  @impl true
  def close(handle) do
    notify({:close, handle})
    :ok
  end

  @impl true
  def set_modem_pins(handle, rts, dtr) do
    notify({:set_modem_pins, handle, rts, dtr})
    :ok
  end

  @impl true
  def get_modem_pins(handle) do
    notify({:get_modem_pins, handle})
    {:ok, %{rts: false, dtr: false}}
  end

  @impl true
  def request(handle, type) do
    notify({:request, handle, type})
    {:ok, :ok}
  end

  defp notify(event) do
    for {{__MODULE__, _test}, pid} <- :persistent_term.get(), is_pid(pid) do
      send(pid, event)
    end

    :ok
  end
end

defmodule Espex.Test.FakeZWaveProxy do
  @moduledoc false
  @behaviour Espex.ZWaveProxy

  @impl true
  def available?, do: true

  @impl true
  def home_id, do: 0

  @impl true
  def feature_flags, do: 1

  @impl true
  def subscribe(_pid), do: {:ok, <<0, 0, 0, 0>>}

  @impl true
  def unsubscribe(_pid), do: :ok

  @impl true
  def send_frame(_data), do: :ok
end

defmodule Espex.Test.FakeInfraredProxy do
  @moduledoc false
  @behaviour Espex.InfraredProxy

  @impl true
  def list_entities, do: []

  @impl true
  def transmit_raw(_key, _timings, _opts), do: :ok

  @impl true
  def subscribe(_pid), do: :ok

  @impl true
  def unsubscribe(_pid), do: :ok
end

defmodule Espex.Test.FakeEntityProvider do
  @moduledoc false
  @behaviour Espex.EntityProvider

  @impl true
  def list_entities do
    [%Espex.Proto.ListEntitiesBinarySensorResponse{object_id: "fake", key: 1, name: "Fake"}]
  end

  @impl true
  def initial_states do
    [%Espex.Proto.BinarySensorStateResponse{key: 1, state: true, missing_state: false}]
  end

  @impl true
  def handle_command(_message), do: :ok
end

defmodule Espex.Test.FakeBluetoothScanner do
  @moduledoc """
  No-op `Espex.BluetoothScanner` adapter that implements every callback
  (including optional `set_scanner_mode/1`). Use
  `Espex.Test.MinimalBluetoothScanner` for the "optional callback
  omitted" path.
  """
  @behaviour Espex.BluetoothScanner

  @impl true
  def subscribe(_pid), do: :ok

  @impl true
  def unsubscribe(_pid), do: :ok

  @impl true
  def set_scanner_mode(_mode), do: :ok
end

defmodule Espex.Test.MinimalBluetoothScanner do
  @moduledoc """
  `Espex.BluetoothScanner` adapter implementing only required callbacks —
  no `set_scanner_mode/1`. Used to exercise the feature-flag path where
  the `STATE_AND_MODE` bit must NOT be set.
  """
  @behaviour Espex.BluetoothScanner

  @impl true
  def subscribe(_pid), do: :ok

  @impl true
  def unsubscribe(_pid), do: :ok
end

defmodule Espex.Test.TrackingBluetoothProxy do
  @moduledoc """
  Test adapter recording every `Espex.BluetoothProxy` callback — the
  full lifecycle (connect, disconnect, pair, unpair, clear_cache,
  set_connection_params), every GATT call (read, write, notify,
  get_services, read_descriptor, write_descriptor), and
  `connections_free/0`. PR 4 wires the lifecycle in `Espex.Dispatch`
  and `Espex.Connection`; GATT wiring lands in PR 5, but the adapter
  stubs are ready now so the GATT integration tests can drop in
  without churning this file.

  Implements every optional callback so feature-flag computation sees
  `PAIRING | CACHE_CLEARING` set. Listener-pid fan-out mirrors
  `TrackingBluetoothScanner` / `TrackingSerialProxy`; tests push
  `{:espex_ble_*, ...}` events directly to the captured handler pid
  after grabbing it from the `{:connect, address, opts, handler_pid}`
  notification.

  Tests using this adapter MUST run `async: false` — listener fan-out
  shares process-wide state. `connections_free/0` returns `{3, 3}` by
  default; override per-test by setting `{__MODULE__, :connections_free}`
  in `:persistent_term`.
  """
  @behaviour Espex.BluetoothProxy

  @impl true
  def connect(address, opts, subscriber) do
    notify({:connect, address, opts, subscriber})
    :ok
  end

  @impl true
  def disconnect(address) do
    notify({:disconnect, address})
    :ok
  end

  @impl true
  def gatt_get_services(address) do
    notify({:gatt_get_services, address})
    :ok
  end

  @impl true
  def gatt_read(address, handle) do
    notify({:gatt_read, address, handle})
    :ok
  end

  @impl true
  def gatt_write(address, handle, data, response?) do
    notify({:gatt_write, address, handle, data, response?})
    :ok
  end

  @impl true
  def gatt_read_descriptor(address, handle) do
    notify({:gatt_read_descriptor, address, handle})
    :ok
  end

  @impl true
  def gatt_write_descriptor(address, handle, data) do
    notify({:gatt_write_descriptor, address, handle, data})
    :ok
  end

  @impl true
  def gatt_notify(address, handle, enable?) do
    notify({:gatt_notify, address, handle, enable?})
    :ok
  end

  @impl true
  def connections_free do
    :persistent_term.get({__MODULE__, :connections_free}, {3, 3})
  end

  @impl true
  def pair(address) do
    notify({:pair, address})
    :ok
  end

  @impl true
  def unpair(address) do
    notify({:unpair, address})
    :ok
  end

  @impl true
  def clear_cache(address) do
    notify({:clear_cache, address})
    :ok
  end

  @impl true
  def set_connection_params(address, params) do
    notify({:set_connection_params, address, params})
    :ok
  end

  defp notify(event) do
    for {{__MODULE__, _test}, pid} <- :persistent_term.get(), is_pid(pid) do
      send(pid, event)
    end

    :ok
  end
end

defmodule Espex.Test.TrackingBluetoothScanner do
  @moduledoc """
  Test adapter that records subscribe/unsubscribe/set_scanner_mode calls
  by fanning them out to listener pids registered in `:persistent_term`.

  Listeners register themselves under a per-test key shaped
  `{__MODULE__, test_name}`; every callback notifies every registered
  pid. Tests inject advertisements and scanner-state events by capturing
  the per-connection handler pid from the `{:subscribe, handler_pid}`
  notification and `send/2`-ing the `:espex_ble_*` tuples directly —
  same pattern as `Espex.Test.TrackingSerialProxy`.

  Tests using this adapter MUST run `async: false` — the fan-out shares
  process-wide state.
  """
  @behaviour Espex.BluetoothScanner

  @impl true
  def subscribe(pid) do
    notify({:subscribe, pid})
    :ok
  end

  @impl true
  def unsubscribe(pid) do
    notify({:unsubscribe, pid})
    :ok
  end

  @impl true
  def set_scanner_mode(mode) do
    notify({:set_scanner_mode, mode})
    :ok
  end

  defp notify(event) do
    for {{__MODULE__, _test}, pid} <- :persistent_term.get(), is_pid(pid) do
      send(pid, event)
    end

    :ok
  end
end

defmodule Espex.Test.FakeBluetoothProxy do
  @moduledoc """
  No-op `Espex.BluetoothProxy` adapter for compile-time wiring tests.
  Exports every optional callback so feature-flag computation tests can
  exercise the "all flags set" path. Use `Espex.Test.MinimalBluetoothProxy`
  for the "no optional callbacks" path.
  """
  @behaviour Espex.BluetoothProxy

  @impl true
  def connect(_address, _opts, _subscriber), do: :ok

  @impl true
  def disconnect(_address), do: :ok

  @impl true
  def gatt_get_services(_address), do: :ok

  @impl true
  def gatt_read(_address, _handle), do: :ok

  @impl true
  def gatt_write(_address, _handle, _data, _response?), do: :ok

  @impl true
  def gatt_read_descriptor(_address, _handle), do: :ok

  @impl true
  def gatt_write_descriptor(_address, _handle, _data), do: :ok

  @impl true
  def gatt_notify(_address, _handle, _enable?), do: :ok

  @impl true
  def connections_free, do: {3, 3}

  @impl true
  def pair(_address), do: :ok

  @impl true
  def unpair(_address), do: :ok

  @impl true
  def clear_cache(_address), do: :ok

  @impl true
  def set_connection_params(_address, _params), do: :ok
end

defmodule Espex.Test.MinimalBluetoothProxy do
  @moduledoc """
  `Espex.BluetoothProxy` adapter implementing only required callbacks —
  no `pair/unpair/clear_cache/set_connection_params`. Used to exercise
  the `:not_supported` dispatch paths and the feature-flag bits that
  toggle based on `function_exported?/3` checks.
  """
  @behaviour Espex.BluetoothProxy

  @impl true
  def connect(_address, _opts, _subscriber), do: :ok

  @impl true
  def disconnect(_address), do: :ok

  @impl true
  def gatt_get_services(_address), do: :ok

  @impl true
  def gatt_read(_address, _handle), do: :ok

  @impl true
  def gatt_write(_address, _handle, _data, _response?), do: :ok

  @impl true
  def gatt_read_descriptor(_address, _handle), do: :ok

  @impl true
  def gatt_write_descriptor(_address, _handle, _data), do: :ok

  @impl true
  def gatt_notify(_address, _handle, _enable?), do: :ok

  @impl true
  def connections_free, do: {3, 3}
end
