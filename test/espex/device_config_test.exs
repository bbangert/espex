defmodule Espex.DeviceConfigTest do
  use ExUnit.Case, async: true

  alias Espex.DeviceConfig

  describe "psk normalisation" do
    @raw32 :crypto.hash(:sha256, "pinky")
    @b64 Base.encode64(@raw32)

    test "nil keeps default (no encryption)" do
      config = DeviceConfig.new()
      assert config.psk == nil
      refute DeviceConfig.encrypted?(config)
    end

    test "32-byte raw binary is accepted verbatim" do
      config = DeviceConfig.new(psk: @raw32)
      assert config.psk == @raw32
      assert DeviceConfig.encrypted?(config)
    end

    test "base64 string is decoded to 32 bytes" do
      config = DeviceConfig.new(psk: @b64)
      assert config.psk == @raw32
    end

    test "base64 string with whitespace around it is trimmed" do
      config = DeviceConfig.new(psk: "  #{@b64}\n")
      assert config.psk == @raw32
    end

    test "wrong-length base64 raises" do
      too_short = Base.encode64(<<1, 2, 3>>)

      assert_raise ArgumentError, ~r/32 bytes/, fn ->
        DeviceConfig.new(psk: too_short)
      end
    end

    test "garbage string raises" do
      assert_raise ArgumentError, ~r/32-byte binary or a base64/, fn ->
        DeviceConfig.new(psk: "not-base64@#$")
      end
    end

    test "non-string, non-binary raises" do
      assert_raise ArgumentError, fn -> DeviceConfig.new(psk: 42) end
      assert_raise ArgumentError, fn -> DeviceConfig.new(psk: [1, 2, 3]) end
    end
  end

  describe "to_device_info_response" do
    test "api_encryption_supported reflects whether a PSK is set" do
      no_key = DeviceConfig.new()
      assert DeviceConfig.to_device_info_response(no_key).api_encryption_supported == false

      with_key = DeviceConfig.new(psk: :crypto.hash(:sha256, "x"))
      assert DeviceConfig.to_device_info_response(with_key).api_encryption_supported == true
    end
  end
end
