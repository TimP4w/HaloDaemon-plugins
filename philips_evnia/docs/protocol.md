# Philips Evnia protocols

Two independent USB protocols exposed by the Philips Evnia 49 (49M2C8900) monitor: DDC/CI for picture, OSD, input, audio, and monitor settings, and Ambiglow for the rear RGB LEDs. Full wire detail lives in the package-owned sub-pages [ddc-ci.md](ddc-ci.md) and [ambiglow.md](ambiglow.md).

**Credits:** DDC/CI follows the VESA DDC/CI and MCCS standards; the Ambiglow control path (capture-block enable, `0xE100` frame buffer, baseline restore) is adapted from [tomasf/evnia](https://github.com/tomasf/evnia) (MIT).

---

## Overview

The monitor presents two separate USB devices, both driven by this one plugin:

- **DDC/CI** (USB hub chip, `2109:8884`, interface 0, transport id `primary`): MCCS commands tunnelled in USB vendor control transfers. Host-initiated request/response; writes are fire-and-forget, reads are a request followed by a delayed reply.
- **Ambiglow** (ENE KB7730 RGB controller, `0cf2:b201`, interface 0, transport id `ambiglow`): a flat register write space over USB vendor control-OUTs. Write-only; streams the 44 RGB LEDs around the panel. A host-link register decides whether the host or the monitor scaler owns the LEDs; the scaler's own Ambiglow effects are selected over DDC/CI.

Neither device sends unsolicited data.

---

## 1. Packet layout

### DDC/CI (see [ddc-ci.md §1](ddc-ci.md#1-packet-layout))

Every frame is a DDC/CI envelope ending in an XOR checksum:

```text
0x6E  0x51  (0x80|len)  opcode  payload…  xor
```

Set-VCP writes are 8 bytes (standard VCP) or 10 bytes (Philips vendor VCP `0xE2 0xA0` plus a sub-command byte); Get requests are 6, 8, or 10 bytes (standard, extended, info-string). Outbound checksums fold from seed `0x00`; reply checksums from seed `0x50`.

### Ambiglow (see [ambiglow.md §1](ambiglow.md#1-control-model))

No framing at all: each operation is one vendor control-OUT with the register address in `wIndex` and the raw value bytes in the data stage. Three register regions:

| Region | `wIndex` | Payload |
| --- | --- | --- |
| Host link | `0x0023` | 1 byte: `0x04` host owns the LEDs, `0x00` scaler owns them |
| Zone blocks | `0xE020`, `0xE030`, `0xE040`, `0xE050` | 16 bytes each (source, effect mode, speed, direction, brightness, commit) |
| Frame buffer | `0xE100` | 44 x 3 = 132 RGB bytes |

---

## 2. Functions

### DDC/CI (see [ddc-ci.md §2](ddc-ci.md#2-functions))

- **Set VCP:** standard or extended Set frame, control-OUT, no acknowledgement; a 50 ms minimum gap is enforced between writes.
- **Get VCP:** write the Get request, wait 150 ms, control-IN a 32-byte reply, verify checksum, take the big-endian u16 value.
- **Get info string:** same read flow with the `0xFE` info-string opcode and a 4-byte page address; used at initialize to read the model number.
- **Mode-scoped state:** picture values are stored per SmartImage preset, and SDR/HDR presets expose different controls. The startup read set, the control dependency rules and the status-poll refresh are in [ddc-ci.md §5–§7](ddc-ci.md#7-control-dependencies).

### Ambiglow (see [ambiglow.md §2](ambiglow.md#2-functions))

- **Arm capture:** host link `0x04`, then the 16-byte capture block to `0xE020` and `0xE030`. Idempotent; armed lazily before the first frame.
- **Write frame:** one 132-byte `[R, G, B]` write to `0xE100` for the whole 44-LED strip.
- **Release:** after a 10 ms frame-settle wait, write the 64-byte baseline block to `0xE020` and host link `0x00`. The scaler then resumes the effect selected by DDC `E2A0 19`.
- **Native effects:** Off, Follow Video and Follow Audio are scaler effects selected over DDC after a release. Static, Color Shift, Color Wave, Breathing and Starry Night run on the ENE controller with the chosen RGB colour (optional rainbow), brightness and speed. "Monitor (firmware control)" re-selects the scaler mode read at initialize; it also runs on close. Effect changes write only what changes, to avoid visible flashes.

---

## 3. Parameters

Control-transfer parameters per device:

| Device | Direction | `bmRequestType` | `bRequest` | `wValue` | `wIndex` |
| --- | --- | --- | --- | --- | --- |
| DDC/CI | write | `0x40` | `0xB2` | `0` | `0` |
| DDC/CI | read | `0xC0` | `0xA3` | `0` | `0x006F` |
| Ambiglow | write | `0x40` | `0x80` | `0` | register address |

Timing: 50 ms DDC write gap, 150 ms DDC reply delay, 10 ms Ambiglow frame-settle before release, 1000 ms Ambiglow transfer timeout.

The Ambiglow zone is 44 RGB LEDs (`[R, G, B]` order, LED 0 first) in a grid topology with per-LED positions. VCP codes, enums, ranges, and the checksum algorithm are defined in [ddc-ci.md §3](ddc-ci.md#3-parameters); LED geometry in [ambiglow.md §3](ambiglow.md#3-parameters).

---

## 4. Responses

Only DDC/CI Get requests return data: a checksum-verified reply frame carrying the current VCP value or an info string ([ddc-ci.md §4](ddc-ci.md#4-responses)). All DDC/CI Sets and every Ambiglow transfer are write-only with no acknowledgement ([ambiglow.md §4](ambiglow.md#4-responses)).

---

## 5. Polling & notifications

Neither device originates a packet. The plugin polls DDC/CI from `read_status`: once after mode-changing writes, and every 30 s for a SmartImage change made outside HaloDaemon ([ddc-ci.md §5](ddc-ci.md#5-polling--notifications)).

---

## Notes

- Keeping both protocol pages beside the plugin makes the implementation, supported-device catalog, and wire documentation one package-owned unit.
- The two USB devices are matched independently (`2109:8884` primary, `0cf2:b201` companion) and presented as a single device by the plugin.
