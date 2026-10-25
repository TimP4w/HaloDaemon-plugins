<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Logitech implementation review

Reviewed 2026-10-25.
This is a source and mock-transport review, not a hardware certification.
The fixes here are in the source checkout; installed plugin releases are separate.

## Scope

Reviewed HID++ framing and reply matching, receivers and pairing, DPI stages,
host/onboard mode, flash writes, button mappings, battery reporting, report
rates, wheel controls, Fn behavior, brightness, lighting, and audio. The review
also covers daemon state restoration, input handling, and the separate G560
plugin.

Proprietary gaming features, physical LED order, bitmap button IDs, and native
effects need device-specific evidence. Existing hardware behavior was retained
where the protocol comparison did not establish a replacement.

## Defects fixed in this review

1. **P1: programmable controls use the wrong capability bit.** Discovery tested
   `0x08` (Fn-sensitive), rather than `0x20` (divertable). Divertable controls
   could disappear, while unrelated controls could be offered for remapping.
   Corrected and tested with both flag combinations.
2. **P1: diversion writes omit the update-valid bit.** Enable/disable used
   `0x01`/`0x00`; the valid bit is also required, producing `0x03`/`0x02`.
   Firmware can acknowledge a write without applying the intended change.
   Corrected with exact-packet assertions.
3. **P1: enabling a disabled onboard slot restores its factory contents.**
   Enabling now changes only the directory entry. Re-enabling an enabled slot
   does not erase/rewrite flash. Customized profiles survive this operation.
4. **P1: editing a ROM profile redirects its write to a writable profile.**
   The old code masked `0x0101` down to `0x0001`. ROM DPI edits now fail,
   and the flash writer rejects sectors outside the descriptor's writable range.
5. **P2: late errors abort unrelated requests.** Error matching checked the
   feature index alone. It now also checks the full function/software-ID byte.
   HID++ 1 register replies also match the register address; receiver-info
   replies additionally match their bank/slot selector.
6. **P2: zero current DPI does not use the firmware default.** A zero sensor
   DPI now falls back to the default resolution in the same reply.
7. **P2: unchanged onboard DPI edits wear flash.** The patched profile body is
   compared with the existing body before the erase/write/commit sequence.
8. **P2: empty RAM directories hide ROM profiles.** An all-zero/all-FF first
   directory record now triggers a ROM-directory fallback.
9. **P2: unknown flash layouts are decoded as the supported format.** Memory
   type and profile-format bounds are now checked before reading profile data.
10. **P2: battery status uses incompatible magic values.** Voltage charging
    uses bit 7, ADC checks validity and charging bits separately, and unified
    battery status is decoded as an enum. Unified coarse battery levels are
    used when percentage is zero; battery errors are not labeled charging.

The packet fixtures now carry realistic receiver bank echoes and onboard
memory descriptors. Two generic harness operations were added for testing DPI
stage writes and profile enabling through the real daemon capability boundary.
Protocol notes and required upstream attribution were updated.

## Remaining findings

These are not fixed by the protocol changes above.

### P1: custom button mappings are not persisted

`LuaDevice` implements remap setters and keeps a runtime map, but inherits
`KeyRemapCapability`'s empty state key and null saved state. The use case calls
`persist_device_state`, yet the saved object contains no button mappings.
A restart reconstructs plugin defaults instead of restoring user overrides.
The same gap means profile switching cannot restore different button maps.
Saving mappings and enabling hardware reporting are separate operations;
both are necessary.

Additionally, setting a default-mapped button to Native removes its runtime
entry. Reinitialization can seed the plugin default again. Reset-one and
reset-all update the daemon's default-action map while the plugin disables
hardware reporting, so their displayed defaults can disagree with hardware.
A complete fix needs persistence, explicit Native overrides, and consistent
hardware/cache reset semantics, with restart and profile-switch tests.

### P1: saving in onboard mode drops the saved host DPI stages

`DpiCapability::save_state` returns null in onboard mode. The default profile's
persistence path replaces the entire saved device object, so toggling onboard
mode can remove an existing host DPI entry. Restarting onboard and later
returning to host mode seeds stages from the onboard list again. The earlier
host-only restart fix does not cover this sequence. Host stage configuration
needs storage independent of the currently displayed onboard state.

### P2: physical profile/DPI changes do not fully refresh daemon DPI state

The plugin refreshes onboard data on a feature notification, but its DPI
notification path uses the profile's default-resolution index, not the active
resolution index from the notification. The daemon's event path publishes a
state change without refreshing its DPI cache. Explicit UI mode/profile changes
refresh that cache; physical button changes can still leave the displayed
stage/current DPI stale.

Separately, `LuaDevice::set_dpi_steps` sets cached current DPI from the old stage
index although a host stage-list edit sends no sensor-DPI write. Direct DPI
changes do not reconcile the cached stage index. These need invariants tying
reported current/index to actual device state rather than list-edit position.

### P2: receiver connection notifications are never explicitly enabled

Receiver initialization returns capabilities without setting the HID++ 1
notification flags. WIRELESS and SOFTWARE_PRESENT need to be enabled through
register 0x00 (three-byte mask `00 09 00`) with response checking. Receiving
connection notifications currently depends on existing receiver state; the
rebroadcast nudge after pairing is not a substitute. A fix needs receiver-family
fixtures and acknowledged initialization/error handling.

### P2: initialization treats every HID++ error as a sleeping device

The outer initialization wrapper converts any text containing `HID++ error`
into `ok=false`. This includes invalid arguments and invalid function IDs,
which can indicate a protocol bug or an unsupported feature variant. Such
failures become silent rediscovery instead of actionable diagnostics. Preserve
the known powered-off headset cases, but classify errors by origin/code and
operation rather than hiding the whole HID++ error space.

### P2: ROM profile identities are collapsed in the profile UI contract

Onboard status exposes the low byte as a slot, and `switch_profile` writes
`00 <slot>`. This cannot distinguish ROM sector `0x0101` from writable sector
`0x0001`. Full two-byte sector IDs are needed to distinguish read-only profiles.
The flash guard prevents redirecting edits into RAM, but selecting
ROM profiles still needs a compatible capability/UI representation.

### P2: Linux input initialization is attempted only once

If creating either uinput virtual device fails during startup, `main` sends
KeyRemapUnavailable and never starts the input engine. It does not retry when
permissions/device availability recover. Restarting the daemon can therefore
recover injection. The inspected service journal did not establish that this
was the user's particular cold-boot failure; keep it separate from confirmed
wire-level diversion defects.

### G560 and hardware-specific coverage limits

The G560 source reference uses zero after solid-mode RGB; the plugin uses
`0x02`. The reference contains no subwoofer-volume command. Existing mock tests
assert the plugin's own packets and do not establish firmware acceptance.
Retained both behaviors pending hardware captures rather than replacing known
application behavior with an unverified guess.

The SPY backend reports host button presses globally and still does not suppress
native actions per button. That limitation is already documented in hidpp2.md;
The protocol comparison did not establish a reliable per-button suppression command.
Gaming native effects and model-specific keyboard/LED maps also require actual
hardware validation, including reconnect, suspend/resume, and streaming under
button traffic.

## Validation

Run the Logitech and G560 package fixtures through `halod plugin-test`, the
required Nix workspace formatting/tests/Clippy checks, and the plugin signing
tool's ephemeral index/validation flow. Successful mocks verify the listed
packet/state invariants; they do not establish a successful physical cold boot
or validate undocumented gaming commands.
