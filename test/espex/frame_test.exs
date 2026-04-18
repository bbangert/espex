defmodule Espex.FrameTest do
  use ExUnit.Case, async: true

  alias Espex.Frame

  doctest Frame

  describe "encode_varint/1 and decode_varint/1" do
    test "round-trips single-byte values" do
      for value <- [0, 1, 42, 127] do
        encoded = Frame.encode_varint(value)
        assert byte_size(encoded) == 1
        assert Frame.decode_varint(encoded) == {:ok, value, <<>>}
      end
    end

    test "round-trips multi-byte boundary values" do
      for value <- [128, 129, 300, 16_383, 16_384, 2_097_151, 2_097_152, 0xFFFFFFFF] do
        encoded = Frame.encode_varint(value)
        assert Frame.decode_varint(encoded) == {:ok, value, <<>>}
      end
    end

    test "decode_varint returns :incomplete on empty buffer" do
      assert Frame.decode_varint(<<>>) == {:incomplete, <<>>}
    end

    test "decode_varint returns :incomplete when continuation bit set but no more bytes" do
      assert Frame.decode_varint(<<0x80>>) == {:incomplete, <<>>}
    end

    test "decode_varint leaves trailing bytes untouched" do
      assert Frame.decode_varint(<<0x05, 1, 2, 3>>) == {:ok, 5, <<1, 2, 3>>}
    end
  end

  describe "encode_frame/2 and decode_frame/1" do
    test "round-trips a small frame" do
      payload = <<10, 5, 104, 101, 108, 108, 111>>
      frame = Frame.encode_frame(1, payload)
      assert Frame.decode_frame(frame) == {:ok, 1, payload, <<>>}
    end

    test "round-trips a frame with a large type id and payload" do
      payload = :crypto.strong_rand_bytes(300)
      frame = Frame.encode_frame(144, payload)
      assert Frame.decode_frame(frame) == {:ok, 144, payload, <<>>}
    end

    test "decode_frame returns :incomplete when buffer truncated mid-frame" do
      payload = <<1, 2, 3, 4, 5>>
      frame = Frame.encode_frame(7, payload)
      truncated = binary_part(frame, 0, byte_size(frame) - 2)
      assert {:incomplete, ^truncated} = Frame.decode_frame(truncated)
    end

    test "decode_frame preserves extra bytes after the frame" do
      payload = <<0xAA, 0xBB>>
      frame = Frame.encode_frame(3, payload)
      buffer = frame <> <<1, 2, 3>>
      assert Frame.decode_frame(buffer) == {:ok, 3, payload, <<1, 2, 3>>}
    end

    test "decode_frame rejects non-plaintext indicator" do
      assert Frame.decode_frame(<<0x01, 0, 0>>) == {:error, {:bad_indicator, 0x01}}
    end

    test "decode_frame returns :incomplete on empty buffer" do
      assert Frame.decode_frame(<<>>) == {:incomplete, <<>>}
    end
  end
end
