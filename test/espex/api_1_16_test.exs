defmodule Espex.Api116Test do
  # The behaviours the Home Assistant client (aioesphomeapi) switches on
  # once a device advertises API 1.15 / 1.16: the DeviceCapabilities RPC
  # and the proxy request acknowledgements. Exercised over real TCP.
  use ExUnit.Case, async: false

  import Espex.Test.TcpClient

  alias Espex.Proto

  setup context do
    # TrackingSerialProxy forwards adapter calls to the pid registered here
    # (per-test key), which is why this file stays async: false.
    tracking_key = {Espex.Test.TrackingSerialProxy, context.test}
    :persistent_term.put(tracking_key, self())
    on_exit(fn -> :persistent_term.erase(tracking_key) end)

    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    {:ok, sup_pid} =
      Espex.start_link(
        [
          name: sup_name,
          server_name: server_name,
          port: 0,
          device_config: [name: "api116", project_name: "espex_test", project_version: "0.0.1"]
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

    %{port: port}
  end

  defp adapter_opts(context), do: context |> Map.get(:adapters, %{}) |> Map.to_list()

  defp hello(port) do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: "api116-test", api_version_major: 1, api_version_minor: 18})
    {:ok, %Proto.HelloResponse{} = hello, rest} = recv_struct(socket)
    {socket, hello, rest}
  end

  test "hello advertises API 1.16", %{port: port} do
    {socket, hello, _} = hello(port)
    assert {hello.api_version_major, hello.api_version_minor} == {1, 16}
    :gen_tcp.close(socket)
  end

  @tag adapters: %{
         bluetooth_scanner: Espex.Test.FakeBluetoothScanner,
         zwave_proxy: Espex.Test.FakeZWaveProxyWithHomeId,
         serial_proxy: Espex.Test.FakeSerialProxyWithOne
       }
  test "DeviceCapabilitiesResponse matches DeviceInfoResponse on the same connection", %{port: port} do
    {socket, _hello, rest} = hello(port)
    # A Z-Wave adapter with a known network pushes its home id right after hello.
    {:ok, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE}, rest} = recv_struct(socket, rest)

    send_struct(socket, %Proto.DeviceInfoRequest{})
    {:ok, %Proto.DeviceInfoResponse{} = info, rest} = recv_struct(socket, rest)
    send_struct(socket, %Proto.DeviceCapabilitiesRequest{})
    {:ok, %Proto.DeviceCapabilitiesResponse{} = caps, _} = recv_struct(socket, rest)

    assert info.bluetooth_proxy_feature_flags != 0
    assert caps.bluetooth_proxy.feature_flags == info.bluetooth_proxy_feature_flags
    assert caps.zwave_proxy.feature_flags == info.zwave_proxy_feature_flags
    assert caps.zwave_proxy.home_id == info.zwave_home_id
    assert caps.zwave_proxy.home_id == 0xDEADBEEF
    assert [%Proto.SerialProxyInfo{name: "zigbee"}] = caps.serial_proxies
    assert caps.serial_proxies == info.serial_proxies
    :gen_tcp.close(socket)
  end

  describe "serial proxy acknowledgements" do
    @tag adapters: %{serial_proxy: Espex.Test.FakeSerialProxyWithOne}
    test "CONFIGURE is acknowledged OK; an unknown instance is INVALID_ARGUMENT", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})

      assert {:ok,
              %Proto.SerialProxyRequestResponse{
                instance: 0,
                type: :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE,
                status: :SERIAL_PROXY_STATUS_OK
              }, rest} = recv_struct(socket, rest)

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 7, baudrate: 9600})

      assert {:ok,
              %Proto.SerialProxyRequestResponse{
                instance: 7,
                type: :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE,
                status: :SERIAL_PROXY_STATUS_INVALID_ARGUMENT
              }, _} = recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.FailingOpenSerialProxy}
    test "a failed open is acknowledged ERROR with the adapter's reason", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})

      assert {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_ERROR} = ack, _} =
               recv_struct(socket, rest)

      assert ack.type == :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE
      assert ack.error_message =~ "enodev"
      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.FakeSerialProxyWithOne}
    test "SET_MODEM_PINS is acknowledged OK by an adapter that implements it", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxySetModemPinsRequest{instance: 0, line_states: 0x03})

      assert {:ok,
              %Proto.SerialProxyRequestResponse{
                instance: 0,
                type: :SERIAL_PROXY_REQUEST_TYPE_SET_MODEM_PINS,
                status: :SERIAL_PROXY_STATUS_OK
              }, _} = recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.MinimalSerialProxy}
    test "SET_MODEM_PINS is NOT_SUPPORTED without the optional callback; GET reports it too", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxySetModemPinsRequest{instance: 0, line_states: 0x01})

      assert {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_NOT_SUPPORTED}, rest} =
               recv_struct(socket, rest)

      send_struct(socket, %Proto.SerialProxyGetModemPinsRequest{instance: 0})

      assert {:ok, %Proto.SerialProxyGetModemPinsResponse{status: :SERIAL_PROXY_STATUS_NOT_SUPPORTED}, _} =
               recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "a lazy open triggered by WRITE is not acknowledged", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxyWriteRequest{instance: 0, data: "x"})
      # The request was processed (open + write reached the adapter)...
      assert_receive {:open, 0, _opts, _subscriber}
      assert_receive {:write, {:tracking_handle, 0}, "x"}
      # ...and nothing came back on the wire for it.
      assert {:error, :timeout} = recv_struct(socket, rest, 250)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.ErroringPinsSerialProxy}
    test "SET_MODEM_PINS adapter error is acknowledged ERROR with the reason", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxySetModemPinsRequest{instance: 0, line_states: 0x01})

      assert {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_ERROR} = ack, _} =
               recv_struct(socket, rest)

      assert ack.type == :SERIAL_PROXY_REQUEST_TYPE_SET_MODEM_PINS
      assert ack.error_message =~ "eio"
      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.UnsupportedPinsSerialProxy}
    test "an adapter answering {:error, :not_supported} is acknowledged NOT_SUPPORTED, not ERROR", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxySetModemPinsRequest{instance: 0, line_states: 0x01})

      assert {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_NOT_SUPPORTED, error_message: ""}, _} =
               recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.FakeSerialProxyWithOne}
    test "GET_MODEM_PINS for an unknown instance reports INVALID_ARGUMENT", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxyGetModemPinsRequest{instance: 9})

      assert {:ok,
              %Proto.SerialProxyGetModemPinsResponse{
                instance: 9,
                line_states: 0,
                status: :SERIAL_PROXY_STATUS_INVALID_ARGUMENT
              }, _} = recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end
  end

  describe "Z-Wave proxy acknowledgements" do
    @tag adapters: %{zwave_proxy: Espex.Test.FakeZWaveProxyWithHomeId}
    test "SUBSCRIBE is acknowledged OK before the initial home id; UNSUBSCRIBE is acknowledged OK", %{port: port} do
      {socket, _hello, rest} = hello(port)
      {:ok, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE}, rest} = recv_struct(socket, rest)

      send_struct(socket, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE})

      assert {:ok,
              %Proto.ZWaveProxyRequestResponse{
                type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE,
                status: :ZWAVE_PROXY_STATUS_OK
              }, rest} = recv_struct(socket, rest)

      assert {:ok, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE}, rest} =
               recv_struct(socket, rest)

      send_struct(socket, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE})

      assert {:ok,
              %Proto.ZWaveProxyRequestResponse{
                type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE,
                status: :ZWAVE_PROXY_STATUS_OK
              }, _} = recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{zwave_proxy: Espex.Test.BusyZWaveProxy}
    test "a controller held by another client answers IN_USE", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE})

      assert {:ok, %Proto.ZWaveProxyRequestResponse{status: :ZWAVE_PROXY_STATUS_IN_USE}, rest} =
               recv_struct(socket, rest)

      # No home id follows a refused subscribe.
      assert {:error, :timeout} = recv_struct(socket, rest, 250)
      :gen_tcp.close(socket)
    end

    @tag adapters: %{zwave_proxy: Espex.Test.ExplodingZWaveProxy}
    test "any other adapter error answers NOT_SUPPORTED", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE})

      assert {:ok,
              %Proto.ZWaveProxyRequestResponse{
                type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE,
                status: :ZWAVE_PROXY_STATUS_NOT_SUPPORTED
              }, rest} = recv_struct(socket, rest)

      assert {:error, :timeout} = recv_struct(socket, rest, 250)
      :gen_tcp.close(socket)
    end

    test "SUBSCRIBE with no adapter answers NOT_SUPPORTED", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE})

      assert {:ok, %Proto.ZWaveProxyRequestResponse{status: :ZWAVE_PROXY_STATUS_NOT_SUPPORTED}, _} =
               recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end
  end
end
