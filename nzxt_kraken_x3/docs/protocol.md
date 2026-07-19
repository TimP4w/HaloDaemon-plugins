# NZXT Kraken X3 protocol

NZXT Kraken X53/X63/X73 USB HID protocol for ring and logo RGB, chained external accessories, and liquid-temperature telemetry.

**Credits:** reconstructed from [liquidctl](https://github.com/liquidctl/liquidctl) (GPL-3.0-or-later): the `KrakenX3` driver in `kraken3.py` and its HUE 2 accessory parsing.

---

## Overview

This document covers only the Kraken X53/X63/X73 devices implemented by [`nzxt_kraken_x3`](../main.lua), HID VID `0x1E71`, USB PIDs `0x2007` and `0x2014`. The protocol is proprietary USB HID: every report is 64 bytes on the wire, with no report-ID prefix; shorter commands are zero-padded by HaloDaemon's HID transport (`report_size: 64`, 1000 ms timeout, no feature reports).

The first two bytes of a report are the command and subcommand. Request/response pairs reply with the next command value and the same subcommand: `20 03` receives `21 03`, `10 01` receives `11 01`. After initialization the device also pushes unsolicited `75 02` status reports. This wire family has no LCD, no bulk endpoint, and no software pump or fan speed control; it is older than and distinct from the Z/Elite family.

---

## 1. Packet layout

Offsets are 0-based into the 64-byte report; unlisted bytes are zero.

### RGB data report, command `0x22 0x10` / `0x22 0x11`

```text
byte 0    0x22
byte 1    0x10 for the first data packet, 0x11 for the second
byte 2    channel id (0x01 external, 0x02 ring, 0x04 logo, 0x07 sync)
byte 3    0x00
byte 4…   up to 60 color bytes, G,R,B per LED
```

### RGB commit report, command `0x22 0xA0`

```text
byte 0    0x22
byte 1    0xA0
byte 2    channel id
byte 3    0x00
byte 4    mode value (0x01 = super-fixed, per-LED colors)
byte 5    speed low byte  (0x00 for super-fixed)
byte 6    speed high byte (0x00 for super-fixed)
byte 7…   fixed tail 08 00 00 80 00 32 00 00 01 (liquidctl; see Notes)
```

### Logo report, command `0x2A 0x04`

One report writes and applies the single logo LED (opcode, address `cid cid` with logo cid `0x04`, mode `0x00` = fixed, speed `0x32 0x00`, one GRB color, fixed footer):

```text
byte 0    0x2A
byte 1    0x04
byte 2    0x04            logo channel id
byte 3    0x04            logo channel id (repeated)
byte 4    0x00            mode: fixed
byte 5    0x32            speed low byte
byte 6    0x00            speed high byte
byte 7    G
byte 8    R
byte 9    B
byte 56   0x01
byte 57   0x00
byte 58   0x01
byte 59   0x03
```

### Requests

```text
10 01                firmware version request  (reply 11 01)
20 03                accessory / lighting info request  (reply 21 03)
70 02 01 B8 <ival>   initialization, <ival> = status update interval (0x01 here)
70 01                finalize initialization
```

---

## 2. Functions

| Function | Bytes sent | Notes |
| --- | --- | --- |
| Initialize | `70 02 01 B8 01`, then `70 01`, then `10 01` | Run once at device open, in this order |
| Detect accessories | `20 03` | Reply `21 03`; issued by the daemon's accessory-discovery path, not at init |
| Write channel colors | `22 10 …`, `22 11 …`, `22 A0 …` | Per-LED update for ring or external channel; see below |
| Write logo | `2A 04 …` | Single report, applies immediately |
| Read status | none | Unsolicited `75 02` reports; see section 5 |

### Channel color update

Every update to the ring (`0x02`) or external (`0x01`) channel sends exactly two data reports and one commit report:

1. `22 10 <channel> 00` + the first 60 GRB bytes.
2. `22 11 <channel> 00` + the remaining GRB bytes.
3. `22 A0 <channel> 00 01 00 00 …` commit (super-fixed mode).

Both data reports are always sent, even when the second carries only zeros. Colors are not visible until the commit report is written; there is no other apply mechanism.

---

## 3. Parameters

### Frame constants

| Constant | Value | Meaning |
| --- | --- | --- |
| Report size | 64 bytes | Fixed; short writes are zero-padded |
| Read timeout | 1000 ms | Per read attempt |
| Color byte order | G, R, B | All color payloads, data and logo reports |
| Color bytes per data report | 60 | 20 LEDs per report, 2 reports per update |
| Max LEDs per channel | 40 | Super-fixed limit (2 data reports) |
| Ring LED count | 8 | Pump-head ring |
| Logo LED count | 1 | Single LED |
| Status interval byte | `0x01` | Byte 4 of the `70 02` init report |

### Channel ids (byte 2 of `0x22` reports)

| Channel | Id | Notes |
| --- | --- | --- |
| External accessory chain | `0x01` | LED count comes from accessory detection |
| Ring | `0x02` | 8 LEDs on the pump head |
| Logo | `0x04` | Addressed via the `0x2A 0x04` report instead |
| Sync | `0x07` | All channels at once (liquidctl; unused here) |

### Accessory ids (byte 15 of the `21 03` reply)

| Id | Accessory | LEDs | Topology |
| --- | --- | --- | --- |
| 19 | F120 RGB | 8 | ring |
| 20 | F140 RGB | 8 | ring |
| 23, 24 | F140 RGB Core | 8 | ring |
| 27, 28 | F240 RGB Core | 16 | 2 rings |
| 29, 30 | F360 RGB Core | 24 | 3 rings |
| 31 | F420 RGB Core | 24 | 3 rings |

The plugin maps the reported id to this catalog and exposes the resulting LED chain dynamically as one division channel (max 40 LEDs).

---

## 4. Responses

### Firmware reply, `11 01`

Reply to `10 01`. Firmware version is at bytes 17, 18, 19 as major, minor, patch (liquidctl; this package does not parse it).

### Accessory reply, `21 03`

Reply to `20 03`. The accessory channel count is at offset 14; accessory id records start at offset 15, six slots per channel, so channel `c` slot `a` is at `15 + c*6 + a`. An id of `0` means no accessory on that slot.

### Status report, `75 02`

Pushed unsolicited (see section 5) rather than read on demand:

```text
offset 15   liquid temperature, whole degrees Celsius
offset 16   tenths digit (clamped to 0..9 by the plugin)
offset 17   pump speed, RPM, u16 little-endian (liquidctl; not exposed here)
offset 19   pump duty, percent (liquidctl; not exposed here)
```

`FF FF` at offsets 15..16 means no liquid-temperature reading is present; the plugin keeps the last valid value. The tenths clamp prevents malformed firmware data from producing an implausible fractional value.

---

## 5. Polling & notifications

After the init sequence the device streams unsolicited `75 02` status reports at the interval set by the `70 02` report; the host drains them non-blockingly and keeps the latest valid snapshot. Accessory-change reports trigger a fresh `20 03` detection so the external RGB child can be rebuilt. RGB and detection are host-initiated; only status is device-originated.

---

## Notes

- Cooling control is not implemented by this package: no pump or fan RPM/duty values are exposed, and the wire family offers no software speed control.
- Correction: an earlier revision of this document gave commit byte 7 as `0x28`; liquidctl's `KrakenX3` driver sends `0x08` there (`22 A0 cid 00 <mode> <speed lo> <speed hi> 08 00 00 80 00 32 00 00 01`). The implementation in this package still sends `0x28`.
- liquidctl requests `10 01` and `20 03` before the `70 02` / `70 01` pair; this package sends `70 02`, `70 01`, `10 01` and leaves `20 03` to the daemon's accessory-discovery path. Both orders work on hardware per the respective implementations.
