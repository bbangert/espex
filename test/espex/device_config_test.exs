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

  describe "put_psk/2" do
    @raw32 :crypto.hash(:sha256, "rotated")
    @b64 Base.encode64(@raw32)

    test "accepts a 32-byte raw binary" do
      assert {:ok, config} = DeviceConfig.put_psk(DeviceConfig.new(), @raw32)
      assert config.psk == @raw32
      assert DeviceConfig.encrypted?(config)
    end

    test "accepts a base64-encoded 32-byte string" do
      assert {:ok, config} = DeviceConfig.put_psk(DeviceConfig.new(), @b64)
      assert config.psk == @raw32
    end

    test "rejects a wrong-length key without raising or mutating" do
      base = DeviceConfig.new(psk: @raw32)
      assert {:error, :invalid_psk_length} = DeviceConfig.put_psk(base, <<1, 2, 3>>)
      assert {:error, :invalid_psk_length} = DeviceConfig.put_psk(base, "")
    end

    test "rejects a non-UTF-8 binary of the wrong length without raising" do
      # String.trim/1 (used for the base64 path) raises on invalid UTF-8;
      # put_psk/2 must stay total and return a tagged error instead.
      assert {:error, :invalid_psk_length} = DeviceConfig.put_psk(DeviceConfig.new(), <<0xFF, 0xFE>>)
    end
  end

  describe "to_device_info_response" do
    test "api_encryption_supported reflects whether a PSK is set" do
      no_key = DeviceConfig.new()
      assert DeviceConfig.to_device_info_response(no_key).api_encryption_supported == false

      with_key = DeviceConfig.new(psk: :crypto.hash(:sha256, "x"))
      assert DeviceConfig.to_device_info_response(with_key).api_encryption_supported == true
    end

    test "api_encryption_supported is true for a keyless node that opted into provisioning" do
      keyless_optin = DeviceConfig.new(accepts_key_provisioning: true)
      assert keyless_optin.psk == nil
      assert DeviceConfig.to_device_info_response(keyless_optin).api_encryption_supported == true
    end

    test "bluetooth_proxy_feature_flags defaults to 0" do
      config = DeviceConfig.new()
      assert config.bluetooth_feature_flags == 0

      assert DeviceConfig.to_device_info_response(config).bluetooth_proxy_feature_flags == 0
    end

    test "bluetooth_proxy_feature_flags reflects the config bitfield" do
      config = DeviceConfig.new() |> Map.put(:bluetooth_feature_flags, 0x63)

      assert DeviceConfig.to_device_info_response(config).bluetooth_proxy_feature_flags == 0x63
    end
  end
end
