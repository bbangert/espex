defmodule Espex.SerialProxy.Identity do
  @moduledoc since: "0.12.0"
  @moduledoc """
  The identity of the device behind a serial proxy port (API 1.18).

  Clients that subscribe with `SubscribeSerialProxyIdentityRequest` get
  one `SerialProxyIdentity` per advertised port, then another whenever a
  port's identity changes. Home Assistant uses it to tell physical
  devices of the same kind apart, for example two identical Zigbee
  sticks. It matches on `manufacturer` and `product` whatever the
  source.

  An adapter reports identities through the optional
  `c:Espex.SerialProxy.identity/1` callback and pushes changes with
  `Espex.push_serial_proxy_identity/2`. See "Identity" in
  `Espex.SerialProxy`.

  ## Fields

    * `instance` — the `Espex.SerialProxy.Info` instance this describes
    * `source` — `:none` when the port carries no identity (the
      default), `:usb` when it is read from the descriptors of the USB
      device behind the port
    * `connected?` — the device is present and usable on this port
    * `error?` — the USB host stack refused the descriptor query; leave
      the strings and `usb` ids empty
    * `manufacturer`, `product`, `serial_number` — descriptor strings,
      `""` for `:none` and for `:usb` while nothing is connected
    * `usb` — a map of the USB descriptor ids, sent only for `:usb`:
      `:vendor_id`, `:product_id`, `:bcd_device`, `:interface_number`
      (the `bInterfaceNumber` the port is bound through),
      `:interface_class` and `:port_number` (the port's index among those
      a vendor driver exposes on the interface). Missing keys are 0.
  """

  import Bitwise

  alias Espex.Proto

  @type source :: :none | :usb

  @type usb :: %{
          optional(:vendor_id) => non_neg_integer(),
          optional(:product_id) => non_neg_integer(),
          optional(:bcd_device) => non_neg_integer(),
          optional(:interface_number) => non_neg_integer(),
          optional(:interface_class) => non_neg_integer(),
          optional(:port_number) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          instance: non_neg_integer(),
          source: source(),
          connected?: boolean(),
          error?: boolean(),
          manufacturer: String.t(),
          product: String.t(),
          serial_number: String.t(),
          usb: usb() | nil
        }

  @enforce_keys [:instance]
  defstruct [
    :instance,
    source: :none,
    connected?: false,
    error?: false,
    manufacturer: "",
    product: "",
    serial_number: "",
    usb: nil
  ]

  # Bits of ESPHome's SerialProxyIdentityFlag enum.
  @connected_bit 1 <<< 0
  @error_bit 1 <<< 1

  @usb_keys [:vendor_id, :product_id, :bcd_device, :interface_number, :interface_class, :port_number]

  @doc since: "0.12.0"
  @doc """
  Build an `%Identity{}` from keyword options.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc since: "0.12.0"
  @doc """
  Convert to the `SerialProxyIdentity` protobuf message.
  """
  @spec to_proto(t()) :: Proto.SerialProxyIdentity.t()
  def to_proto(%__MODULE__{} = identity) do
    %Proto.SerialProxyIdentity{
      instance: identity.instance,
      source: source_to_proto(identity.source),
      flags: flag(identity.connected?, @connected_bit) ||| flag(identity.error?, @error_bit),
      manufacturer: identity.manufacturer,
      product: identity.product,
      serial_number: identity.serial_number,
      usb: usb_to_proto(identity.source, identity.usb)
    }
  end

  defp source_to_proto(:none), do: :SERIAL_PROXY_IDENTITY_SOURCE_NONE
  defp source_to_proto(:usb), do: :SERIAL_PROXY_IDENTITY_SOURCE_USB

  defp flag(true, bit), do: bit
  defp flag(false, _bit), do: 0

  defp usb_to_proto(:usb, usb) when is_map(usb), do: struct!(Proto.UsbDeviceDescriptor, Map.take(usb, @usb_keys))
  defp usb_to_proto(:usb, nil), do: %Proto.UsbDeviceDescriptor{}
  defp usb_to_proto(:none, _usb), do: nil
end
