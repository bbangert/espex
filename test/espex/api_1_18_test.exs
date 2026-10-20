defmodule Espex.Api118Test do
  # API 1.18: IR/RF transmit completion. Exercised over real TCP.
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

  test "without an infrared adapter a transmit is refused", %{port: port} do
    {socket, _hello, rest} = hello(port)
    transmit(socket, 42)

    assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 42, device_id: 5, success: false}, _} =
             recv_struct(socket, rest)

    :gen_tcp.close(socket)
  end
end
