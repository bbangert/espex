defmodule Espex.EncryptedIntegrationTest do
  use ExUnit.Case, async: false

  alias Espex.{MessageTypes, Noise, Proto}
  alias Espex.Noise.Frame, as: NoiseFrame

  @psk :crypto.hash(:sha256, "espex-encrypted-integration-psk")
  @prologue "NoiseAPIInit" <> <<0, 0>>

  setup context do
    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    {:ok, sup_pid} =
      Espex.start_link(
        name: sup_name,
        server_name: server_name,
        port: 0,
        device_config: [
          name: "espex-encrypted",
          friendly_name: "Espex Encrypted",
          project_name: "espex.demo",
          project_version: "0.0.1",
          mac_address: "AA:BB:CC:DD:EE:FF",
          psk: @psk
        ]
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

  defp connect(port) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true, packet: :raw])

    sock
  end

  # Read exactly `n` bytes, blocking up to `timeout` ms.
  defp recv_exact(sock, n, timeout) do
    case :gen_tcp.recv(sock, n, timeout) do
      {:ok, bin} when byte_size(bin) == n -> {:ok, bin}
      other -> other
    end
  end

  # Read one outer Noise frame from the socket. Returns the payload.
  defp recv_outer_frame(sock, timeout \\ 1_000) do
    with {:ok, <<0x01, len::unsigned-big-16>>} <- recv_exact(sock, 3, timeout),
         {:ok, body} <- recv_exact(sock, len, timeout) do
      {:ok, body}
    end
  end

  describe "noise handshake + encrypted Hello round-trip" do
    test "client handshake completes and HelloResponse decrypts correctly", %{port: port} do
      sock = connect(port)

      # 1) Initialise client-side Noise (initiator).
      {:ok, init} = Noise.init(:initiator, @psk, @prologue)

      # 2) Client sends NOISE_HELLO (empty outer frame).
      :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(<<>>))

      # 3) Client sends handshake-init frame: 0x00 prefix + noise e msg.
      {:ok, init, noise_msg1} = Noise.write_message(init, <<>>)
      :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(<<0x00, noise_msg1::binary>>))

      # 4) Receive ServerHello frame: <0x01 selector><name>\0<mac>\0
      {:ok, server_hello} = recv_outer_frame(sock)
      assert <<0x01, rest::binary>> = server_hello
      [name, rest_after_name] = :binary.split(rest, <<0>>)
      assert name == "espex-encrypted"
      [mac, _tail] = :binary.split(rest_after_name, <<0>>)
      assert mac == "AA:BB:CC:DD:EE:FF"

      # 5) Receive server's handshake response frame: 0x00 + noise e,ee msg
      {:ok, <<0x00, noise_msg2::binary>>} = recv_outer_frame(sock)
      {:ok, init, _empty_payload} = Noise.read_message(init, noise_msg2)

      # 6) Split into cipher states. Client is initiator: tx goes c2s, rx c2c.
      {:ok, tx, rx} = Noise.split(init)

      # 7) Client sends an encrypted HelloRequest.
      {:ok, hello_type, hello_payload} = MessageTypes.encode_parts(%Proto.HelloRequest{client_info: "test-client"})
      inner = NoiseFrame.encode_inner(hello_type, hello_payload)
      {:ok, tx, ct} = Noise.encrypt(tx, <<>>, inner)
      :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(ct))

      # 8) Server responds with encrypted HelloResponse.
      {:ok, resp_ct} = recv_outer_frame(sock)
      {:ok, _rx, resp_inner} = Noise.decrypt(rx, <<>>, resp_ct)
      {:ok, resp_type, resp_payload} = NoiseFrame.decode_inner(resp_inner)
      {:ok, %Proto.HelloResponse{} = resp} = MessageTypes.decode_message(resp_type, resp_payload)

      assert resp.name == "espex-encrypted"
      assert resp.server_info =~ "espex.demo"

      # Sanity: silence unused-binding warnings on tx (advances after encrypt).
      assert tx.n == 1

      :gen_tcp.close(sock)
    end

    test "DeviceInfoResponse has api_encryption_supported: true", %{port: port} do
      sock = connect(port)
      tx_rx = do_handshake(sock)
      {tx, rx} = tx_rx

      {:ok, info_type, info_payload} = MessageTypes.encode_parts(%Proto.DeviceInfoRequest{})
      inner = NoiseFrame.encode_inner(info_type, info_payload)
      {:ok, _tx, ct} = Noise.encrypt(tx, <<>>, inner)
      :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(ct))

      {:ok, resp_ct} = recv_outer_frame(sock)
      {:ok, _rx, resp_inner} = Noise.decrypt(rx, <<>>, resp_ct)
      {:ok, _type, resp_payload} = NoiseFrame.decode_inner(resp_inner)
      {:ok, %Proto.DeviceInfoResponse{} = resp} = MessageTypes.decode_message(10, resp_payload)

      assert resp.api_encryption_supported == true
      assert resp.name == "espex-encrypted"

      :gen_tcp.close(sock)
    end

    test "plaintext probe gets a proper rejection frame and connection close", %{port: port} do
      sock = connect(port)

      # Send a plaintext HelloRequest — preamble byte 0x00. This is what
      # aioesphomeapi sends when no PSK has been configured yet. The server
      # must respond with a rejection frame beginning with 0x01 so the
      # client raises RequiresEncryptionAPIError and HA's config flow
      # prompts for a key.
      {:ok, frame} = MessageTypes.encode_message(%Proto.HelloRequest{client_info: "plaintext-probe"})
      assert <<0x00, _::binary>> = frame

      :ok = :gen_tcp.send(sock, frame)

      # Expect the handshake rejection frame: <0x01><size:be16><0x01><message>
      {:ok, rejection} = recv_outer_frame(sock)
      assert <<0x01, message::binary>> = rejection
      assert message == "Encryption required"

      assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
    end

    test "wrong PSK on client gets a 'Handshake MAC failure' rejection frame", %{port: port} do
      sock = connect(port)

      {:ok, init} = Noise.init(:initiator, :crypto.hash(:sha256, "wrong-psk"), @prologue)

      :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(<<>>))
      {:ok, _init, noise_msg1} = Noise.write_message(init, <<>>)
      :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(<<0x00, noise_msg1::binary>>))

      # Server sends ServerHello OK (that step doesn't use the PSK), then
      # a handshake rejection once the AEAD tag fails to verify under the
      # mismatched PSK, then closes.
      {:ok, _server_hello} = recv_outer_frame(sock)
      {:ok, rejection} = recv_outer_frame(sock)
      assert <<0x01, message::binary>> = rejection
      assert message == "Handshake MAC failure"
      assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
    end
  end

  # Helper: perform the full handshake, return {tx, rx}.
  defp do_handshake(sock) do
    {:ok, init} = Noise.init(:initiator, @psk, @prologue)

    :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(<<>>))
    {:ok, init, msg1} = Noise.write_message(init, <<>>)
    :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(<<0x00, msg1::binary>>))

    {:ok, _server_hello} = recv_outer_frame(sock)
    {:ok, <<0x00, msg2::binary>>} = recv_outer_frame(sock)
    {:ok, init, _} = Noise.read_message(init, msg2)
    {:ok, tx, rx} = Noise.split(init)
    {tx, rx}
  end
end
