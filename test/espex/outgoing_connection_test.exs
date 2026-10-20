defmodule Espex.OutgoingConnectionTest do
  # Dial-back over loopback: the test plays Home Assistant's dial-back
  # listener. This also guards the ThousandIsland ready-message contract
  # Espex.Dialer.Adopt relies on; run it on every thousand_island bump.
  # PidConnectionListener uses :persistent_term, so async: false.
  use ExUnit.Case, async: false

  import Espex.Test.TcpClient, only: [wait_until: 1]

  alias Espex.Proto
  alias Espex.Test.NoiseClient

  @psk :crypto.hash(:sha256, "espex-dial-back-psk")

  setup context do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])
    {:ok, ha_port} = :inet.port(listener)

    :persistent_term.put(:espex_listener_test_pid, self())
    on_exit(fn -> :persistent_term.erase(:espex_listener_test_pid) end)

    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    {:ok, sup_pid} =
      Espex.start_link(
        name: sup_name,
        server_name: server_name,
        port: 0,
        device_config: [name: "dialer", mac_address: "AA:BB:CC:DD:EE:0F", psk: @psk],
        connection_listener: Espex.Test.PidConnectionListener,
        outgoing_connection: [host: "127.0.0.1", port: ha_port, delay: 0]
      )

    on_exit(fn ->
      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, port} = Espex.Supervisor.bound_port(sup_pid)
    %{listener: listener, server: server_name, port: port}
  end

  defp accept(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    socket
  end

  defp hello(session, target? \\ true) do
    session =
      NoiseClient.send_struct(session, %Proto.HelloRequest{
        client_info: "dial-back-test",
        api_version_major: 1,
        api_version_minor: 18,
        outgoing_connection_target: target?
      })

    {%Proto.HelloResponse{name: "dialer"}, session} = NoiseClient.recv_struct(session)
    session
  end

  test "the device dials, speaks first with the bare MAC, and serves the session",
       %{listener: listener, server: server} do
    socket = accept(listener)
    assert {:ok, {"dialer", "aabbccddee0f"}} = NoiseClient.recv_server_hello(socket)

    session = socket |> NoiseClient.handshake(@psk) |> hello()
    assert_receive {:connections_changed}

    session = NoiseClient.send_struct(session, %Proto.DeviceInfoRequest{})
    {%Proto.DeviceInfoResponse{} = info, _session} = NoiseClient.recv_struct(session)
    assert info.api_outgoing_connection_supported
    assert info.mac_address == "AA:BB:CC:DD:EE:0F"

    assert [%Espex.ClientInfo{client_info: "dial-back-test", encrypted?: true, peer: "127.0.0.1:" <> _}] =
             Espex.connected_clients(server)

    # Closing it is a disconnect; with delay 0 the device dials again.
    :gen_tcp.close(socket)
    assert_receive {:connections_changed}

    again = accept(listener)
    assert {:ok, {"dialer", _mac}} = NoiseClient.recv_server_hello(again)
    # The registry drops the old entry when that process is gone.
    wait_until(fn -> match?([%Espex.ClientInfo{client_info: nil}], Espex.connected_clients(server)) end)
    :gen_tcp.close(again)
  end

  test "no second dial while the dialed connection is alive", %{listener: listener} do
    socket = accept(listener)
    {:ok, _} = NoiseClient.recv_server_hello(socket)
    _session = socket |> NoiseClient.handshake(@psk) |> hello(false)

    assert {:error, :timeout} = :gen_tcp.accept(listener, 200)
    :gen_tcp.close(socket)
  end

  test "accepted connections also advertise dial-back", %{port: port} do
    session = port |> NoiseClient.connect(@psk) |> hello()
    session = NoiseClient.send_struct(session, %Proto.DeviceInfoRequest{})

    {%Proto.DeviceInfoResponse{api_outgoing_connection_supported: true}, {socket, _, _}} =
      NoiseClient.recv_struct(session)

    :gen_tcp.close(socket)
  end
end
