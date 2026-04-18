# Espex

ESPHome Native API server library for Elixir.

Espex implements the [ESPHome Native API](https://esphome.io/components/api.html)
protocol over TCP, letting an Elixir application expose itself as an ESPHome
device to clients like Home Assistant. The protocol layer and connection
lifecycle live here; hardware is plugged in through behaviours.

## Status

Early extraction from [`universal_proxy`](https://github.com/bbangert/universal_proxy).
Not yet published to hex.pm.

## Features

- ESPHome Native API frame encoding/decoding — plaintext and
  `Noise_NNpsk0_25519_ChaChaPoly_SHA256` encrypted transports
- TCP server with one process per client connection
- Sub-device support — advertise multiple logical devices under one node
- Built-in message handling for the Serial Proxy, Z-Wave Proxy, and Infrared
  Proxy feature sets
- Server-side state push via `Espex.push_state/2` so adapters and
  `EntityProvider` implementations can update live values
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

- [ ] mDNS advertising helper
- [ ] Client-side library (connect to ESPHome devices instead of being one)

## License

MIT — see [LICENSE](LICENSE).
