# Espex

ESPHome Native API server library for Elixir.

Espex implements the [ESPHome Native API](https://esphome.io/components/api.html)
protocol over TCP, letting an Elixir application expose itself as an ESPHome
device to clients like Home Assistant. The protocol layer and connection
lifecycle live here; hardware is plugged in through behaviours.

## Status

Early extraction from [`universal_proxy`](https://github.com/bbangert/universal_proxy).
Still being tested and iterated on, this is not a final API.

## Documentation

Start here once you're ready to go beyond the quickstart below:

- [Architecture guide](guides/architecture.md) — supervision tree,
  the connection/dispatch split, wire protocol, encryption, and how
  `Espex.push_state/2` reaches connected clients.
- [Entity types guide](guides/entity_types.md) — cookbook for the
  common ESPHome entities (Switch, BinarySensor, Sensor, Button,
  Light, Cover, Climate) with proto structs and examples.

Each adapter behaviour's module doc contains a callback reference
and a complete example:

- `Espex.SerialProxy`
- `Espex.ZWaveProxy`
- `Espex.InfraredProxy`
- `Espex.BluetoothScanner`
- `Espex.BluetoothProxy`
- `Espex.EntityProvider`
- `Espex.Mdns`

## Features

- ESPHome Native API frame encoding/decoding — plaintext and
  `Noise_NNpsk0_25519_ChaChaPoly_SHA256` encrypted transports
- Runtime Noise PSK provisioning and rotation — Home Assistant can
  bootstrap a keyless node's key over plaintext (opt-in) or rotate it
  over the encrypted channel, with host-app persistence via
  `Espex.PskStore`
- TCP server with one process per client connection
- Sub-device support — advertise multiple logical devices under one node
- Built-in message handling for the Serial Proxy, Z-Wave Proxy, Infrared
  Proxy, and Bluetooth Proxy feature sets — the BLE side covers passive
  raw-advertisement scanning, active connections with cross-connection
  ownership locking, GATT read / write / notify, pairing, and
  `connections_free` reporting
- Server-side state push via `Espex.push_state/2` so adapters and
  `EntityProvider` implementations can update live values
- Opt-in mDNS advertising (`_esphomelib._tcp`) via `Espex.Mdns` — ships an
  `Espex.Mdns.MdnsLite` adapter over the
  [`mdns_lite`](https://hex.pm/packages/mdns_lite) library for the Nerves
  case, and a behaviour for custom backends
- Pluggable hardware via behaviours:
  - `Espex.SerialProxy`
  - `Espex.ZWaveProxy`
  - `Espex.InfraredProxy`
  - `Espex.BluetoothScanner` (passive raw advertisements)
  - `Espex.BluetoothProxy` (active connect/disconnect, GATT, pairing)
  - `Espex.EntityProvider`
  - `Espex.PskStore` (persist a runtime-provisioned Noise PSK)

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:espex, "~> 0.1"}
  ]
end
```

## Usage

Plaintext (no encryption):

```elixir
Espex.start_link(
  device_config: [name: "my-device", friendly_name: "My Device"],
  serial_proxy: MyApp.MySerialAdapter,
  zwave_proxy: MyApp.MyZWaveAdapter,
  infrared_proxy: MyApp.MyInfraredAdapter,
  entity_provider: MyApp.MyEntities
)
```

Encrypted (Noise_NNpsk0) — set `:psk` to either a 32-byte raw binary or a
base64-encoded string matching the format used in ESPHome YAML:

```elixir
Espex.start_link(
  device_config: [
    name: "my-device",
    friendly_name: "My Device",
    psk: "foIclFXDcBlfzi9oQNegJz/uRG/sgdIc956pX+GrC+A="
  ],
  entity_provider: MyApp.MyEntities
)
```

When a PSK is configured, plaintext clients are rejected with the
standard "encryption required" signal so Home Assistant's ESPHome
integration prompts the user for the key. Any adapter key you omit
disables that feature.

### Runtime key provisioning and rotation

Home Assistant can also set the PSK at runtime via
`NoiseEncryptionSetKeyRequest`. Two flows are supported:

- **Bootstrap (plaintext).** Set `accepts_key_provisioning: true` on a
  keyless node. It then advertises encryption support — HA's trigger to
  offer provisioning — and accepts a key over the plaintext channel.
  The first key crosses the wire in plaintext by protocol design, so
  only enable this on a trusted LAN. The flag is opt-in and defaults to
  `false` (no behaviour change for existing users).
- **Rotation (encrypted).** A node that already has a PSK always accepts
  a new key over its authenticated, encrypted channel — no flag needed.

A provisioned key takes effect on the **next** connection (each
connection copies the PSK at accept time; HA reconnects automatically).
Pass a [`Espex.PskStore`](`Espex.PskStore`) module as `:psk_store` to
persist the key so it survives a restart — without one, espex applies
the key to the running server only and logs a warning:

```elixir
Espex.start_link(
  device_config: [name: "my-device", accepts_key_provisioning: true],
  psk_store: MyApp.FilePskStore
)
```

### mDNS advertising

Advertise the server as a `_esphomelib._tcp` service so ESPHome clients
auto-discover it. Add `:mdns_lite` to your application's deps (it's not
a runtime dep of espex) and wire the shipped adapter:

```elixir
# in your mix.exs
{:mdns_lite, "~> 0.8"}

# at start
Espex.start_link(
  device_config: [name: "my-device", ...],
  mdns: Espex.Mdns.MdnsLite
)
```

For non-Nerves setups (e.g. a host running Avahi), implement your own
adapter against the `Espex.Mdns` behaviour — just `advertise(service)`
and `withdraw(service_id)`:

```elixir
defmodule MyApp.AvahiAdapter do
  @behaviour Espex.Mdns

  @impl true
  def advertise(service), do: MyApp.Avahi.publish(service)

  @impl true
  def withdraw(id), do: MyApp.Avahi.unpublish(id)
end

Espex.start_link(mdns: MyApp.AvahiAdapter, ...)
```

## Development

```sh
mix deps.get
mix compile
mix test
mix credo --strict
mix dialyzer
```

An interactive demo that starts a server advertising a switch, button
and sensor and walks you through an HA connection:

```sh
mix run test/manual/live_demo.exs              # plaintext
ESPEX_ENCRYPT=1 mix run test/manual/live_demo.exs  # Noise-encrypted
```

## Roadmap

- [ ] Client-side library (connect to ESPHome devices instead of being one)

## License

MIT — see [LICENSE](LICENSE).
