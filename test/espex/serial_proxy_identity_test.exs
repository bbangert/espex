defmodule Espex.SerialProxy.IdentityTest do
  use ExUnit.Case, async: true

  alias Espex.Proto
  alias Espex.SerialProxy.{Identity, Info}

  describe "to_proto/1" do
    test "defaults to source NONE with no flags, strings or usb descriptor" do
      assert Identity.to_proto(%Identity{instance: 2}) == %Proto.SerialProxyIdentity{
               instance: 2,
               source: :SERIAL_PROXY_IDENTITY_SOURCE_NONE,
               flags: 0,
               usb: nil
             }
    end

    test "USB carries the strings, the flag bits and the descriptor ids" do
      identity =
        Identity.new(
          instance: 0,
          source: :usb,
          connected?: true,
          error?: true,
          manufacturer: "Nabu Casa",
          product: "ZBT-2",
          serial_number: "3c2f19a0",
          usb: %{vendor_id: 0x303A, product_id: 0x4001, port_number: 1}
        )

      proto = Identity.to_proto(identity)
      assert proto.source == :SERIAL_PROXY_IDENTITY_SOURCE_USB
      assert proto.flags == 0b11
      assert {proto.manufacturer, proto.product, proto.serial_number} == {"Nabu Casa", "ZBT-2", "3c2f19a0"}

      assert proto.usb == %Proto.UsbDeviceDescriptor{vendor_id: 0x303A, product_id: 0x4001, port_number: 1}
    end

    test "USB with nothing connected sends an empty descriptor" do
      proto = Identity.to_proto(%Identity{instance: 0, source: :usb})
      assert proto.usb == %Proto.UsbDeviceDescriptor{}
      assert proto.flags == 0
    end

    test "the descriptor is left out for source NONE" do
      assert Identity.to_proto(%Identity{instance: 0, usb: %{vendor_id: 1}}).usb == nil
    end

    test "the identity round-trips through the wire encoding" do
      proto = Identity.to_proto(%Identity{instance: 1, source: :usb, connected?: true, usb: %{vendor_id: 7}})
      assert proto |> Proto.SerialProxyIdentity.encode() |> Proto.SerialProxyIdentity.decode() == proto
    end
  end

  test "Info encodes the USB_SERIAL port type" do
    info = Info.new(instance: 0, name: "usb", port_type: :usb_serial)
    assert Info.to_proto(info).port_type == :SERIAL_PROXY_PORT_TYPE_USB_SERIAL
  end
end
