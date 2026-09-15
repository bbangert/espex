defmodule Espex.Api117Test do
  # API 1.17: the serial proxy single-owner rule (the SUBSCRIBEd
  # connection owns the instance; everyone else gets PORT_IN_USE) and
  # SerialProxySetModeRequest. Exercised over real TCP.
  use ExUnit.Case, async: false

  import Espex.Test.TcpClient

  alias Espex.{Proto, Server}

  @subscribe :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
  @unsubscribe :SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE
  @flush :SERIAL_PROXY_REQUEST_TYPE_FLUSH

  setup context do
    # TrackingSerialProxy (and ModeTrackingSerialProxy, which delegates to
    # it) forwards adapter calls to the pid registered here, which is why
    # this file stays async: false.
    tracking_key = {Espex.Test.TrackingSerialProxy, context.test}
    :persistent_term.put(tracking_key, self())
    on_exit(fn -> :persistent_term.erase(tracking_key) end)

    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    {:ok, sup_pid} =
      Espex.start_link(
        name: sup_name,
        server_name: server_name,
        port: 0,
        device_config: [name: "api117", project_name: "espex_test", project_version: "0.0.1"],
        serial_proxy: context[:serial_proxy] || Espex.Test.TrackingSerialProxy
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

  defp hello(port) do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: "api117-test", api_version_major: 1, api_version_minor: 17})
    {:ok, %Proto.HelloResponse{} = hello, rest} = recv_struct(socket)
    {socket, hello, rest}
  end

  defp request(socket, instance, type) do
    send_struct(socket, %Proto.SerialProxyRequest{instance: instance, type: type})
  end

  defp set_mode(socket, instance, mode) do
    send_struct(socket, %Proto.SerialProxySetModeRequest{instance: instance, mode: mode})
  end

  # Read one SerialProxyRequestResponse and check it; returns the leftover buffer.
  defp assert_ack(socket, rest, instance, type, status) do
    assert {:ok, %Proto.SerialProxyRequestResponse{} = ack, rest} = recv_struct(socket, rest)
    assert {ack.instance, ack.type, ack.status} == {instance, type, status}
    rest
  end

  test "hello advertises API 1.17", %{port: port} do
    {socket, hello, _} = hello(port)
    assert {hello.api_version_major, hello.api_version_minor} == {1, 17}
    :gen_tcp.close(socket)
  end

  describe "no owner yet" do
    test "CONFIGURE / SET_MODEM_PINS / FLUSH / SET_MODE without SUBSCRIBE are PORT_IN_USE, adapter untouched", %{
      port: port
    } do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})
      rest = assert_ack(socket, rest, 0, :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE, :SERIAL_PROXY_STATUS_PORT_IN_USE)

      send_struct(socket, %Proto.SerialProxySetModemPinsRequest{instance: 0, line_states: 0x01})
      rest = assert_ack(socket, rest, 0, :SERIAL_PROXY_REQUEST_TYPE_SET_MODEM_PINS, :SERIAL_PROXY_STATUS_PORT_IN_USE)

      request(socket, 0, @flush)
      rest = assert_ack(socket, rest, 0, @flush, :SERIAL_PROXY_STATUS_PORT_IN_USE)

      set_mode(socket, 0, :SERIAL_PROXY_MODE_PROTOCOL)
      _rest = assert_ack(socket, rest, 0, :SERIAL_PROXY_REQUEST_TYPE_SET_MODE, :SERIAL_PROXY_STATUS_PORT_IN_USE)

      # Every ack above was sent after its request was dispatched, so the
      # adapter would already have been called by now if it were going to be.
      refute_received {:open, _, _, _}

      :gen_tcp.close(socket)
    end

    test "WRITE without SUBSCRIBE is dropped: nothing reaches the adapter, nothing on the wire", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxyWriteRequest{instance: 0, data: "ping"})

      assert {:error, :timeout} = recv_struct(socket, rest, 250)
      refute_received {:open, _, _, _}
      refute_received {:write, _, _}

      :gen_tcp.close(socket)
    end

    test "GET_MODEM_PINS without SUBSCRIBE is still answered (read-only, ungated)", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.SerialProxyGetModemPinsRequest{instance: 0})

      assert {:ok, %Proto.SerialProxyGetModemPinsResponse{instance: 0, status: :SERIAL_PROXY_STATUS_OK}, _} =
               recv_struct(socket, rest)

      assert_receive {:get_modem_pins, {:tracking_handle, 0}}

      :gen_tcp.close(socket)
    end

    test "UNSUBSCRIBE without SUBSCRIBE is OK (idempotent)", %{port: port} do
      {socket, _hello, rest} = hello(port)

      request(socket, 0, @unsubscribe)
      _rest = assert_ack(socket, rest, 0, @unsubscribe, :SERIAL_PROXY_STATUS_OK)
      refute_received {:request, _, :unsubscribe}

      :gen_tcp.close(socket)
    end
  end

  describe "two clients" do
    test "the second SUBSCRIBE is PORT_IN_USE until the owner UNSUBSCRIBEs", %{port: port} do
      {a, _hello, rest_a} = hello(port)
      {b, _hello, rest_b} = hello(port)

      rest_a = subscribe(a, 0, rest_a)

      request(b, 0, @subscribe)
      rest_b = assert_ack(b, rest_b, 0, @subscribe, :SERIAL_PROXY_STATUS_PORT_IN_USE)

      send_struct(b, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})
      rest_b = assert_ack(b, rest_b, 0, :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE, :SERIAL_PROXY_STATUS_PORT_IN_USE)

      request(a, 0, @unsubscribe)
      _rest_a = assert_ack(a, rest_a, 0, @unsubscribe, :SERIAL_PROXY_STATUS_OK)
      # A's handle was closed before its release, so the port is really free.
      assert_received {:close, {:tracking_handle, 0}}

      # A's ack is the barrier: its release on the Server happened first.
      _rest_b = subscribe(b, 0, rest_b)
      assert_receive {:open, 0, _opts, _subscriber}

      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end

    test "the owner's disconnect frees the instance for the next SUBSCRIBE", ctx do
      %{port: port, server_name: server_name} = ctx
      {a, _hello, rest_a} = hello(port)
      _rest_a = subscribe(a, 0, rest_a)
      assert is_pid(Server.serial_owner(server_name, 0))

      :gen_tcp.close(a)
      # The release runs in the dying connection's cleanup (or the DOWN
      # sweep); neither is observable from the socket, so poll the Server.
      wait_until(fn -> Server.serial_owner(server_name, 0) == nil end)

      {b, _hello, rest_b} = hello(port)
      _rest_b = subscribe(b, 0, rest_b)

      :gen_tcp.close(b)
    end

    test "the same connection may SUBSCRIBE twice: OK both times, one open", %{port: port} do
      {socket, _hello, rest} = hello(port)

      rest = subscribe(socket, 0, rest)
      assert_receive {:open, 0, _opts, _subscriber}
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}

      _rest = subscribe(socket, 0, rest)
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}
      refute_received {:open, 0, _, _}

      :gen_tcp.close(socket)
    end

    test "ownership is per instance: each client owns its own port and is dropped on the other", %{port: port} do
      {a, _hello, rest_a} = hello(port)
      {b, _hello, rest_b} = hello(port)

      _rest_a = subscribe(a, 0, rest_a)
      _rest_b = subscribe(b, 1, rest_b)

      send_struct(b, %Proto.SerialProxyWriteRequest{instance: 0, data: "b-on-0"})
      send_struct(a, %Proto.SerialProxyWriteRequest{instance: 1, data: "a-on-1"})
      send_struct(a, %Proto.SerialProxyWriteRequest{instance: 0, data: "a-on-0"})
      send_struct(b, %Proto.SerialProxyWriteRequest{instance: 1, data: "b-on-1"})

      assert_receive {:write, {:tracking_handle, 0}, "a-on-0"}
      assert_receive {:write, {:tracking_handle, 1}, "b-on-1"}
      refute_received {:write, _, "b-on-0"}
      refute_received {:write, _, "a-on-1"}

      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end
  end

  describe "SET_MODE" do
    test "adapter without set_mode/2: RAW is OK, PROTOCOL is NOT_SUPPORTED", %{port: port} do
      {socket, _hello, rest} = hello(port)
      rest = subscribe(socket, 0, rest)

      set_mode(socket, 0, :SERIAL_PROXY_MODE_RAW)
      rest = assert_ack(socket, rest, 0, :SERIAL_PROXY_REQUEST_TYPE_SET_MODE, :SERIAL_PROXY_STATUS_OK)

      set_mode(socket, 0, :SERIAL_PROXY_MODE_PROTOCOL)
      _rest = assert_ack(socket, rest, 0, :SERIAL_PROXY_REQUEST_TYPE_SET_MODE, :SERIAL_PROXY_STATUS_NOT_SUPPORTED)

      :gen_tcp.close(socket)
    end

    @tag serial_proxy: Espex.Test.ModeTrackingSerialProxy
    test "adapter with set_mode/2: PROTOCOL is OK and observed; UNSUBSCRIBE resets to raw before its ack", %{
      port: port
    } do
      {socket, _hello, rest} = hello(port)
      rest = subscribe(socket, 0, rest)

      set_mode(socket, 0, :SERIAL_PROXY_MODE_PROTOCOL)
      assert_receive {:set_mode, {:tracking_handle, 0}, :protocol}
      rest = assert_ack(socket, rest, 0, :SERIAL_PROXY_REQUEST_TYPE_SET_MODE, :SERIAL_PROXY_STATUS_OK)

      request(socket, 0, @unsubscribe)
      # Reset, unsubscribe, close — all before the ack is written.
      assert_receive {:set_mode, {:tracking_handle, 0}, :raw}
      assert_receive {:request, {:tracking_handle, 0}, :unsubscribe}
      assert_receive {:close, {:tracking_handle, 0}}
      _rest = assert_ack(socket, rest, 0, @unsubscribe, :SERIAL_PROXY_STATUS_OK)

      :gen_tcp.close(socket)
    end

    @tag serial_proxy: Espex.Test.ModeTrackingSerialProxy
    test "an explicit RAW reaches the adapter; UNSUBSCRIBE from raw makes no reset call", %{port: port} do
      {socket, _hello, rest} = hello(port)
      rest = subscribe(socket, 0, rest)

      set_mode(socket, 0, :SERIAL_PROXY_MODE_RAW)
      assert_receive {:set_mode, {:tracking_handle, 0}, :raw}
      rest = assert_ack(socket, rest, 0, :SERIAL_PROXY_REQUEST_TYPE_SET_MODE, :SERIAL_PROXY_STATUS_OK)

      request(socket, 0, @unsubscribe)
      _rest = assert_ack(socket, rest, 0, @unsubscribe, :SERIAL_PROXY_STATUS_OK)
      refute_received {:set_mode, _, _}
      assert_received {:close, {:tracking_handle, 0}}

      :gen_tcp.close(socket)
    end

    @tag serial_proxy: Espex.Test.ModeTrackingSerialProxy
    test "PROTOCOL mode is reapplied on the new handle after CONFIGURE reopens the port", %{port: port} do
      {socket, _hello, rest} = hello(port)
      rest = subscribe(socket, 0, rest)

      set_mode(socket, 0, :SERIAL_PROXY_MODE_PROTOCOL)
      assert_receive {:set_mode, {:tracking_handle, 0}, :protocol}
      rest = assert_ack(socket, rest, 0, :SERIAL_PROXY_REQUEST_TYPE_SET_MODE, :SERIAL_PROXY_STATUS_OK)

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 115_200})
      assert_receive {:close, {:tracking_handle, 0}}
      assert_receive {:open, 0, _opts, _subscriber}
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}
      assert_receive {:set_mode, {:tracking_handle, 0}, :protocol}
      _rest = assert_ack(socket, rest, 0, :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE, :SERIAL_PROXY_STATUS_OK)

      :gen_tcp.close(socket)
    end

    test "a mode outside the enum is INVALID_ARGUMENT", %{port: port} do
      {socket, _hello, rest} = hello(port)
      rest = subscribe(socket, 0, rest)

      set_mode(socket, 0, 7)
      _rest = assert_ack(socket, rest, 0, :SERIAL_PROXY_REQUEST_TYPE_SET_MODE, :SERIAL_PROXY_STATUS_INVALID_ARGUMENT)

      :gen_tcp.close(socket)
    end
  end
end
