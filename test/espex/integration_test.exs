defmodule Espex.IntegrationTest do
  use ExUnit.Case, async: false

  import Espex.Test.TcpClient

  alias Espex.Proto

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

  describe "entity commands (security context)" do
    setup do
      :persistent_term.put(:espex_entity_command_test_pid, self())
      on_exit(fn -> :persistent_term.erase(:espex_entity_command_test_pid) end)
      :ok
    end

    @tag adapters: %{entity_provider: Espex.Test.FakeEntityProvider}
    test "a provider without handle_command/2 still gets handle_command/1", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.ButtonCommandRequest{key: 1})

      assert_receive {:entity_command_1, %Proto.ButtonCommandRequest{key: 1}}, 1_000
      :gen_tcp.close(socket)
    end

    @tag adapters: %{entity_provider: Espex.Test.ContextAwareEntityProvider}
    test "handle_command/2 is preferred and reports an unencrypted connection", %{port: port} do
      socket = connect(port)
      send_struct(socket, %Proto.ButtonCommandRequest{key: 1})

      # Plaintext connection: the provider must be told, so it can refuse
      # privileged commands. AuthenticationRequest is answered
      # unconditionally, so there is no other signal available.
      assert_receive {:entity_command_2, %Proto.ButtonCommandRequest{key: 1}, %{encrypted?: false}},
                     1_000

      refute_receive {:entity_command_1, _}, 100
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
    test "CONFIGURE without prior SUBSCRIBE — PORT_IN_USE, no open (API 1.17 owner rule)", %{port: port} do
      socket = connect(port)

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})

      {:ok, %Proto.SerialProxyRequestResponse{} = ack, _rest} = recv_struct(socket)
      assert ack.type == :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE
      assert ack.status == :SERIAL_PROXY_STATUS_PORT_IN_USE
      # The ack was sent after Dispatch ran — nothing reached the adapter.
      refute_received {:open, _, _, _}

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "SUBSCRIBE then UNSUBSCRIBE: port closed and ownership released — CONFIGURE refused, re-SUBSCRIBE reopens",
         %{port: port} do
      socket = connect(port)
      rest = subscribe(socket, 0)

      assert_receive {:open, 0, _opts, _subscriber}
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}

      send_struct(socket, %Proto.SerialProxyRequest{
        instance: 0,
        type: :SERIAL_PROXY_REQUEST_TYPE_UNSUBSCRIBE
      })

      # The adapter hears :unsubscribe, then the handle is closed, then the
      # ack goes out (after the Server release).
      assert_receive {:request, {:tracking_handle, 0}, :unsubscribe}
      assert_receive {:close, {:tracking_handle, 0}}
      {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_OK}, rest} = recv_struct(socket, rest)

      # No longer owned: CONFIGURE is PORT_IN_USE and nothing is opened.
      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})

      {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_PORT_IN_USE}, rest} =
        recv_struct(socket, rest)

      refute_received {:open, _, _, _}

      # Re-SUBSCRIBE lazily reopens and reattaches, and CONFIGURE works again.
      rest = subscribe(socket, 0, rest)
      assert_receive {:open, 0, _opts1, _subscriber1}
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})

      assert_receive {:close, {:tracking_handle, 0}}
      assert_receive {:open, 0, _opts2, _subscriber2}
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}

      {:ok, %Proto.SerialProxyRequestResponse{type: :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE}, _rest} =
        recv_struct(socket, rest)

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

      # CONFIGURE is acknowledged; the resubscribe adds no frame of its own.
      {:ok, %Proto.SerialProxyRequestResponse{type: :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE}, rest2} =
        recv_struct(socket, rest1)

      assert {:error, :timeout} = recv_struct(socket, rest2, 250)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "WRITE after SUBSCRIBE, without CONFIGURE, reaches the lazily opened port", %{port: port} do
      socket = connect(port)
      _rest = subscribe(socket, 0)

      assert_receive {:open, 0, opts, _subscriber}
      assert opts[:speed] == 9600

      send_struct(socket, %Proto.SerialProxyWriteRequest{instance: 0, data: "ping"})
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

      # CONFIGURE is acknowledged; the resubscribe is silent.
      {:ok, %Proto.SerialProxyRequestResponse{type: :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE}, rest2} =
        recv_struct(socket, rest)

      assert {:error, :timeout} = recv_struct(socket, rest2, 250)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxyWithDefaults}
    test "adapter-supplied default_open_opts/1 is used for the lazy open", context do
      # No separate persistent_term registration needed — every callback
      # delegates to TrackingSerialProxy, whose listener key was already
      # registered by this describe block's setup.
      socket = connect(context.port)
      _rest = subscribe(socket, 0)

      assert_receive {:open, 0, opts, _subscriber}
      assert opts[:speed] == 115_200

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "WRITE after a failed lazy open — write dropped, backoff suppresses retry, CONFIGURE recovers", %{
      port: port
    } do
      :persistent_term.put({Espex.Test.TrackingSerialProxy, :fail_next_open}, true)
      on_exit(fn -> :persistent_term.erase({Espex.Test.TrackingSerialProxy, :fail_next_open}) end)

      socket = connect(port)

      # SUBSCRIBE is the owner's first lazy open; it fails but is acked OK.
      rest = subscribe(socket, 0)
      assert_receive {:open, 0, _opts, _subscriber}

      send_struct(socket, %Proto.SerialProxyWriteRequest{instance: 0, data: "a"})

      # Backoff skips the reopen entirely; :fail_next_open was already
      # erased by the first attempt, so a real retry would have succeeded
      # — the absence of :open here proves the skip, not a coincidence.
      refute_receive {:open, 0, _, _}, 250
      refute_received {:write, _, _}

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})

      # CONFIGURE is exempt from backoff — always attempts an open, and acks it.
      assert_receive {:open, 0, _opts2, _subscriber2}
      {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_OK}, rest} = recv_struct(socket, rest)

      send_struct(socket, %Proto.SerialProxyWriteRequest{instance: 0, data: "a"})
      assert_receive {:write, {:tracking_handle, 0}, "a"}

      # Connection survived the failed open and the backoff throughout.
      send_struct(socket, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{}, _rest} = recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "SET modem pins after SUBSCRIBE reaches the adapter without CONFIGURE", %{port: port} do
      socket = connect(port)
      _rest = subscribe(socket, 0)
      assert_receive {:open, 0, _opts, _subscriber}

      send_struct(socket, %Proto.SerialProxySetModemPinsRequest{instance: 0, line_states: 0x01})
      assert_receive {:set_modem_pins, {:tracking_handle, 0}, true, false}

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "GET modem pins on an unopened, unowned instance lazily opens and reaches the adapter", %{port: port} do
      # GET_MODEM_PINS is read-only and ungated upstream — no SUBSCRIBE needed.
      socket = connect(port)

      send_struct(socket, %Proto.SerialProxyGetModemPinsRequest{instance: 0})

      assert_receive {:open, 0, _opts, _subscriber}
      assert_receive {:get_modem_pins, {:tracking_handle, 0}}

      {:ok, %Proto.SerialProxyGetModemPinsResponse{instance: 0}, _rest} = recv_struct(socket)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "FLUSH after SUBSCRIBE reaches the adapter without CONFIGURE", %{port: port} do
      socket = connect(port)
      rest = subscribe(socket, 0)
      assert_receive {:open, 0, _opts, _subscriber}

      send_struct(socket, %Proto.SerialProxyRequest{instance: 0, type: :SERIAL_PROXY_REQUEST_TYPE_FLUSH})
      assert_receive {:request, {:tracking_handle, 0}, :flush}

      {:ok, %Proto.SerialProxyRequestResponse{status: :SERIAL_PROXY_STATUS_OK}, _rest} = recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.TrackingSerialProxy}
    test "subscribe intent and lazy opens are per-instance", %{port: port} do
      socket = connect(port)
      rest = subscribe(socket, 0)

      assert_receive {:open, 0, _opts0, _subscriber0}
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}

      # GET_MODEM_PINS is ungated, so it lazily opens instance 1 without
      # this connection owning it.
      send_struct(socket, %Proto.SerialProxyGetModemPinsRequest{instance: 1})

      assert_receive {:open, 1, _opts1, _subscriber1}
      assert_receive {:get_modem_pins, {:tracking_handle, 1}}
      {:ok, %Proto.SerialProxyGetModemPinsResponse{instance: 1}, rest} = recv_struct(socket, rest)
      # Instance 0's subscribe intent must not leak onto instance 1's open.
      refute_receive {:request, {:tracking_handle, 1}, :subscribe}, 250

      send_struct(socket, %Proto.SerialProxyConfigureRequest{instance: 0, baudrate: 9600})

      assert_receive {:close, {:tracking_handle, 0}}
      assert_receive {:open, 0, _opts2, _subscriber2}
      assert_receive {:request, {:tracking_handle, 0}, :subscribe}

      # CONFIGURE is acknowledged; the resubscribe adds no frame of its own.
      {:ok, %Proto.SerialProxyRequestResponse{type: :SERIAL_PROXY_REQUEST_TYPE_CONFIGURE}, rest2} =
        recv_struct(socket, rest)

      assert {:error, :timeout} = recv_struct(socket, rest2, 250)

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
