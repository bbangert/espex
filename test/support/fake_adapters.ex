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
