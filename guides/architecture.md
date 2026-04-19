# Architecture

Espex is an ESPHome Native API server library for Elixir. It implements
the wire protocol, transport encryption, and connection lifecycle that an
ESPHome client (such as Home Assistant) speaks, and exposes a small set
of behaviours that let your application plug in hardware or virtual
entities. Espex itself does not talk to hardware — that's what the
adapter behaviours are for.

## Supervision tree

`Espex.Supervisor` starts a `:rest_for_one` supervision chain:

1. **`Registry`** (`:duplicate` keys, named per server instance) — every
   accepted connection handler registers itself here so `Espex.push_state/2`
   can fan broadcasts out to subscribers.
2. **`Espex.Server`** — a GenServer holding the stable cross-connection
   state (device config, adapter modules). Short-lived per-connection
   state does not live here; see below.
3. **`ThousandIsland`** — TCP acceptor pool that spawns an
   `Espex.Connection` handler process per client.
4. **`Espex.Mdns.Advertiser`** — optional. Started only if you pass the
   `:mdns` option to `Espex.start_link/1`. It waits for the TCP listener
   to bind (so ephemeral ports work) and then calls your mDNS adapter's
   `advertise/1`.

Because the strategy is `:rest_for_one`, if `Espex.Server` crashes, the
listener and advertiser restart behind it — live connections drop rather
than hold stale references to a replaced server pid.

## Connection and Dispatch

Every accepted TCP connection gets its own handler process. The handler
is intentionally thin — the functional-core / stateful-shell pattern:

- **`Espex.Connection`** (stateful) — buffers incoming bytes, decodes
  frames, interprets actions against this process's socket and the
  configured adapters. Owns everything that touches IO, pids, or
  adapter modules.
- **`Espex.Dispatch`** (pure) — takes the current per-connection state
  and an inbound protobuf message or adapter event, returns an updated
  state plus a list of *actions* describing what should happen next
  (`{:send, struct}`, `{:serial_open, instance, opts}`,
  `{:entity_command, cmd}`, and so on).

Adapter module calls that are just pure function calls on consumer
modules (e.g. `InfraredProxy.list_entities/0`) happen inline in
`Dispatch`. Anything that needs to touch the socket or cross a process
boundary — sending frames, opening ports, subscribing — is emitted as
an action so the handler owns those interactions exclusively. This
split keeps `Dispatch` easy to test with fake adapters and keeps the
handler free of branching on message type.

## Per-connection state

`Espex.ConnectionState` is built once at connection-accept time from
the stable `Espex.Server` state, then threaded through every
`Dispatch.handle_request/2` / `Dispatch.handle_event/2` call. It
contains only inert data — no pids, no process-level concerns.

Three lists are *snapshotted at accept time and frozen* for the
connection's lifetime:

- `serial_proxies` — from `SerialProxy.list_instances/0`
- `infrared_entities` — from `InfraredProxy.list_entities/0`
- `entities` — from `EntityProvider.list_entities/0`

This is a protocol requirement: ESPHome clients cache
`ListEntitiesRequest` / `DeviceInfoRequest` responses for the lifetime
of the connection. Silently changing them mid-connection desyncs the
client. If you need to advertise new entities, the client must
reconnect to pick them up.

## Wire protocol

Two framing layers live on the same TCP byte stream, selected at
connection start based on whether `DeviceConfig.psk` is set.

### Plaintext framing

When no PSK is configured, each message is wrapped as:

- `0x00` indicator byte
- VarInt — payload size (protobuf bytes only)
- VarInt — message type id
- Protobuf-encoded payload

VarInt encoding follows the standard protobuf convention (MSB is a
continuation bit; 7 data bits per byte; little-endian).

### Noise-encrypted framing

When `DeviceConfig.psk` is set, Espex expects
`Noise_NNpsk0_25519_ChaChaPoly_SHA256`. The handshake runs at
connection start. If it fails, or the client sends plaintext bytes
to an encrypted server, the connection is dropped after sending a
protocol-level "encryption required" rejection frame (which is how
Home Assistant's config flow discovers that it needs to prompt the
user for the key).

Post-handshake, two layers of framing are in use:

1. **Outer frame** — `0x01` preamble byte + big-endian `u16` length
   + raw payload. This wraps both handshake messages and post-handshake
   encrypted transport frames.
2. **Inner frame** (post-handshake only) — after decrypting an outer
   frame's payload, the result is `<type:be16><length:be16><payload>`
   where `length` is defined but ignored by the receiver (the actual
   payload length is used instead).

The encrypted transport fully replaces the varint-based plaintext
framing once the handshake completes — every subsequent inbound and
outbound protobuf message flows through the outer+inner path.

## `push_state/2` fan-out

When your application wants to push a state update to every currently
connected client, call `Espex.push_state/2` with any
`%Espex.Proto.*StateResponse{}` struct:

```elixir
Espex.push_state(server_name, %Espex.Proto.SensorStateResponse{
  key: 1003,
  state: 21.5,
  missing_state: false
})
```

Under the hood:

1. Each `Espex.Connection` handler registers with the Registry under
   the `:subscribers` key at accept time.
2. `push_state/2` does a `Registry.dispatch/3` that sends
   `{:espex_state_update, struct}` to every registered pid.
3. Each connection's `handle_info/2` hands the event to
   `Dispatch.handle_event/2`, which returns a `{:send, struct}` action.
4. The handler encodes the protobuf and writes it to the socket.

With no subscribers the dispatch is a silent no-op. Clients that
subscribed via `SubscribeStatesRequest` see the update; others ignore
unknown keys.

## Configuration

Pass options to `Espex.start_link/1` (or `Espex.Supervisor.start_link/1`):

| Option | Default | Purpose |
|--------|---------|---------|
| `:device_config` | `DeviceConfig.new()` | Either a keyword list passed to `DeviceConfig.new/1` or a pre-built `%DeviceConfig{}` |
| `:port` | from `device_config.port` (6053) | TCP listen port; pass `0` for an ephemeral port and read the bound port with `Espex.Supervisor.bound_port/1` |
| `:name` | `Espex.Supervisor` | Registered name for the supervisor |
| `:server_name` | `Espex.Server` | Registered name for `Espex.Server` — pass this same value to `Espex.push_state/2` |
| `:num_acceptors` | `10` | ThousandIsland acceptor pool size |
| `:serial_proxy` | — | Module implementing `Espex.SerialProxy` |
| `:zwave_proxy` | — | Module implementing `Espex.ZWaveProxy` |
| `:infrared_proxy` | — | Module implementing `Espex.InfraredProxy` |
| `:entity_provider` | — | Module implementing `Espex.EntityProvider` |
| `:mdns` | — | Module implementing `Espex.Mdns`, e.g. `Espex.Mdns.MdnsLite` |

Any adapter key you omit disables that feature.

## DeviceConfig

`Espex.DeviceConfig` holds the identity and capabilities advertised to
clients. Construct one with `DeviceConfig.new/1`:

```elixir
DeviceConfig.new(
  name: "my-device",
  friendly_name: "My Device",
  mac_address: "AA:BB:CC:DD:EE:FF",
  project_name: "mycompany.widget",
  project_version: "1.0.0",
  devices: [
    DeviceConfig.Device.new(id: 1, name: "Sensor Pod"),
    DeviceConfig.Device.new(id: 2, name: "Actuator Pod")
  ],
  psk: "foIclFXDcBlfzi9oQNegJz/uRG/sgdIc956pX+GrC+A="
)
```

Most fields are optional. The ones that matter most:

- `name` — required; the ESPHome device name (hostname-style, no
  spaces).
- `friendly_name` — display name shown in Home Assistant.
- `mac_address` — falls back to a deterministic hash of `name` if
  omitted.
- `devices` — list of `Espex.DeviceConfig.Device` structs for sub-devices;
  entities can reference `device_id` to group themselves under one.
- `psk` — pre-shared key for Noise encryption. Accepts either a raw
  32-byte binary or a 44-character base64 string (the format that
  appears in ESPHome YAML).

`DeviceConfig.encrypted?/1` returns whether a PSK is set. The handler
uses this to decide between plaintext and Noise transport at
connection start.
