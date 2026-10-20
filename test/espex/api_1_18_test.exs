defmodule Espex.Api118Test do
  # API 1.18: IR/RF transmit completion, Sendspin, serial proxy identity
  # and the device wizard. Exercised over real TCP. FakeSendspin and
  # TrackingWizard use :persistent_term, which is why this file stays
  # async: false.
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

  defp hello(port, minor \\ 18) do
    socket = connect(port)
    send_struct(socket, %Proto.HelloRequest{client_info: "api118-test", api_version_major: 1, api_version_minor: minor})
    {:ok, %Proto.HelloResponse{} = hello, rest} = recv_struct(socket)
    {socket, hello, rest}
  end

  defp transmit(socket, key, timings \\ [9000, -4500, 560]) do
    send_struct(socket, %Proto.InfraredRFTransmitRawTimingsRequest{key: key, device_id: 5, timings: timings})
  end

  test "hello advertises API 1.18", %{port: port} do
    {socket, hello, _} = hello(port)
    assert {hello.api_version_major, hello.api_version_minor} == {1, 18}
    :gen_tcp.close(socket)
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

    test "an unknown key is refused with success: false", %{port: port} do
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

    test "a client below 1.18 gets no reply, sent or refused", %{port: port} do
      {socket, _hello, rest} = hello(port, 17)
      transmit(socket, 42)
      transmit(socket, 7)
      assert_nothing_sent(socket, rest)
      :gen_tcp.close(socket)
    end

    test "paced frames are each answered", %{port: port} do
      {socket, _hello, rest} = hello(port)

      rest =
        Enum.reduce(1..3, rest, fn _, rest ->
          transmit(socket, 42)

          assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 42, success: true}, rest} =
                   recv_struct(socket, rest)

          rest
        end)

      assert_nothing_sent(socket, rest)
      :gen_tcp.close(socket)
    end

    test "only the requesting connection receives the completion", %{port: port} do
      {a, _hello, rest_a} = hello(port)
      {b, _hello, rest_b} = hello(port)

      transmit(a, 42)
      assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 42, success: true}, _} = recv_struct(a, rest_a)
      assert_nothing_sent(b, rest_b)

      :gen_tcp.close(a)
      :gen_tcp.close(b)
    end
  end

  describe "InfraredRFTransmitCompleteResponse with a slow transmitter" do
    @describetag adapters: %{infrared_proxy: Espex.Test.SlowInfraredProxy}

    setup do
      Espex.Test.SlowInfraredProxy.put_test_pid(self())
    end

    test "the connection answers a ping while its frame is on the air", %{port: port} do
      {socket, _hello, rest} = hello(port)
      transmit(socket, 42)
      assert_receive {:ir_started, task}

      send_struct(socket, %Proto.PingRequest{})
      assert {:ok, %Proto.PingResponse{}, rest} = recv_struct(socket, rest)

      send(task, {:release, :ok})
      assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 42, success: true}, _} = recv_struct(socket, rest)
      :gen_tcp.close(socket)
    end

    test "a request from another client supersedes: the first hears false at once", %{port: port} do
      {a, _hello, rest_a} = hello(port)
      {b, _hello, rest_b} = hello(port)

      transmit(a, 42)
      assert_receive {:ir_started, first}

      transmit(b, 42)
      assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 42, success: false}, rest_a} = recv_struct(a, rest_a)

      # The transmitter runs one frame at a time: the second starts once
      # the first returns, and only its requester hears the result.
      refute_received {:ir_started, _}
      send(first, {:release, :ok})
      assert_receive {:ir_started, second}
      send(second, {:release, :ok})

      assert {:ok, %Proto.InfraredRFTransmitCompleteResponse{key: 42, success: true}, _} = recv_struct(b, rest_b)
      assert_nothing_sent(a, rest_a)

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
      assert_nothing_sent(socket, rest)
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
    test "a plaintext connection gets ENCRYPTION_REQUIRED without asking the adapter", %{port: port} do
      # A raising adapter would log a crash if it were asked.
      Espex.Test.FakeSendspin.put(pairing_token: :raise)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {socket, _hello, rest} = hello(port)
          send_struct(socket, %Proto.SendspinPairingTokenRequest{})

          assert {:ok, %Proto.SendspinPairingTokenResponse{} = resp, _} = recv_struct(socket, rest)
          assert {resp.status, resp.token} == {:SENDSPIN_PAIRING_TOKEN_STATUS_ENCRYPTION_REQUIRED, ""}
          :gen_tcp.close(socket)
        end)

      refute log =~ "pairing_token"
      refute log =~ "secret-token"
    end

    @tag adapters: %{sendspin: Espex.Test.FakeSendspin}
    test "client_id is held to its 43-byte limit", %{port: port} do
      {socket, _hello, rest} = hello(port)
      at_limit = String.duplicate("a", 43)

      Espex.Test.FakeSendspin.put(client_id: at_limit)
      send_struct(socket, %Proto.DeviceCapabilitiesRequest{})

      assert {:ok, %Proto.DeviceCapabilitiesResponse{sendspin: %{client_id: ^at_limit}}, rest} =
               recv_struct(socket, rest)

      Espex.Test.FakeSendspin.put(client_id: at_limit <> "a")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send_struct(socket, %Proto.DeviceCapabilitiesRequest{})
          assert {:ok, %Proto.DeviceCapabilitiesResponse{sendspin: %{client_id: ""}}, _} = recv_struct(socket, rest)
        end)

      assert log =~ "unexpected value"
      :gen_tcp.close(socket)
    end

    @tag adapters: %{sendspin: Espex.Test.FakeSendspin}
    test "a crashing client_id/0 reports an empty client id and keeps the connection", %{port: port} do
      Espex.Test.FakeSendspin.put(client_id: :raise)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {socket, _hello, rest} = hello(port)
          send_struct(socket, %Proto.DeviceCapabilitiesRequest{})
          assert {:ok, %Proto.DeviceCapabilitiesResponse{sendspin: sendspin}, rest} = recv_struct(socket, rest)
          assert sendspin == %Proto.SendspinCapabilities{feature_flags: 1, client_id: ""}
          assert_nothing_sent(socket, rest)
          :gen_tcp.close(socket)
        end)

      assert log =~ "Sendspin capabilities crashed (RuntimeError)"
    end
  end

  describe "SerialProxyIdentity" do
    defp subscribe_identity(port) do
      {socket, _hello, rest} = hello(port)
      send_struct(socket, %Proto.SubscribeSerialProxyIdentityRequest{})
      {socket, rest}
    end

    @tag adapters: %{serial_proxy: Espex.Test.IdentitySerialProxy}
    test "the snapshot has one identity per port, from identity/1", %{port: port} do
      {socket, rest} = subscribe_identity(port)

      assert {:ok, %Proto.SerialProxyIdentity{} = usb, rest} = recv_struct(socket, rest)
      assert {:ok, %Proto.SerialProxyIdentity{} = none, _} = recv_struct(socket, rest)

      assert usb.instance == 0
      assert usb.source == :SERIAL_PROXY_IDENTITY_SOURCE_USB
      assert usb.flags == 1
      assert {usb.manufacturer, usb.product} == {"Nabu Casa", "ZBT-2"}
      assert usb.usb.vendor_id == 0x303A

      assert none == %Proto.SerialProxyIdentity{instance: 1, source: :SERIAL_PROXY_IDENTITY_SOURCE_NONE}
      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.FakeSerialProxyWithOne}
    test "without identity/1 every port reports NONE", %{port: port} do
      {socket, rest} = subscribe_identity(port)

      assert {:ok, %Proto.SerialProxyIdentity{instance: 0, source: :SERIAL_PROXY_IDENTITY_SOURCE_NONE, usb: nil}, _} =
               recv_struct(socket, rest)

      :gen_tcp.close(socket)
    end

    @tag adapters: %{serial_proxy: Espex.Test.IdentitySerialProxy}
    test "a push reaches only subscribed connections", %{port: port, server_name: server_name} do
      {subscribed, rest} = subscribe_identity(port)
      {:ok, _, rest} = recv_struct(subscribed, rest)
      {:ok, _, rest} = recv_struct(subscribed, rest)
      {other, _hello, other_rest} = hello(port)

      identity = %Espex.SerialProxy.Identity{instance: 1, source: :usb, connected?: true, product: "Stick"}
      :ok = Espex.push_serial_proxy_identity(server_name, identity)

      assert {:ok, %Proto.SerialProxyIdentity{instance: 1, product: "Stick"}, _} = recv_struct(subscribed, rest)
      assert_nothing_sent(other, other_rest)

      :gen_tcp.close(subscribed)
      :gen_tcp.close(other)
    end

    @tag adapters: %{serial_proxy: Espex.Test.IdentitySerialProxy}
    test "a push for an unadvertised instance is dropped", %{port: port, server_name: server_name} do
      {socket, rest} = subscribe_identity(port)
      {:ok, _, rest} = recv_struct(socket, rest)
      {:ok, _, rest} = recv_struct(socket, rest)

      :ok = Espex.push_serial_proxy_identity(server_name, %Espex.SerialProxy.Identity{instance: 5})
      assert_nothing_sent(socket, rest)
      :gen_tcp.close(socket)
    end

    test "without a serial adapter the subscribe goes unanswered", %{port: port} do
      {socket, rest} = subscribe_identity(port)
      assert_nothing_sent(socket, rest)
      :gen_tcp.close(socket)
    end
  end

  describe "linked wizard inputs" do
    @describetag adapters: %{wizard: Espex.Test.LinkedWizard, home_assistant_states: Espex.Test.FakeHomeAssistantStates}

    setup do
      Espex.Test.FakeHomeAssistantStates.put_test_pid(self())
      :persistent_term.put({Espex.Test.TrackingWizard, :listener}, self())

      on_exit(fn ->
        Espex.Test.FakeHomeAssistantStates.reset()
        :persistent_term.erase({Espex.Test.TrackingWizard, :listener})
      end)

      %{outdoor: Espex.Wizard.fnv1_hash("outdoor")}
    end

    defp subscribe_states(socket, rest) do
      send_struct(socket, %Proto.SubscribeHomeAssistantStatesRequest{})
      sync(socket, rest)
    end

    defp set_input(socket, key, value),
      do: send_struct(socket, %Proto.WizardInputSetRequest{key: key, entity_id: value})

    # The two entries of the "outdoor" input for `entity_id`, as sent.
    defp recv_links(socket, rest, entity_id) do
      {:ok, %Proto.SubscribeHomeAssistantStateResponse{} = first, rest} = recv_struct(socket, rest)
      {:ok, %Proto.SubscribeHomeAssistantStateResponse{} = second, rest} = recv_struct(socket, rest)

      assert [{first.entity_id, first.attribute}, {second.entity_id, second.attribute}] ==
               [{entity_id, ""}, {entity_id, "unit_of_measurement"}]

      rest
    end

    # A ping round trip orders every earlier frame's handling before it.
    defp sync(socket, rest) do
      send_struct(socket, %Proto.PingRequest{})
      {:ok, %Proto.PingResponse{}, rest} = recv_struct(socket, rest)
      rest
    end

    test "a set sends the linked entries to every subscribed client, the sender included",
         %{port: port, outdoor: outdoor} do
      {sender, _hello, rest_s} = hello(port)
      rest_s = subscribe_states(sender, rest_s)
      {other, _hello, rest_o} = hello(port)
      rest_o = subscribe_states(other, rest_o)
      {quiet, _hello, rest_q} = hello(port)

      set_input(sender, outdoor, "sensor.outdoor")
      assert_receive {:wizard_input_set, ^outdoor, ["sensor.outdoor"]}

      _ = recv_links(sender, rest_s, "sensor.outdoor")
      _ = recv_links(other, rest_o, "sensor.outdoor")
      assert_nothing_sent(quiet, rest_q)

      # Any client's states for the entity now reach the adapter.
      send_struct(quiet, %Proto.HomeAssistantStateResponse{
        entity_id: "sensor.outdoor",
        attribute: "unit_of_measurement",
        state: "°C"
      })

      assert_receive {:ha_state, "sensor.outdoor", "unit_of_measurement", "°C"}

      Enum.each([sender, other, quiet], &:gen_tcp.close/1)
    end

    test "only a new valid value resends, and it replaces the old entries", %{port: port, outdoor: outdoor} do
      {socket, _hello, rest} = hello(port)
      rest = subscribe_states(socket, rest)

      set_input(socket, outdoor, "sensor.a")
      rest = recv_links(socket, rest, "sensor.a")

      # Invalid, the same value again, and an unlinked input: nothing.
      set_input(socket, outdoor, "nodot")
      set_input(socket, outdoor, "sensor.a")
      set_input(socket, Espex.Wizard.fnv1_hash("light"), "light.kitchen")
      rest = sync(socket, rest)

      set_input(socket, outdoor, "sensor.b")
      rest = recv_links(socket, rest, "sensor.b")

      send_struct(socket, %Proto.HomeAssistantStateResponse{entity_id: "sensor.a", state: "1"})
      send_struct(socket, %Proto.HomeAssistantStateResponse{entity_id: "sensor.b", state: "2"})
      rest = sync(socket, rest)
      refute_received {:ha_state, "sensor.a", _, _}
      assert_received {:ha_state, "sensor.b", nil, "2"}

      # Back to A: its entries are sent again, so the device gets A's state.
      set_input(socket, outdoor, "sensor.a")
      _ = recv_links(socket, rest, "sensor.a")
      :gen_tcp.close(socket)
    end

    test "a client that sets an input before subscribing gets it in the walk", %{port: port, outdoor: outdoor} do
      {socket, _hello, rest} = hello(port)
      set_input(socket, outdoor, "sensor.outdoor")
      rest = sync(socket, rest)

      send_struct(socket, %Proto.SubscribeHomeAssistantStatesRequest{})
      rest = recv_links(socket, rest, "sensor.outdoor")
      assert_nothing_sent(socket, rest)
      :gen_tcp.close(socket)
    end
  end

  describe "device wizard" do
    setup do
      key = {Espex.Test.TrackingWizard, :listener}
      :persistent_term.put(key, self())
      on_exit(fn -> :persistent_term.erase(key) end)
    end

    @tag adapters: %{wizard: Espex.Test.TrackingWizard}
    test "capabilities report it, and the client can fetch and decode it", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.DeviceCapabilitiesRequest{})

      assert {:ok, %Proto.DeviceCapabilitiesResponse{wizard: %Proto.WizardCapabilities{configured: true}}, rest} =
               recv_struct(socket, rest)

      send_struct(socket, %Proto.DeviceWizardRequest{})
      assert {:ok, %Proto.DeviceWizardResponse{data: data}, _} = recv_struct(socket, rest)

      assert %{"version" => 1, "pages" => [page]} =
               data |> :zstd.decompress() |> IO.iodata_to_binary() |> JSON.decode!()

      assert page["title"] == "Setup"
      assert page["entities"] == [%{"key" => 1001, "description" => "Test the backlight"}]
      assert [%{"key" => light}, %{"key" => calendars, "multiple" => true, "max_length" => 300}] = page["inputs"]
      assert {light, calendars} == {Espex.Wizard.fnv1_hash("light"), Espex.Wizard.fnv1_hash("calendars")}
      :gen_tcp.close(socket)
    end

    @tag adapters: %{wizard: Espex.Test.TrackingWizard}
    test "a valid input set reaches the adapter; an invalid one does not", %{port: port} do
      {socket, _hello, _rest} = hello(port)
      calendars = Espex.Wizard.fnv1_hash("calendars")

      send_struct(socket, %Proto.WizardInputSetRequest{key: calendars, entity_id: "calendar.a,calendar.b"})
      assert_receive {:wizard_input_set, ^calendars, ["calendar.a", "calendar.b"]}, 1_000

      send_struct(socket, %Proto.WizardInputSetRequest{key: calendars, entity_id: "calendar.a,"})
      send_struct(socket, %Proto.WizardInputSetRequest{key: 1, entity_id: "light.kitchen"})
      assert_nothing_sent(socket)
      refute_received {:wizard_input_set, _, _}
      :gen_tcp.close(socket)
    end

    @tag adapters: %{wizard: Espex.Test.HandBuiltWizard}
    test "a document built without new/1 gets its input keys at accept", %{port: port} do
      {socket, _hello, _rest} = hello(port)
      light = Espex.Wizard.fnv1_hash("light")

      send_struct(socket, %Proto.WizardInputSetRequest{key: light, entity_id: "light.kitchen"})
      assert_receive {:wizard_input_set, ^light, ["light.kitchen"]}, 1_000
      :gen_tcp.close(socket)
    end

    test "without an adapter capabilities report no wizard and the request goes unanswered", %{port: port} do
      {socket, _hello, rest} = hello(port)

      send_struct(socket, %Proto.DeviceCapabilitiesRequest{})
      assert {:ok, %Proto.DeviceCapabilitiesResponse{wizard: nil}, rest} = recv_struct(socket, rest)

      send_struct(socket, %Proto.DeviceWizardRequest{})
      assert_nothing_sent(socket, rest)
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
