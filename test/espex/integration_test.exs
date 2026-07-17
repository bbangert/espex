defmodule Espex.IntegrationTest do
  use ExUnit.Case, async: false

  alias Espex.{Frame, MessageTypes, Proto}

  setup context do
    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    opts =
      [
        name: sup_name,
        server_name: server_name,
        port: 0,
        device_config: [
          name: "test-device",
          friendly_name: "Test",
          project_name: "espex_test",
          project_version: "0.0.1"
        ]
      ] ++ Map.to_list(context[:adapters] || %{})

    {:ok, sup_pid} = Espex.start_link(opts)
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

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true, packet: :raw])
    socket
  end

  defp send_struct(socket, struct) do
    {:ok, frame} = MessageTypes.encode_message(struct)
    :ok = :gen_tcp.send(socket, frame)
  end

  # Read one decoded message from the socket. Returns {:ok, message, leftover_buffer}
  # — pass `leftover_buffer` into the next call to continue reading.
  defp recv_struct(socket, buffer \\ <<>>, timeout \\ 1_000) do
    case Frame.decode_frame(buffer) do
      {:ok, type_id, payload, rest} ->
        {:ok, module} = MessageTypes.module_for_id(type_id)
        {:ok, module.decode(payload), rest}

      _ ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, data} -> recv_struct(socket, buffer <> data, timeout)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  describe "hello round-trip" do
    test "HelloRequest → HelloResponse", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.HelloRequest{client_info: "integration-test"})
      {:ok, response, _} = recv_struct(socket)

      assert %Proto.HelloResponse{name: "test-device", server_info: info} = response
      assert info =~ "espex_test"
      :gen_tcp.close(socket)
    end
  end

  describe "device info" do
    test "DeviceInfoRequest returns the configured device fields", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{} = info, _} = recv_struct(socket)

      assert info.name == "test-device"
      assert info.friendly_name == "Test"
      assert info.project_name == "espex_test"
      assert info.project_version == "0.0.1"
      assert info.serial_proxies == []
      assert info.zwave_proxy_feature_flags == 0
      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.FakeSerialProxyWithOne}
    test "DeviceInfoResponse includes serial proxies from the adapter", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{serial_proxies: proxies}, _} = recv_struct(socket)

      assert [%Proto.SerialProxyInfo{name: "zigbee", port_type: :SERIAL_PROXY_PORT_TYPE_TTL}] = proxies
      :gen_tcp.close(socket)
    end
  end

  describe "list entities" do
    test "with no adapters, returns only Done", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.ListEntitiesRequest{})
      {:ok, %Proto.ListEntitiesDoneResponse{}, _} = recv_struct(socket)
      :gen_tcp.close(socket)
    end

    @tag adapters: %{entity_provider: Espex.Test.FakeEntityProvider}
    test "with EntityProvider, returns custom entities then Done", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.ListEntitiesRequest{})

      {:ok, %Proto.ListEntitiesBinarySensorResponse{name: "Fake"}, rest} = recv_struct(socket)
      {:ok, %Proto.ListEntitiesDoneResponse{}, _} = recv_struct(socket, rest)
      :gen_tcp.close(socket)
    end
  end

  describe "disconnect" do
    test "DisconnectRequest gets a response and the server closes the socket", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.DisconnectRequest{})
      {:ok, %Proto.DisconnectResponse{}, _rest} = recv_struct(socket)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    end
  end

  describe "serial proxy lazy open + subscription intent" do
    setup context do
      key = {Espex.Test.TrackingSerialProxy, context.test}
      :persistent_term.put(key, self())
      on_exit(fn -> :persistent_term.erase(key) end)
      :ok
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "SUBSCRIBE alone lazily opens with fallback defaults and subscribes", %{port: port} do
      socket = connect(port)

      send_struct(socket, %Proto.SerialProxyRequest{
        instance: 0,
        type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
      })

      assert_receive {:open, 0, opts, subscriber}
      assert is_pid(subscriber)
      assert opts[:speed] == 9600

      assert_receive {:request, {:tracking_handle, 0}, :subscribe}

      {:ok, %Proto.SerialProxyRequestResponse{} = ack, rest} = recv_struct(socket)
      assert ack.instance == 0
      assert ack.type == :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
      assert ack.status == :SERIAL_PROXY_STATUS_OK

      # Exactly one response on the wire — the resubscribe inside :serial_open
      # never triggers a second SerialProxyRequestResponse.
      assert {:error, :timeout} = recv_struct(socket, rest, 250)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "CONFIGURE without prior SUBSCRIBE — open only, no subscribe request", %{port: port} do
      socket = connect(port)

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})

      assert_receive {:open, 0, _opts, _subscriber}
      refute_receive {:request, _, :subscribe}, 250

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "SUBSCRIBE then UNSUBSCRIBE: intent cleared — later CONFIGURE does not resubscribe", %{port: port} do
      socket = connect(port)

      send_struct(socket, %Proto.SerialProxyRequest{
        instance: 0,
        type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
      })

      assert_receive {:open, 0, _opts, _subscriber}
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}
      {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_OK}, rest1} = recv_struct(socket)

      send_struct(socket, %Proto.SerialProxyRequest{
        instance: 0,
        type: :SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE
      })

      # Port is already open, so unsubscribe goes straight to the adapter.
      assert_receive {:request, {:tracking_handle, 0}, :unsubscribe}
      {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_OK}, _rest2} = recv_struct(socket, rest1)

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})

      assert_receive {:close, {:tracking_handle, 0}}
      assert_receive {:open, 0, _opts2, _subscriber2}
      refute_receive {:request, _, :subscribe}, 250

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "subscription persists across reconfigure", %{port: port} do
      socket = connect(port)

      send_struct(socket, %Proto.SerialProxyRequest{
        instance: 0,
        type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
      })

      assert_receive {:open, 0, _opts1, _subscriber1}
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}
      {:ok, %Proto.SerialProxyRequestResponse{}, rest1} = recv_struct(socket)

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 115_200})

      assert_receive {:close, {:tracking_handle, 0}}
      assert_receive {:open, 0, opts2, _subscriber2}
      assert opts2[:speed] == 115_200

      # Reattached on the new handle — resubscribe-on-reconfigure is the contract.
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}

      # No extra wire response for the resubscribe — only the original ack.
      assert {:error, :timeout} = recv_struct(socket, rest1, 250)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "WRITE without CONFIGURE lazily opens and writes", %{port: port} do
      socket = connect(port)

      send_struct(socket, %Proto.SerialProxyWriteRequest{instance: 0, data: "ping"})

      assert_receive {:open, 0, opts, _subscriber}
      assert opts[:speed] == 9600
      assert_receive {:write, {:tracking_handle, 0}, "ping"}

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "SUBSCRIBE with failing open — OK acked, intent survives, next CONFIGURE attaches", %{port: port} do
      :persistent_term.put({Espex.Test.TrackingSerialProxy, :fail_next_open}, true)
      on_exit(fn -> :persistent_term.erase({Espex.Test.TrackingSerialProxy, :fail_next_open}) end)

      socket = connect(port)

      send_struct(socket, %Proto.SerialProxyRequest{
        instance: 0,
        type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE
      })

      assert_receive {:open, 0, _opts, _subscriber}
      refute_receive {:request, _, :subscribe}, 250

      {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_OK}, rest} = recv_struct(socket)

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})

      assert_receive {:open, 0, _opts2, _subscriber2}
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}

      # No second SerialProxyRequestResponse — the resubscribe is silent.
      assert {:error, :timeout} = recv_struct(socket, rest, 250)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxyWithDefaults}
    test "adapter-supplied default_open_opts/1 is used for the lazy open", context do
      key = {Espex.Test.TrackingSerialProxyWithDefaults, context.test}
      :persistent_term.put(key, self())
      on_exit(fn -> :persistent_term.erase(key) end)

      socket = connect(context.port)
      send_struct(socket, %Proto.SerialProxyWriteRequest{instance: 0, data: "ping"})

      assert_receive {:open, 0, opts, _subscriber}
      assert opts[:speed] == 115_200

      :gen_tcp.close(socket)
    end
  end

  describe "push_state/2" do
    test "broadcasts a StateResponse struct to every connected client", context do
      server_name = :"espex_server_#{context.test}"
      socket1 = connect(context.port)
      socket2 = connect(context.port)

      # Both clients must be registered before broadcast.
      # Force each through the handshake so we know their Connection process has
      # finished handle_connection (and therefore Registry.register).
      for sock <- [socket1, socket2] do
        send_struct(sock, %Proto.HelloRequest{})
        {:ok, %Proto.HelloResponse{}, _} = recv_struct(sock)
      end

      :ok = Espex.push_state(server_name, %Proto.SensorStateResponse{key: 99, state: 42.5})

      for sock <- [socket1, socket2] do
        {:ok, %Proto.SensorStateResponse{key: 99, state: state}, _} = recv_struct(sock)
        assert_in_delta state, 42.5, 0.01
      end

      :gen_tcp.close(socket1)
      :gen_tcp.close(socket2)
    end
  end

  describe "Z-Wave home ID" do
    @tag adapters: %{zwave_proxy: Espex.Test.FakeZWaveProxyWithHomeId}
    test "pushed to a client at handshake even without subscribing", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.HelloRequest{client_info: "zwave-js"})
      {:ok, %Proto.HelloResponse{}, rest} = recv_struct(socket)

      # No SUBSCRIBE sent — the auth-time push must still arrive.
      {:ok, %Proto.ZWaveProxyRequest{type: type, data: data}, _} = recv_struct(socket, rest)
      assert type == :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE
      assert data == <<0xDE, 0xAD, 0xBE, 0xEF>>

      :gen_tcp.close(socket)
    end

    @tag adapters: %{zwave_proxy: Espex.Test.FakeZWaveProxyWithHomeId}
    test "push_zwave_home_id/2 broadcasts to every client, subscribed or not", context do
      server_name = :"espex_server_#{context.test}"
      socket1 = connect(context.port)
      socket2 = connect(context.port)

      # Handshake both, and drain the auth-time push each receives so the
      # buffers are clean before the broadcast under test.
      buffers =
        for sock <- [socket1, socket2] do
          send_struct(sock, %Proto.HelloRequest{})
          {:ok, %Proto.HelloResponse{}, rest} = recv_struct(sock)
          {:ok, %Proto.ZWaveProxyRequest{}, rest} = recv_struct(sock, rest)
          {sock, rest}
        end

      :ok = Espex.push_zwave_home_id(server_name, <<1, 2, 3, 4>>)

      for {sock, buf} <- buffers do
        {:ok, %Proto.ZWaveProxyRequest{type: type, data: <<1, 2, 3, 4>>}, _} = recv_struct(sock, buf)
        assert type == :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE
      end

      :gen_tcp.close(socket1)
      :gen_tcp.close(socket2)
    end
  end
end
