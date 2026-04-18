defmodule Espex.Noise.FrameTest do
  use ExUnit.Case, async: true

  alias Espex.Noise.Frame

  describe "outer frame" do
    test "round-trips a non-empty payload" do
      frame = Frame.encode_outer(<<1, 2, 3, 4>>)
      assert <<0x01, 0, 4, 1, 2, 3, 4>> = frame
      assert Frame.decode_outer(frame) == {:ok, <<1, 2, 3, 4>>, <<>>}
    end

    test "round-trips NOISE_HELLO (empty frame)" do
      frame = Frame.encode_outer(<<>>)
      assert frame == <<0x01, 0, 0>>
      assert Frame.decode_outer(frame) == {:ok, <<>>, <<>>}
    end

    test "round-trips a maximum-size (65535-byte) payload" do
      payload = :crypto.strong_rand_bytes(65_535)
      frame = Frame.encode_outer(payload)
      assert byte_size(frame) == 3 + 65_535
      assert Frame.decode_outer(frame) == {:ok, payload, <<>>}
    end

    test "preserves trailing bytes after one frame" do
      frame = Frame.encode_outer(<<0xAA, 0xBB>>)
      assert Frame.decode_outer(frame <> <<9, 9, 9>>) == {:ok, <<0xAA, 0xBB>>, <<9, 9, 9>>}
    end

    test "returns :incomplete when buffer truncated mid-frame" do
      frame = Frame.encode_outer(<<1, 2, 3, 4, 5>>)
      truncated = binary_part(frame, 0, byte_size(frame) - 2)
      assert {:incomplete, ^truncated} = Frame.decode_outer(truncated)
    end

    test "returns :incomplete when only header is available" do
      assert {:incomplete, <<0x01>>} = Frame.decode_outer(<<0x01>>)
      assert {:incomplete, _} = Frame.decode_outer(<<0x01, 0>>)
    end

    test "returns :incomplete on empty buffer" do
      assert Frame.decode_outer(<<>>) == {:incomplete, <<>>}
    end

    test "rejects wrong preamble byte (0x00 is the plaintext path, invalid here)" do
      assert Frame.decode_outer(<<0x00, 0, 0>>) == {:error, {:bad_preamble, 0x00}}
      assert Frame.decode_outer(<<0x42, 0, 0>>) == {:error, {:bad_preamble, 0x42}}
    end
  end

  describe "inner frame" do
    test "round-trips a type id + payload" do
      payload = <<42, 99, 100>>
      bin = Frame.encode_inner(7, payload)
      assert <<0, 7, 0, 3, 42, 99, 100>> = bin
      assert {:ok, 7, ^payload} = Frame.decode_inner(bin)
    end

    test "decode_inner uses remaining bytes as payload, ignoring the length field" do
      # Intentionally wrong length value — receiver must still consume all remaining bytes.
      buggy = <<0, 42, 0xFF, 0xFF, 1, 2, 3>>
      assert {:ok, 42, <<1, 2, 3>>} = Frame.decode_inner(buggy)
    end

    test "encode_inner accepts empty payload" do
      assert <<0, 5, 0, 0>> = Frame.encode_inner(5, <<>>)
    end

    test "decode_inner rejects binaries shorter than the header" do
      assert {:error, :inner_frame_too_short} = Frame.decode_inner(<<1, 2, 3>>)
    end
  end
end
