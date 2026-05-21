defmodule Espex.BluetoothProxyTest do
  use ExUnit.Case, async: true

  alias Espex.BluetoothProxy
  alias Espex.BluetoothProxy.{Characteristic, Descriptor, Service}
  alias Espex.Proto

  describe "encode_uuid/1" do
    test "splits a 128-bit binary into [high, low] uint64s — ESPHome wire is high-first" do
      uuid = <<0x0000180F00001000::64, 0x800000805F9B34FB::64>>

      assert {[0x0000180F00001000, 0x800000805F9B34FB], 0} = BluetoothProxy.encode_uuid(uuid)
    end

    test "passes a short integer through into the short_uuid slot" do
      assert {[], 0x180F} = BluetoothProxy.encode_uuid(0x180F)
    end

    test "handles a short_uuid of zero" do
      assert {[], 0} = BluetoothProxy.encode_uuid(0)
    end
  end

  describe "Descriptor.to_proto/1" do
    test "encodes a 128-bit UUID high-first into the repeated uuid field" do
      uuid = <<0xAAAABBBBCCCCDDDD::64, 0xEEEEFFFF00001111::64>>
      descriptor = Descriptor.new(uuid: uuid, handle: 17)

      assert %Proto.BluetoothGATTDescriptor{
               uuid: [0xAAAABBBBCCCCDDDD, 0xEEEEFFFF00001111],
               handle: 17,
               short_uuid: 0
             } = Descriptor.to_proto(descriptor)
    end

    test "encodes a short UUID into the short_uuid field" do
      descriptor = Descriptor.new(uuid: 0x2902, handle: 5)

      assert %Proto.BluetoothGATTDescriptor{uuid: [], handle: 5, short_uuid: 0x2902} =
               Descriptor.to_proto(descriptor)
    end
  end

  describe "Characteristic.to_proto/1" do
    test "encodes nested descriptors, preserving order" do
      d1 = Descriptor.new(uuid: 0x2901, handle: 11)
      d2 = Descriptor.new(uuid: 0x2902, handle: 12)

      char =
        Characteristic.new(
          uuid: 0x2A37,
          handle: 10,
          properties: 0x10,
          descriptors: [d1, d2]
        )

      assert %Proto.BluetoothGATTCharacteristic{
               uuid: [],
               handle: 10,
               properties: 0x10,
               short_uuid: 0x2A37,
               descriptors: [
                 %Proto.BluetoothGATTDescriptor{handle: 11, short_uuid: 0x2901},
                 %Proto.BluetoothGATTDescriptor{handle: 12, short_uuid: 0x2902}
               ]
             } = Characteristic.to_proto(char)
    end

    test "defaults properties to 0 and descriptors to []" do
      char = Characteristic.new(uuid: 0x2A00, handle: 3)

      assert %Proto.BluetoothGATTCharacteristic{
               properties: 0,
               descriptors: []
             } = Characteristic.to_proto(char)
    end
  end

  describe "Service.to_proto/1" do
    test "round-trips a full service tree" do
      descriptor = Descriptor.new(uuid: 0x2902, handle: 23)

      characteristic =
        Characteristic.new(
          uuid: 0x2A37,
          handle: 22,
          properties: 0x10,
          descriptors: [descriptor]
        )

      service =
        Service.new(
          uuid: 0x180D,
          handle: 21,
          characteristics: [characteristic]
        )

      assert %Proto.BluetoothGATTService{
               uuid: [],
               handle: 21,
               short_uuid: 0x180D,
               characteristics: [
                 %Proto.BluetoothGATTCharacteristic{
                   handle: 22,
                   properties: 0x10,
                   short_uuid: 0x2A37,
                   descriptors: [%Proto.BluetoothGATTDescriptor{handle: 23, short_uuid: 0x2902}]
                 }
               ]
             } = Service.to_proto(service)
    end

    test "encodes a 128-bit service UUID high-first and leaves short_uuid at 0" do
      uuid = <<0x12345678_9ABCDEF0::64, 0x0F0E0D0C_0B0A0908::64>>
      service = Service.new(uuid: uuid, handle: 1)

      assert %Proto.BluetoothGATTService{
               uuid: [0x12345678_9ABCDEF0, 0x0F0E0D0C_0B0A0908],
               handle: 1,
               short_uuid: 0,
               characteristics: []
             } = Service.to_proto(service)
    end

    test "defaults characteristics to []" do
      service = Service.new(uuid: 0x1800, handle: 1)
      assert %Proto.BluetoothGATTService{characteristics: []} = Service.to_proto(service)
    end
  end

  describe "struct enforcement" do
    test "Service requires uuid and handle" do
      assert_raise ArgumentError, ~r/:uuid/, fn -> Service.new(handle: 1) end
      assert_raise ArgumentError, ~r/:handle/, fn -> Service.new(uuid: 0x1800) end
    end

    test "Characteristic requires uuid and handle" do
      assert_raise ArgumentError, ~r/:uuid/, fn -> Characteristic.new(handle: 1) end
      assert_raise ArgumentError, ~r/:handle/, fn -> Characteristic.new(uuid: 0x2A00) end
    end

    test "Descriptor requires uuid and handle" do
      assert_raise ArgumentError, ~r/:uuid/, fn -> Descriptor.new(handle: 5) end
      assert_raise ArgumentError, ~r/:handle/, fn -> Descriptor.new(uuid: 0x2902) end
    end
  end
end
