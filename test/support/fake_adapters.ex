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
