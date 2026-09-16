defmodule Espex.Test.TcpClient do
  @moduledoc """
  Minimal plaintext ESPHome client for the real-TCP integration tests:
  connect, send a protobuf struct, receive and decode one frame, and a
  polling wait for state that has no notification (e.g. a pre-hello
  Registry entry).
  """

  import ExUnit.Assertions

  alias Espex.{Frame, MessageTypes, Proto}

  @spec connect(:inet.port_number()) :: :gen_tcp.socket()
  def connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, nodelay: true, packet: :raw])
    socket
  end

  @spec send_struct(:gen_tcp.socket(), struct()) :: :ok
  def send_struct(socket, struct) do
    {:ok, frame} = MessageTypes.encode_message(struct)
    :ok = :gen_tcp.send(socket, frame)
  end

  @doc """
  Decode the next complete frame from `buffer`, reading more from the
  socket as needed. Returns `{:ok, struct, rest}` or the recv error.
  """
  @spec recv_struct(:gen_tcp.socket(), binary(), timeout()) :: {:ok, struct(), binary()} | {:error, term()}
  def recv_struct(socket, buffer \\ <<>>, timeout \\ 1_000) do
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

  @doc """
  SUBSCRIBE `instance` and consume its `OK` acknowledgement — the API
  1.17 ownership step every other serial request needs first. Returns the
  leftover buffer.
  """
  @spec subscribe(:gen_tcp.socket(), non_neg_integer(), binary()) :: binary()
  def subscribe(socket, instance, buffer \\ <<>>) do
    send_struct(socket, %Proto.SerialProxyRequest{instance: instance, type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE})

    assert {:ok,
            %Proto.SerialProxyRequestResponse{
              instance: ^instance,
              type: :SERIAL_PROXY_REQUEST_TYPE_SUBSCRIBE,
              status: :SERIAL_PROXY_STATUS_OK
            }, rest} = recv_struct(socket, buffer)

    rest
  end

  @doc """
  Poll `check` until it returns true or `deadline_ms` elapses. Only for
  state with no observable event to wait on.
  """
  @spec wait_until((-> boolean()), pos_integer()) :: :ok
  def wait_until(check, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_until(check, deadline)
  end

  defp do_wait_until(check, deadline) do
    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("wait_until timed out")

      true ->
        Process.sleep(5)
        do_wait_until(check, deadline)
    end
  end
end
