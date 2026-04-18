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

- Plaintext ESPHome Native API frame encoding/decoding
- TCP server with one process per client connection
- Built-in message handling for the Serial Proxy, Z-Wave Proxy, and Infrared
  Proxy feature sets
- Pluggable hardware via behaviours:
  - `Espex.SerialProxy.Adapter`
  - `Espex.ZWaveProxy.Adapter`
  - `Espex.InfraredProxy.Adapter`
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

```elixir
Espex.start_link(
  device_config: [name: "my-device", friendly_name: "My Device"],
  serial_proxy: MyApp.MySerialAdapter,
  zwave_proxy: MyApp.MyZWaveAdapter,
  infrared_proxy: MyApp.MyInfraredAdapter,
  entity_provider: MyApp.MyEntities
)
```

Any adapter key you omit disables that feature.

## Development

```sh
mix deps.get
mix compile
mix test
mix credo --strict
mix dialyzer
```

## Roadmap

- [ ] Noise_NNpsk0 encryption (currently plaintext only)
- [ ] mDNS advertising helper
- [ ] Client-side library (connect to ESPHome devices instead of being one)

## License

MPL-2.0
