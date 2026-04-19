# Espex

ESPHome Native API server library for Elixir.

Espex implements the [ESPHome Native API](https://esphome.io/components/api.html)
protocol over TCP, letting an Elixir application expose itself as an ESPHome
device to clients like Home Assistant. The protocol layer and connection
lifecycle live here; hardware is plugged in through behaviours.

## Status

Early extraction from [`universal_proxy`](https://github.com/bbangert/universal_proxy).
Not yet published to hex.pm.

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
- `Espex.EntityProvider`
- `Espex.Mdns`

## Features

- ESPHome Native API frame encoding/decoding — plaintext and
  `Noise_NNpsk0_25519_ChaChaPoly_SHA256` encrypted transports
- TCP server with one process per client connection
- Sub-device support — advertise multiple logical devices under one node
- Built-in message handling for the Serial Proxy, Z-Wave Proxy, and Infrared
  Proxy feature sets
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
  - `Espex.EntityProvider`

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
