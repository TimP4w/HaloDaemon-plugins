# NZXT Kraken Z/Elite protocol

HID + USB bulk protocol for the LCD-capable NZXT Kraken families (Z53/63/73, Elite 2023, Kraken 2023, Elite V2, Plus 2024): pump/fan control, telemetry, ring and accessory RGB, and LCD image transfer.

**Credits:** reference implementation from [liquidctl](https://github.com/liquidctl/liquidctl) (GPL-3.0-or-later): `kraken3.py` (`KrakenX3` / `KrakenZ3` / `Kraken2023` drivers). Raw-streaming asset modes were reconstructed from device behavior and are not present in liquidctl.

---

## Overview

The cooler is a composite USB device (VID `0x1E71`). HID is the primary command and event stream: 64-byte output reports with no report-ID prefix and no feature reports, read with a 1000 ms timeout. LCD pixel data does not fit HID; it crosses the allowlisted USB bulk OUT endpoint `0x02` (max 4 MiB per transfer, timeout up to 10 s), while HID carries only the start/stop/config handshake around each transfer.

Commands start with a command byte and a subcommand byte. Replies increment the command byte and retain the subcommand: `30 01` is answered by `31 01`, `20 03` by `21 03`, `32 02` by `33 02`, and every LCD transfer step `36 xx` by the ACK `37 xx`. Telemetry is unsolicited: once enabled, the device pushes `0x75` status reports on its own.

---

## 1. Packet layout

All HID commands are zero-padded to 64 bytes; unlisted bytes are zero.

### Speed profile frame - `0x72`

```text
byte 0     0x72
byte 1..3  channel id: 01 00 00 = pump, 02 01 01 = fan
byte 4..43 profile[40]: duty percent at (20 + i) degrees C, covering 20..59 C
```

A fixed duty repeats the same value across all 40 entries. Pump duty is clamped to 20..100, fan duty to 0..100.

### Lighting frame - `0x26 0x14`

```text
byte 0    0x26
byte 1    0x14
byte 2    channel (0x01 = pump ring, 0x02 = accessory chain)
byte 3    channel repeated
byte 4..  G,R,B triples, 3 bytes per LED
```

The 24-LED pump ring is always sent as a fixed 40-slot buffer (120 GRB bytes); unused slots stay zero. The accessory channel carries exactly as many triples as the chain has LEDs.

### LCD config frame - `0x30 0x02`

```text
byte 0    0x30
byte 1    0x02
byte 2    0x01
byte 3    brightness percent
byte 4    0x00
byte 5    0x00
byte 6    0x01
byte 7    rotation index, (degrees / 90) % 4
```

### Bucket setup frame - `0x32 0x01`

```text
byte 0    0x32
byte 1    0x01
byte 2    bucket index (0..15)
byte 3    bucket index + 1
byte 4..5 memory start offset, little-endian u16, in 1024-byte units
byte 6..7 memory size, little-endian u16, in 1024-byte units
byte 8    0x01
```

### USB bulk header (20 bytes, endpoint `0x02`)

Every pixel payload is preceded by this header:

```text
byte 0..11   magic: 12 FA 01 E8 AB CD EF 98 76 54 32 10
byte 12      asset mode
byte 13..15  0x00
byte 16..19  payload length, little-endian u32
```

---

## 2. Functions

| Function | Bytes sent | Notes |
| --- | --- | --- |
| Initialize report mode | `70 02 01 B8 <interval>` | `01` for normal operation, `0B` when entering raw streaming |
| Secondary handshake | `70 01` | Fire-and-forget |
| Enable status reports | `10 01` | Starts unsolicited `0x75` telemetry |
| Enter raw LCD streaming | `10 02` | Only when switching to raw streaming, not part of init |
| Read LCD state | `30 01` | Reply `31 01`, see section 4 |
| Set brightness/rotation | `30 02 01 <bri> 00 00 01 <rot>` | Fire-and-forget |
| Query bucket | `30 04 <idx>` | Reply `31 04`, occupancy info from byte 15 |
| Set pump duty | `72 01 00 00 <profile[40]>` | Duty clamped to at least 20 |
| Set fan duty | `72 02 01 01 <profile[40]>` | |
| Set ring RGB | `26 14 01 01 <120 GRB bytes>` | |
| Set accessory RGB | `26 14 02 02 <GRB bytes>` | Both channels are re-sent together |
| Detect accessories | `20 03` | Reply `21 03`, see section 4 |
| Bucket setup | `32 01 <idx> <idx+1> <mem> <size> 01` | Reply `33 01`; rejected setup aborts the upload |
| Delete bucket | `32 02 <idx>` | Reply `33 02`; byte 14 = `0x01` on success |
| Begin LCD transfer | `36 01 …` | Streaming: `36 01 00 01 <mode>`; bucket: `36 01 <idx>`. Wait for `37 01` |
| End LCD transfer | `36 02` | Wait for `37 02` |
| Bucket sync | `36 03` | Sent before querying buckets |
| Switch display source | `38 01 02 00` = built-in liquid display, `38 01 04 <idx>` = show bucket | |

### Initialization sequence

```text
70 02 01 B8 01   initialize report mode
70 01            secondary handshake
10 01            enable standard reports
30 01            read LCD state
```

Stale HID reports (for example unread `37 xx` ACKs from a previous session) are drained before the handshake.

### Q565 frame sequence (asset mode `0x08`)

```text
HID  36 01 00 01 08
HID  wait for 37 01
USB  bulk header, mode 08, then Q565 payload
HID  36 02
HID  wait for 37 02
```

### Raw BGR888 sequence (asset mode `0x09`)

Streaming mode is entered once:

```text
10 02                       raw streaming mode
70 02 01 B8 0B              report mode, streaming interval
74 01                       status query
36 04
30 01
36 03
30 02 00 00 00 00 1E        screen config
38 01 02                    built-in display
32 02 <i>  for i = 0..15    delete all sixteen buckets
30 02 01 <brightness> 00 00 00 1E
```

Then each frame sends two color LUT reports, `72 01 01 00` followed by 41 bytes of `0x3F` and `72 02 01 01` followed by 41 bytes of `0x1F`, and runs the same transfer sequence as Q565 with asset mode `0x09`. RGBA input is rotated and converted to BGR888 before transfer.

### Persistent images and GIFs (bucket pipeline)

Persistent uploads use asset mode `0x01` (GIF) or `0x02` (static image) and allocate one of sixteen panel buckets backed by 24320 KiB of panel memory in 1024-byte units:

1. `36 03`, then query all buckets with `30 04 <idx>`.
2. Pick the lowest bucket whose info bytes (15 and up) are all zero; walk forward deleting occupied buckets until one deletes cleanly.
3. Compute a non-overlapping memory offset for `ceil((12 + 8 + payload) / 1024)` units; if no contiguous room exists, switch to the built-in display, delete every bucket, and restart at bucket 0 offset 0.
4. `32 01 <idx> <idx+1> <mem> <size> 01` to configure the bucket; a missing `33 01` reply aborts.
5. `36 01 <idx>`, wait for `37 01`; bulk header + data on endpoint `0x02`; `36 02`, wait for `37 02`.
6. `38 01 04 <idx>` to display the bucket.

GIF frames are resized to the panel's native resolution before upload.

---

## 3. Parameters

### Supported PIDs and panel sizes

| PID | Model | Panel |
| --- | --- | --- |
| `0x3008` | Kraken Z53/63/73 | 320 x 320 |
| `0x300C` | Kraken Elite 2023 | 640 x 640 |
| `0x300E` | Kraken 2023 | 240 x 240 |
| `0x3012` | Kraken Elite V2 | 640 x 640 |
| `0x3014` | Kraken Plus 2024 | 240 x 240 |

All panels are circular; rotations 0/90/180/270 degrees.

### Constants

| Constant | Value | Meaning |
| --- | --- | --- |
| HID report size | 64 bytes | Zero-padded commands, 1000 ms read timeout |
| Speed profile length | 40 points | One duty percent per degree, 20..59 C |
| Minimum pump duty | 20 percent | Fan minimum is 0 |
| Ring LEDs | 24 | Sent in a fixed 40-slot (120-byte) GRB buffer |
| Bulk endpoint | `0x02` OUT | Max 4 MiB per transfer, up to 10 s timeout |
| Panel memory | 24320 units | Bucket offsets and sizes in 1024-byte units |
| Rotation index | `(degrees / 90) % 4` | Byte 7 of `30 02` |

### Color encoding

Colors are **G, R, B** byte order, one byte per component. LED `i` occupies bytes `4 + i*3` (G), `4 + i*3 + 1` (R), `4 + i*3 + 2` (B) of the lighting frame.

### Asset modes (byte 12 of the bulk header)

| Mode | Payload | Path |
| --- | --- | --- |
| `0x01` | GIF | Bucket pipeline |
| `0x02` | Static image | Bucket pipeline (liquidctl; this plugin uploads stills as Q565) |
| `0x08` | Q565-compressed frame | Streaming transfer |
| `0x09` | Raw BGR888 frame | Raw streaming transfer |

---

## 4. Responses

### LCD state reply - `31 01`

Answer to `30 01`. Brightness percent at offset `0x18`, rotation index at offset `0x1A` (clamped to 0..3, times 90 gives degrees). Defaults of 80 percent and 0 degrees are assumed if no reply arrives within 8 reads.

### Transfer ACK - `37 xx`

Every `36 01` and `36 02` must be answered by `37 01` / `37 02`. Up to 8 reports are read, discarding non-matching ones; a missing ACK aborts the transfer, because proceeding desyncs the panel firmware (it can crash into the bootloader).

### Accessory reply - `21 03`

Answer to `20 03`. The channel count is at offset 14; each channel's accessory records start at `15 + channel*6`. A non-zero accessory ID byte indicates a connected accessory.

### Status report - `0x75`

Unsolicited once enabled; observed subcommands `75 01` and `75 02`:

```text
offset 15      liquid temperature, whole degrees C
offset 16      tenths digit (clamped to 9)
offset 17..18  pump RPM, little-endian u16
offset 19      pump duty percent
offset 23..24  fan RPM, little-endian u16
offset 25      fan duty percent
```

`FF FF` at offsets 15..16 is the no-reading sentinel; such reports are skipped and the last valid telemetry is retained.

### Generic command replies

Bucket commands follow the increment rule: `30 04` is answered by `31 04`, `32 01` by `33 01`, `32 02` by `33 02` (success flag at byte 14 = `0x01`). Bucket info replies carry the memory offset at bytes 17..18 and size at bytes 19..20 (little-endian u16, 1024-byte units).

---

## 5. Polling & notifications

After `10 01` the device pushes `0x75` status reports continuously; the host drains them non-blocking each poll cycle and keeps the newest valid sample. During LCD transfers the HID stream keeps carrying telemetry and ACKs while bulk traffic owns the endpoint, so ACK matching must skip interleaved status reports. Queued unread ACKs must be drained on open and close; leaving them accumulates state that desyncs the firmware on the next handshake.

---

## Notes

- liquidctl uses per-family speed channel ids (Z3 fan `72 02 00 00`, Kraken 2023 pump `72 01 01 00`); this plugin sends the Z-style pump header `72 01 00 00` and the 2023-style fan header `72 02 01 01` for all supported PIDs.
- liquidctl reads status on demand with `74 01`; the unsolicited `0x75` stream used here is not part of the liquidctl driver, nor are asset modes `0x08`/`0x09` (liquidctl only documents `0x01`, `0x02`, and an RGB16 mode `0x06`).
- Image rotation, resizing, and pixel encoding (Q565, BGR888, GIF resize) run host-side in HaloDaemon; the firmware rotates only its built-in display, so streamed frames are pre-rotated in software.
- HaloDaemon loops on short bulk writes until the complete header or payload has been transferred.
- When both lighting channels are active, the last state of the other channel is re-sent with every update so updating one does not blank the other.
- Closing the device restores the built-in liquid display (`38 01 02 00`) so the firmware is in a clean state for the next open.
