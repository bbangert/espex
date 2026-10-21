defmodule Espex.Test.NoiseClient do
  @moduledoc """
  Minimal Noise ESPHome client for the dial-back tests, playing Home
  Assistant's side of a connection the device dialed: read the server
  hello the device sends first, run the initiator handshake, then send
  and receive encrypted structs. A session is `{socket, tx, rx}`.
  """

  alias Espex.{MessageTypes, Noise}
  alias Espex.Noise.Frame, as: NoiseFrame

  @prologue "NoiseAPIInit" <> <<0, 0>>

  @type session :: {:gen_tcp.socket(), Noise.cipher(), Noise.cipher()}

  @doc "Read the server hello frame: `{name, mac}`."
  @spec recv_server_hello(:gen_tcp.socket(), timeout()) :: {:ok, {binary(), binary()}} | {:error, term()}
  def recv_server_hello(socket, timeout \\ 2_000) do
    with {:ok, <<0x01, rest::binary>>} <- recv_outer_frame(socket, timeout) do
      [name, rest] = :binary.split(rest, <<0>>)
      [mac, _] = :binary.split(rest, <<0>>)
      {:ok, {name, mac}}
    end
  end

  @doc "Run the initiator handshake after the server hello was read."
  @spec handshake(:gen_tcp.socket(), <<_::256>>) :: session()
  def handshake(socket, psk) do
    {:ok, noise} = Noise.init(:initiator, psk, @prologue)
    :ok = :gen_tcp.send(socket, NoiseFrame.encode_outer(<<>>))
    {:ok, noise, msg1} = Noise.write_message(noise, <<>>)
    :ok = :gen_tcp.send(socket, NoiseFrame.encode_outer(<<0x00, msg1::binary>>))

    {:ok, <<0x00, msg2::binary>>} = recv_outer_frame(socket)
    {:ok, noise, _} = Noise.read_message(noise, msg2)
    {:ok, tx, rx} = Noise.split(noise)
    {socket, tx, rx}
  end

  @doc "Connect to the device's listener and run the handshake, as a client usually does."
  @spec connect(:inet.port_number(), <<_::256>>) :: session()
  def connect(port, psk) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true, packet: :raw])
    {:ok, noise} = Noise.init(:initiator, psk, @prologue)
    :ok = :gen_tcp.send(socket, NoiseFrame.encode_outer(<<>>))
    {:ok, noise, msg1} = Noise.write_message(noise, <<>>)
    :ok = :gen_tcp.send(socket, NoiseFrame.encode_outer(<<0x00, msg1::binary>>))

    {:ok, _hello} = recv_server_hello(socket)
    {:ok, <<0x00, msg2::binary>>} = recv_outer_frame(socket)
    {:ok, noise, _} = Noise.read_message(noise, msg2)
    {:ok, tx, rx} = Noise.split(noise)
    {socket, tx, rx}
  end

  @spec send_struct(session(), struct()) :: session()
  def send_struct({socket, tx, rx}, struct) do
    {:ok, type, payload} = MessageTypes.encode_parts(struct)
    {:ok, tx, ciphertext} = Noise.encrypt(tx, <<>>, NoiseFrame.encode_inner(type, payload))
    :ok = :gen_tcp.send(socket, NoiseFrame.encode_outer(ciphertext))
    {socket, tx, rx}
  end

  @spec recv_struct(session()) :: {struct(), session()}
  def recv_struct({socket, tx, rx}) do
    {:ok, ciphertext} = recv_outer_frame(socket)
    {:ok, rx, inner} = Noise.decrypt(rx, <<>>, ciphertext)
    {:ok, type, payload} = NoiseFrame.decode_inner(inner)
    {:ok, struct} = MessageTypes.decode_message(type, payload)
    {struct, {socket, tx, rx}}
  end

  defp recv_outer_frame(socket, timeout \\ 2_000) do
    with {:ok, <<0x01, len::unsigned-big-16>>} <- :gen_tcp.recv(socket, 3, timeout) do
      if len == 0, do: {:ok, <<>>}, else: :gen_tcp.recv(socket, len, timeout)
    end
  end
end
