defmodule Espex.PskProvisioningIntegrationTest do
  use ExUnit.Case, async: false

  alias Espex.{Frame, MessageTypes, Noise, Proto, Server}
  alias Espex.Noise.Frame, as: NoiseFrame
  alias Espex.Test.{FailingPskStore, PidPskStore}

  @prologue "NoiseAPIInit" <> <<0, 0>>
  @new_key :crypto.hash(:sha256, "freshly-provisioned-key")

  setup context do
    :persistent_term.put(:espex_psk_test_pid, self())
    on_exit(fn -> :persistent_term.erase(:espex_psk_test_pid) end)

    sup_name = :"espex_sup_#{context.test}"
    server_name = :"espex_server_#{context.test}"

    opts =
      [
        name: sup_name,
        server_name: server_name,
        port: 0,
        device_config:
          context[:device_config] || [name: "espex-psk", project_name: "espex.demo", project_version: "0.0.1"]
      ] ++ (context[:adapters] || [])

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

    %{port: port, server_name: server_name}
  end

  # --- plaintext transport helpers ---

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true, packet: :raw])
    socket
  end

  defp send_struct(socket, struct) do
    {:ok, frame} = MessageTypes.encode_message(struct)
    :ok = :gen_tcp.send(socket, frame)
  end

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

  # --- encrypted transport helpers ---

  defp recv_exact(sock, n, timeout) do
    case :gen_tcp.recv(sock, n, timeout) do
      {:ok, bin} when byte_size(bin) == n -> {:ok, bin}
      other -> other
    end
  end

  defp recv_outer_frame(sock, timeout \\ 1_000) do
    with {:ok, <<0x01, len::unsigned-big-16>>} <- recv_exact(sock, 3, timeout),
         {:ok, body} <- recv_exact(sock, len, timeout) do
      {:ok, body}
    end
  end

  # Perform the full client handshake with `psk`, returning {tx, rx}.
  defp handshake(sock, psk) do
    {:ok, init} = Noise.init(:initiator, psk, @prologue)

    :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(<<>>))
    {:ok, init, msg1} = Noise.write_message(init, <<>>)
    :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(<<0x00, msg1::binary>>))

    {:ok, _server_hello} = recv_outer_frame(sock)
    {:ok, <<0x00, msg2::binary>>} = recv_outer_frame(sock)
    {:ok, init, _} = Noise.read_message(init, msg2)
    {:ok, tx, rx} = Noise.split(init)
    {tx, rx}
  end

  defp send_encrypted(sock, tx, struct) do
    {:ok, type, payload} = MessageTypes.encode_parts(struct)
    inner = NoiseFrame.encode_inner(type, payload)
    {:ok, tx, ct} = Noise.encrypt(tx, <<>>, inner)
    :ok = :gen_tcp.send(sock, NoiseFrame.encode_outer(ct))
    tx
  end

  defp recv_encrypted(sock, rx) do
    {:ok, ct} = recv_outer_frame(sock)
    {:ok, rx, inner} = Noise.decrypt(rx, <<>>, ct)
    {:ok, type, payload} = NoiseFrame.decode_inner(inner)
    {:ok, message} = MessageTypes.decode_message(type, payload)
    {message, rx}
  end

  # Send a plaintext Hello probe and assert the server demands encryption.
  defp assert_requires_encryption(port) do
    sock = connect(port)
    {:ok, frame} = MessageTypes.encode_message(%Proto.HelloRequest{client_info: "probe"})
    :ok = :gen_tcp.send(sock, frame)

    {:ok, rejection} = recv_outer_frame(sock)
    assert <<0x01, "Encryption required">> = rejection
    :gen_tcp.close(sock)
  end

  describe "plaintext bootstrap of a keyless node" do
    @describetag device_config: [
                   name: "espex-psk",
                   project_name: "espex.demo",
                   project_version: "0.0.1",
                   accepts_key_provisioning: true
                 ]
    @describetag adapters: [psk_store: PidPskStore]

    test "advertises encryption, provisions a PSK, and requires it on reconnect", ctx do
      %{port: port, server_name: server_name} = ctx
      sock = connect(port)

      # A keyless node that opted in advertises encryption support — the
      # signal HA uses to offer provisioning.
      send_struct(sock, %Proto.DeviceInfoRequest{})
      {:ok, %Proto.DeviceInfoResponse{api_encryption_supported: true}, _} = recv_struct(sock)

      # Provision the key over plaintext.
      send_struct(sock, %Proto.NoiseEncryptionSetKeyRequest{key: @new_key})
      {:ok, %Proto.NoiseEncryptionSetKeyResponse{success: true}, _} = recv_struct(sock)

      # The store persisted it and the running server adopted it.
      assert_receive {:psk_stored, @new_key}
      assert Server.device_config(server_name).psk == @new_key

      :gen_tcp.close(sock)

      # Next connection now requires encryption — a plaintext probe is rejected.
      assert_requires_encryption(port)
    end
  end

  describe "store failure" do
    @describetag device_config: [
                   name: "espex-psk",
                   project_name: "espex.demo",
                   project_version: "0.0.1",
                   accepts_key_provisioning: true
                 ]
    @describetag adapters: [psk_store: FailingPskStore]

    test "aborts the update and reports success: false", ctx do
      %{port: port, server_name: server_name} = ctx
      sock = connect(port)

      send_struct(sock, %Proto.NoiseEncryptionSetKeyRequest{key: @new_key})
      {:ok, %Proto.NoiseEncryptionSetKeyResponse{success: false}, _} = recv_struct(sock)

      # Server still keyless — the failed write blocked adoption.
      assert Server.device_config(server_name).psk == nil
      :gen_tcp.close(sock)
    end
  end

  describe "plaintext SetKey without opt-in" do
    test "is rejected and leaves the node keyless", ctx do
      %{port: port, server_name: server_name} = ctx
      sock = connect(port)

      send_struct(sock, %Proto.NoiseEncryptionSetKeyRequest{key: @new_key})
      {:ok, %Proto.NoiseEncryptionSetKeyResponse{success: false}, _} = recv_struct(sock)

      assert Server.device_config(server_name).psk == nil
      :gen_tcp.close(sock)
    end
  end

  describe "rotation over an encrypted channel" do
    @original :crypto.hash(:sha256, "original-rotation-psk")
    @describetag device_config: [
                   name: "espex-psk",
                   project_name: "espex.demo",
                   project_version: "0.0.1",
                   psk: :crypto.hash(:sha256, "original-rotation-psk")
                 ]
    @describetag adapters: [psk_store: PidPskStore]

    test "swaps the PSK; the new key handshakes on the next connection", ctx do
      %{port: port, server_name: server_name} = ctx
      sock = connect(port)
      {tx, rx} = handshake(sock, @original)

      _tx = send_encrypted(sock, tx, %Proto.NoiseEncryptionSetKeyRequest{key: @new_key})
      {%Proto.NoiseEncryptionSetKeyResponse{success: true}, _rx} = recv_encrypted(sock, rx)

      assert_receive {:psk_stored, @new_key}
      assert Server.device_config(server_name).psk == @new_key
      :gen_tcp.close(sock)

      # New connection handshakes with the rotated key and reaches an
      # encrypted Hello round-trip.
      sock2 = connect(port)
      {tx2, rx2} = handshake(sock2, @new_key)
      _tx2 = send_encrypted(sock2, tx2, %Proto.HelloRequest{client_info: "after-rotation"})
      {%Proto.HelloResponse{name: "espex-psk"}, _rx2} = recv_encrypted(sock2, rx2)
      :gen_tcp.close(sock2)
    end
  end
end
