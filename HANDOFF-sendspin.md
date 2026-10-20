# Handoff: ESPHome API 1.18 sync and Sendspin support

Status: investigation done, no code changed. Branch: `claude/affectionate-albattani-l3x5h0`.

## Background

A scheduled check diffed `priv/protos/api.proto` and `api_options.proto` against
ESPHome `dev` (`esphome/components/api/`). espex was last synced to upstream
commit `8d61b35cd` (Sep 14, 2026) and advertises API 1.17
(`lib/espex/device_config.ex:64-65`). Upstream is at 1.18.

Limits of the check: GitHub tools were scoped to espex only, so the comparison used
raw dev-branch files, not tagged releases. No release notes were read, and the
changes below are not pinned to specific upstream commits.

## Findings: no breaking changes, all additive

New messages (ids 153-160):
- `InfraredRFTransmitCompleteResponse` (153)
- `SubscribeSerialProxyIdentityRequest` (154), `SerialProxyIdentity` (155),
  `UsbDeviceDescriptor`, plus identity source and flag enums
- `DeviceWizardRequest` (156), `DeviceWizardResponse` (157), `WizardInputSetRequest` (158)
- `SendspinPairingTokenRequest` (159), `SendspinPairingTokenResponse` (160)

New fields and enums:
- `DeviceCapabilitiesResponse.wizard = 5` (`WizardCapabilities.configured`)
- `DeviceCapabilitiesResponse.sendspin = 6` (`SendspinCapabilities`)
- `HelloRequest.outgoing_connection_target = 4`
- `DeviceInfoResponse.api_outgoing_connection_supported = 27`
- `SERIAL_PROXY_PORT_TYPE_USB_SERIAL = 3`
- `missing_state` on Switch (4), Climate (17) and WaterHeater (9) state responses.
  proto3 default is false, so there is no impact if espex never sets it.

Codegen-only (C++ side, no effect on espex): the `progmem` option in
`api_options.proto`, `container_pointer_no_template` type changes, and the
`USE_IR_RF || USE_RADIO_FREQUENCY` ifdef becoming `USE_IR_RF`.

## Sendspin details

espex is the device side, so it is the one that reports these and answers the request.

```proto
message SendspinCapabilities {
  uint32 feature_flags = 1;                      // bitmask; bits not defined in the proto
  string client_id = 2 [(max_data_length) = 43]; // base64url of client static public key;
                                                 // empty until the client started once since boot
}
```

`SendspinPairingTokenResponse.status` values: `NOT_READY` (0, client not started yet),
`OK` (1), `ENCRYPTION_REQUIRED` (2, device has no API encryption key),
`DISABLED` (3, off and not started since boot), `FAILED` (4, client failed to start
until reboot). The token is set only when status is `OK`.

## Proposed implementation

Existing pattern: each optional feature has a behaviour module plus host-supplied adapter
(`lib/espex/serial_proxy.ex`, `infrared_proxy.ex`, `zwave_proxy.ex`). Capabilities are built in
`DeviceConfig.to_device_capabilities_response/2` (`lib/espex/device_config.ex:326`), and requests are routed in
`lib/espex/dispatch.ex` and `lib/espex/message_types.ex`.

1. Copy upstream `api.proto` and `api_options.proto` into `priv/protos`, then regenerate
   `lib/espex/proto/api.pb.ex` and `api_options.pb.ex` (protoc_gen_elixir 0.17.0).
   Check the git history of the previous sync, commit `44a2154`, for the exact procedure.
2. Register ids 159 and 160 in `message_types.ex`.
3. Add an `Espex.Sendspin` behaviour with callbacks for feature flags, client id (nil
   before the client has started) and pairing token and status. Wire it in as an
   optional adapter the way the other proxies are.
4. Populate `sendspin` in the capabilities response. Leave it nil when no adapter is configured.
5. Handle `SendspinPairingTokenRequest` in `dispatch.ex`. Reply `ENCRYPTION_REQUIRED` when
   the connection has no Noise key.
6. Add tests alongside the existing ones in `test/`, and update the README feature list and `guides/`.
7. Last, raise `@api_version_minor` to 18 and update the version history
   docs near `device_config.ex:269`. Raise it only once the 1.18 messages
   espex advertises are actually handled.

## Open questions for Ben

- **Feature flag bits:** where is the bitmask defined? Check ESPHome's Sendspin component
  or the Sendspin spec. Fallback: let the host pass the raw integer.
- **Pairing token source:** presumably the host's Sendspin client generates it and the
  adapter returns it. Confirm.
- **Scope:** only Sendspin plus the proto sync, or also the other 1.18 features
  (serial identity, IR transmit-complete, wizard)? Note that bumping to 1.18 while
  leaving the others unimplemented may be acceptable, since they are opt-in, but verify
  against how espex treated earlier version bumps.
- **`missing_state`:** should the entity state structs expose it? It lets entities
  report "no valid state yet".

## Notes

- Advertise 1.18 only after step 7's condition is met.
- This file is untracked and uncommitted. Delete it or move it as you prefer.
