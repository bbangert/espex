defmodule Espex.Api118Test do
  # API 1.18: IR/RF transmit completion and Sendspin. Exercised over real
  # TCP. FakeSendspin reads its answers from :persistent_term, which is
  # why this file stays async: false.
  use ExUnit.Case, async: false

  import Espex.Test.TcpClient

  alias Espex.Proto

  setup context do
    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    {:ok, sup_pid} =
      Espex.start_link(
        [
          name: sup_name,
          server_name: server_name,
          port: 0,
          device_config: [name: "api118", project_name: "espex_test", project_version: "0.0.1"]
        ] ++ adapter_opts(context)
      )

    {:ok, port} = Espex.Supervisor.bound_port(sup_pid)

    on_exit(fn ->
      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{port: port, server_name: server_name}
  end

  defp adapter_opts(context), do: context |> Map.get(:adapters, %{}) |> Map.to_list()

  defp hello(port) do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: "api118-test", api_version_major: 1, api_version_minor: 18})
    {:ok, %Proto.HelloResponse{} = hello, rest} = recv_struct(socket)
    {socket, hello, rest}
  end

  defp transmit(socket, key, timings \\ [9000, -4500, 560]) do
    send_struct(socket, %Proto.InfraredRFTransmitRawTimingsRequest{key: key, device_id: 5, timings: timings})
  end

  describe "InfraredRFTransmitCompleteResponse" do
    @describetag adapters: %{infrared_proxy: Espex.Test.KeyedInfraredProxy}

    test "a sent frame is reported complete, echoing key and device_id", %{port: port} do
      {socket, _hello, rest} = hello(port)
      transmit(socket, 42)

      assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 42, device_id: 5, success: true}, _} =
               recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end

    test "an adapter error is reported as success: false", %{port: port} do
      {socket, _hello, rest} = hello(port)
      transmit(socket, 7)

      assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 7, device_id: 5, success: false}, _} =
               recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end

    test "a request with no timings is refused", %{port: port} do
      {socket, _hello, rest} = hello(port)
      transmit(socket, 42, [])

      assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 42, success: false}, _} = recv_struct(socket, rest)
      :gen_tcp.close(socket)
    end

    test "back-to-back frames are each answered, in order", %{port: port} do
      {socket, _hello, rest} = hello(port)
      transmit(socket, 42)
      transmit(socket, 7)
      transmit(socket, 42)

      {:ok, first, rest} = recv_struct(socket, rest)
      {:ok, second, rest} = recv_struct(socket, rest)
      {:ok, third, _} = recv_struct(socket, rest)

      assert Enum.map([first, second, third], &{&1.key, &1.success}) == [{42, true}, {7, false}, {42, true}]
      :gen_tcp.close(socket)
    end

    test "only the requesting connection receives the completion", %{port: port} do
      {a, _hello, rest_a} = hello(port)
      {b, _hello, rest_b} = hello(port)

      transmit(a, 42)
      assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 42, success: true}, _} = recv_struct(a, rest_a)
      assert {:error, :timeout} = recv_struct(b, rest_b, 200)

      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end
  end

  describe "Sendspin" do
    setup do
      on_exit(&Espex.Test.FakeSendspin.reset/0)
    end

    test "without an adapter capabilities carry no sendspin and the token request goes unanswered", %{port: port} do
      {socket, _hello, rest} = hello(port)
      send_struct(socket, %Proto.DeviceCapabilitiesRequest{})
      assert {:ok, %Proto.DeviceCapabilitiesResponse{sendspin: nil}, rest} = recv_struct(socket, rest)

      send_struct(socket, %Proto.SendspinPairingTokenRequest{})
      assert {:error, :timeout} = recv_struct(socket, rest, 200)
      :gen_tcp.close(socket)
    end

    @tag adapters: %{sendspin: Espex.Test.FakeSendspin}
    test "capabilities report the default feature flag and read client_id per request", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.DeviceCapabilitiesRequest{})
      assert {:ok, %Proto.DeviceCapabilitiesResponse{sendspin: before}, rest} = recv_struct(socket, rest)
      assert before == %Proto.SendspinCapabilities{feature_flags: 1, client_id: ""}

      Espex.Test.FakeSendspin.put(client_id: "Q2xpZW50UHVibGljS2V5")
      send_struct(socket, %Proto.DeviceCapabilitiesRequest{})
      assert {:ok, %Proto.DeviceCapabilitiesResponse{sendspin: started}, _} = recv_struct(socket, rest)
      assert started.client_id == "Q2xpZW50UHVibGljS2V5"
      :gen_tcp.close(socket)
    end

    @tag adapters: %{sendspin: Espex.Test.FlaggedSendspin}
    test "capabilities use the adapter's feature_flags/0 when it has one", %{port: port} do
      {socket, _hello, rest} = hello(port)
      send_struct(socket, %Proto.DeviceCapabilitiesRequest{})
      assert {:ok, %Proto.DeviceCapabilitiesResponse{sendspin: sendspin}, _} = recv_struct(socket, rest)
      assert sendspin == %Proto.SendspinCapabilities{feature_flags: 0b11, client_id: "flagged-client"}
      :gen_tcp.close(socket)
    end

    @tag adapters: %{sendspin: Espex.Test.FakeSendspin}
    test "a plaintext connection gets ENCRYPTION_REQUIRED and no token", %{port: port} do
      Espex.Test.FakeSendspin.put(pairing_token: {:ok, "secret-token"})
      {socket, _hello, rest} = hello(port)
      send_struct(socket, %Proto.SendspinPairingTokenRequest{})

      assert {:ok, %Proto.SendspinPairingTokenResponse{} = resp, _} = recv_struct(socket, rest)
      assert {resp.status, resp.token} == {:SENDSPIN_PAIRING_TOKEN_STATUS_ENCRYPTION_REQUIRED, ""}
      :gen_tcp.close(socket)
    end
  end

  test "without an infrared adapter a transmit is refused", %{port: port} do
    {socket, _hello, rest} = hello(port)
    transmit(socket, 42)

    assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 42, device_id: 5, success: false}, _} =
             recv_struct(socket, rest)

    :gen_tcp.close(socket)
  end
end
