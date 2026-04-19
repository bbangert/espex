defmodule Espex.Frame do
  @moduledoc """
  Pure functions for encoding and decoding the ESPHome plaintext wire protocol.

  Each plaintext frame has the format:
  - `0x00` indicator byte
  - VarInt: payload size (protobuf data bytes only)
  - VarInt: message type ID
  - Protobuf-encoded payload bytes

  VarInt encoding follows the Protocol Buffers specification: each byte
  has a continuation bit (MSB) and 7 bits of data, least significant
  bits first.
  """

  import Bitwise

  @plaintext_indicator 0x00

  @doc """
  Encode an unsigned integer as a VarInt binary.

  ## Examples

      iex> Espex.Frame.encode_varint(0)
      <<0>>

      iex> Espex.Frame.encode_varint(300)
      <<172, 2>>

  """
  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(value) when value >= 0, do: do_encode_varint(value)

  defp do_encode_varint(value) when value < 128, do: <<value>>

  defp do_encode_varint(value) do
    byte = (value &&& 0x7F) ||| 0x80
    <<byte, do_encode_varint(value >>> 7)::binary>>
  end

  @doc """
  Decode a VarInt from the beginning of a binary.

  Returns `{:ok, value, rest}` on success, or `{:incomplete, binary}`
  if the binary doesn't contain a complete VarInt.

  ## Examples

      iex> Espex.Frame.decode_varint(<<172, 2, 99>>)
      {:ok, 300, <<99>>}

  """
  @spec decode_varint(binary()) :: {:ok, non_neg_integer(), binary()} | {:incomplete, binary()}
  def decode_varint(data) when is_binary(data) do
    do_decode_varint(data, 0, 0)
  end

  defp do_decode_varint(<<>>, _shift, _acc) do
    {:incomplete, <<>>}
  end

  defp do_decode_varint(<<byte, rest::binary>>, shift, acc) do
    value = acc + ((byte &&& 0x7F) <<< shift)

    if (byte &&& 0x80) == 0 do
      {:ok, value, rest}
    else
      do_decode_varint(rest, shift + 7, value)
    end
  end

  @doc """
  Encode a message into a plaintext protocol frame.

  Takes a message type ID and the protobuf-encoded payload binary.
  Returns the complete frame binary ready to send over TCP.

  ## Examples

      iex> Espex.Frame.encode_frame(1, <<10, 5, 104, 101, 108, 108, 111>>)
      <<0, 7, 1, 10, 5, 104, 101, 108, 108, 111>>

  """
  @spec encode_frame(non_neg_integer(), binary()) :: binary()
  def encode_frame(message_type_id, payload) when is_binary(payload) do
    payload_size = byte_size(payload)
    size_varint = encode_varint(payload_size)
    type_varint = encode_varint(message_type_id)

    <<@plaintext_indicator, size_varint::binary, type_varint::binary, payload::binary>>
  end

  @doc """
  Attempt to decode one frame from a binary buffer.

  Returns:
  - `{:ok, message_type_id, payload_binary, rest}` on success
  - `{:incomplete, buffer}` if not enough data for a complete frame
  - `{:error, reason}` if the frame is malformed

  Designed for use in a TCP receive loop where data may arrive in chunks.
  """
  @spec decode_frame(binary()) ::
          {:ok, non_neg_integer(), binary(), binary()}
          | {:incomplete, binary()}
          | {:error, term()}
  def decode_frame(<<@plaintext_indicator, after_indicator::binary>> = buffer) do
    with {:ok, payload_size, after_size} <- decode_varint(after_indicator),
         {:ok, type_id, after_type} <- decode_varint(after_size),
         <<payload::binary-size(payload_size), rest::binary>> <- after_type do
      {:ok, type_id, payload, rest}
    else
      _ -> {:incomplete, buffer}
    end
  end

  def decode_frame(<<>>) do
    {:incomplete, <<>>}
  end

  def decode_frame(<<indicator, _rest::binary>>) when indicator != @plaintext_indicator do
    {:error, {:bad_indicator, indicator}}
  end
end
