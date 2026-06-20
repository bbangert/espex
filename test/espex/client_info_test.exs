defmodule Espex.ClientInfoTest do
  use ExUnit.Case, async: true

  alias Espex.{ClientInfo, ConnectionState}

  defp state(overrides) do
    ConnectionState.new(Keyword.merge([device_config: %Espex.DeviceConfig{}, peer: "1.2.3.4:5678"], overrides))
  end

  test "new/2 copies identity fields and uses the pid as id" do
    s = state(client_info: "HA 2026.1.0", api_version: {1, 10}, connected_at: 100, last_activity_at: 142)
    info = ClientInfo.new(self(), s)

    assert info.id == self()
    assert info.peer == "1.2.3.4:5678"
    assert info.client_info == "HA 2026.1.0"
    assert info.api_version == {1, 10}
    assert info.connected_at == 100
    assert info.last_activity_at == 142
  end

  test "encrypted? is derived from an active encryption state" do
    plaintext = ClientInfo.new(self(), state(encryption: :disabled))
    refute plaintext.encrypted?

    # Mid-handshake states are not yet encrypted.
    refute ClientInfo.new(self(), state(encryption: :awaiting_hello)).encrypted?

    active = ClientInfo.new(self(), state(encryption: {:active, :tx, :rx}))
    assert active.encrypted?
  end
end
