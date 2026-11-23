# NZXT RGB & Fan Control Hub protocol

NZXT Control Hub (USB PID `0x2022`) HID protocol for five fan/RGB channels driving chained accessories, as implemented by [`nzxt_control_hub`](../main.lua). The same commands drive the Smart Device V2 (`0x2006`, `0x200D`, `0x200F`) and RGB & Fan Controller (`0x2009`, `0x200E`, `0x2010`, `0x2011`, `0x2019`, `0x2020`), which have three fan channels and separate RGB ports.

**Credits:** reference implementation from the Linux kernel [`nzxt-smart2`](https://github.com/torvalds/linux/blob/master/drivers/hwmon/nzxt-smart2.c) hwmon driver by Aleksandr Mezin (GPL-2.0-or-later); the firmware/accessory handshake and RGB commands were reconstructed from device behavior.

---

## Overview

The device uses proprietary USB HID reports with a two-byte command/subcommand prefix. Ordinary reports are 64 bytes; RGB data payloads may be longer and are sent as one report without truncation, they have no sequence field and must not be split.

The model is mixed: the host issues commands (fan duty, RGB, detection), while the controller pushes unsolicited periodic status reports at a host-configured interval. The hub itself has no LEDs or sensors; every zone and fan lives on a chained accessory.

---

## 1. Packet layout

All offsets are 0-based. Byte 0 is the command, byte 1 the subcommand.

### Set update interval, command `60 02`

```text
byte 0   0x60
byte 1   0x02
byte 2   0x01
byte 3   0xE8
byte 4   control byte
byte 5   0x01
byte 6   0xE8
byte 7   control byte (repeated)
```

### Detect fans, command `60 03`

```text
byte 0   0x60
byte 1   0x03
```

Two bytes only; the controller answers with a `61 03` fan-config push.

### Set fan duty, command `62 01`

```text
byte 0     0x62
byte 1     0x01
byte 2     channel bitmask, 1 << channel
byte 3+i   duty percent for channel i (8 slots)
```

Only the selected channel's slot is populated. The wire frame has eight duty slots but only the first five map to hardware.

### RGB data, command `26 04`

```text
byte 0    0x26
byte 1    0x04
byte 2    channel bitmask, 1 << channel
byte 3    0x00
byte 4…   G,R,B triples for every LED in the chain
```

Carries the complete chain in one report, which may exceed 64 bytes.

### RGB commit, command `26 06`

```text
byte 0    0x26
byte 1    0x06
byte 2    channel bitmask, 1 << channel
byte 3    0x00
byte 4…   01 00 00 18 00 00 80 00 32 00 00 01  (fixed)
```

Applies the colors previously streamed with `26 04`.

### Firmware query, command `10 02`

Two-byte request; the reply `11 02` carries the version at offsets `0x11..0x13`.

### Accessory detection, command `20 03`

Two-byte request; the reply is `21 03` (see section 4).

---

## 2. Functions

| Function | Bytes sent | Params | Required sequence / notes |
| --- | --- | --- | --- |
| `get_firmware` | `10 02` | none | Write then read reply `11 02` |
| `detect_accessories` | `20 03` | none | Write then read reply `21 03` |
| `detect_fans` | `60 03` | none | Triggers a `61 03` fan-config push |
| `set_update_interval` | `60 02 01 E8 <ctl> 01 E8 <ctl>` | interval | Control byte derived from the interval, see section 3 |
| `set_fan_duty` | `62 01 <1 << ch> <duty slots>` | channel, duty 0..100 | Single write, one channel per report |
| `write_rgb` | `26 04 <1 << ch> 00 <GRB…>` then `26 06 <1 << ch> 00 <fixed>` | channel, colors | Data report first, commit second; data report is never split |

### Init sequence

1. `60 02 01 E8 <ctl> 01 E8 <ctl>`: configure periodic status reports.
2. `60 03`: fan-type detection.
3. `20 03`: lighting info; the `21 03` channel count sizes the RGB channels.

---

## 3. Parameters

### Channels

The Control Hub exposes five physical channels, numbered `0..4`. Commands address a channel with the bitmask `1 << channel`. Each channel is one output carrying both an RGB chain and a fan header, so the plugin declares channel `N` as a chain output whose `cooling_channel` is `N`. A detected accessory becomes a child device and takes that fan over; a channel with nothing attached keeps its fan on the hub itself.

The three-fan controllers have independent RGB ports (40 LEDs each) and fan headers, so no RGB channel claims a fan. On every model the number of RGB channels is taken from the `21 03` channel count read during initialization, falling back to the model default (5 on the Control Hub, 2 otherwise).

### Fan types

| Value | Meaning |
| --- | --- |
| 0 | none |
| 1 | DC |
| 2 | PWM |

### Duty

Duty is a plain percentage, accepted range `0` through `100`.

### Color encoding

Colors use **GRB** byte order, 3 bytes per LED, one triple per LED for the whole chain in a single `26 04` report.

### Update-interval control byte

The polling control byte is derived from the requested interval in milliseconds and bounded by the values accepted by the controller (verified against the kernel driver):

- interval <= 250 ms: control byte `0`, actual interval 250 ms
- otherwise: `clamp(1 + round((interval - 488) / 256), 0, 255)`; a control byte `c >= 1` yields an actual interval of `488 + (c - 1) * 256` ms

---

## 4. Responses

### Fan status, `67 02`

```text
offset 16+i      fan type: 0 none, 1 DC, 2 PWM
offset 24+i*2    RPM, little-endian u16
offset 40+i      duty percentage
```

The kernel driver also documents a `67 04` variant carrying per-channel voltage and current instead of RPM/duty; this package ignores it.

### Fan config, `61 03`

Sent in response to `60 03`. Carries the same fan-type values at offset `16+i` as the status report; it has no RPM or duty fields.

### Accessory list, `21 03`

Sent in response to `20 03`. The channel count is at offset 14 and each channel's six accessory slots begin at `15 + channel*6`. Reported accessory IDs are resolved through the shared catalogue in [accessories.md](accessories.md) to determine names, LED counts and layouts.

### Firmware, `11 02`

Sent in response to `10 02`. Version bytes at offsets `0x11..0x13`.

---

## 5. Polling & notifications

The controller pushes `67 02` status reports unsolicited at the interval configured by `60 02`; these refresh RPM, duty, and fan type. A `61 03` push follows fan detection and refreshes fan type only. Accessory notifications cause the plugin to repeat detection and rebuild dynamic fan/RGB children.

---

## Notes

- The `26 04` RGB data report carries the complete chain, has no sequence field, and must not be split, even when it exceeds 64 bytes.
- The set-duty frame has eight duty slots but only the first five map to hardware.
- This package does not implement Kraken pump, ring, telemetry, or LCD commands.

Firmware lighting effects: see [effects.md](effects.md).
