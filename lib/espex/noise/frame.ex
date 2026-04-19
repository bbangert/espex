defmodule Espex.Noise.Frame do
  @moduledoc false

  @preamble 0x01
  @header_size 3

  @doc """
  Attempt to decode one outer Noise frame from `buffer`.

  Returns:

    * `{:ok, payload, rest}` — one full frame consumed
    * `{:incomplete, buffer}` — need more bytes
    * `{:error, reason}` — malformed (currently only `:bad_preamble`)
  """
  @spec decode_outer(binary()) ::
          {:ok, binary(), binary()} | {:incomplete, binary()} | {:error, term()}
  def decode_outer(<<@preamble, len::unsigned-big-16, rest::binary>> = buffer) do
    if byte_size(rest) >= len do
      <<payload::binary-size(len), remaining::binary>> = rest
      {:ok, payload, remaining}
    else
      {:incomplete, buffer}
    end
  end

  def decode_outer(<<>>), do: {:incomplete, <<>>}
  def decode_outer(<<only_byte>>) when only_byte == @preamble, do: {:incomplete, <<only_byte>>}
  def decode_outer(<<only_byte, _rest::binary-size(1)>> = buf) when only_byte == @preamble, do: {:incomplete, buf}
  def decode_outer(<<other, _rest::binary>>) when other != @preamble, do: {:error, {:bad_preamble, other}}
  def decode_outer(buffer) when is_binary(buffer), do: {:incomplete, buffer}

  @doc """
  Encode the outer frame. `payload` is whatever goes inside — a
  handshake message during handshake, or an encrypted inner-frame
  ciphertext post-handshake.
  """
  @spec encode_outer(binary()) :: binary()
  def encode_outer(payload) when is_binary(payload) do
    <<@preamble, byte_size(payload)::unsigned-big-16, payload::binary>>
  end

  @doc """
  Build an inner frame from a message type id + protobuf payload.
  Used post-handshake as the plaintext input to `Noise.encrypt/3`.
  """
  @spec encode_inner(non_neg_integer(), binary()) :: binary()
  def encode_inner(type_id, payload) when is_binary(payload) do
    <<type_id::unsigned-big-16, byte_size(payload)::unsigned-big-16, payload::binary>>
  end

  @doc """
  Parse an inner frame. Returns `{type_id, payload}` using the full
  remaining bytes as the payload (the `length` field is present for
  historical reasons but ignored, per aioesphomeapi).
  """
  @spec decode_inner(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, term()}
  def decode_inner(<<type_id::unsigned-big-16, _length::unsigned-big-16, payload::binary>>) do
    {:ok, type_id, payload}
  end

  def decode_inner(_), do: {:error, :inner_frame_too_short}

  @doc "Size of the outer frame header (preamble + length)."
  @spec header_size() :: 3
  def header_size, do: @header_size
end
