# Logitech G560 protocol

Vendor long-report HID protocol for the Logitech G560 gaming speaker: four RGB lighting zones plus subwoofer volume, all fire-and-forget.

**Credits:** derived from the MIT-licensed `g560-led` project by Smasty; the package and its test fixture retain its attribution.

---

## Overview

The G560 is deliberately packaged separately from Logitech HID++ devices. It does **not** use HID++ 2.0 feature enumeration. Every command is a fixed **20-byte vendor long report** (report ID `0x11`) addressed to device number `0xff`, with a vendor sub-ID in byte 2 and a function in byte 3. All writes are fire-and-forget: the device sends no replies and no acknowledgements.

**Discovery.** The plugin matches VID `0x046d`, PID `0x0a78`, HID interface 2, usage page `0xff43`, usage `0x0202`; on platforms where the HID node reports zero usage values, the manifest includes the equivalent fallback match.

---

## 1. Packet layout

Every packet is exactly 20 bytes, zero-padded after the payload.

```text
byte 0    0x11                  long report ID
byte 1    0xFF                  device number (always 0xFF)
byte 2    feature sub-ID        0x04 = lighting, 0x09 = volume
byte 3    function              0x3A = set zone color, 0x1C = set volume
byte 4…   function payload, zero-padded to 20 bytes
```

### Set zone color: `0x04` / `0x3A`

```text
byte 0    0x11
byte 1    0xFF
byte 2    0x04                  lighting feature
byte 3    0x3A                  set-color function
byte 4    zone byte             see zone table in section 3
byte 5    0x01                  fixed-color mode
byte 6    R
byte 7    G
byte 8    B
byte 9    0x02                  trailing constant
byte 10…  0x00 padding
```

### Set subwoofer volume: `0x09` / `0x1C`

```text
byte 0    0x11
byte 1    0xFF
byte 2    0x09                  volume feature
byte 3    0x1C                  set-volume function
byte 4    volume                0 to 100, clamped
byte 5…   0x00 padding
```

---

## 2. Functions

| Function | Bytes sent (20-byte report, unlisted = `0x00`) | Params | Notes |
| --- | --- | --- | --- |
| Set zone color | `11 FF 04 3A <zone> 01 <R> <G> <B> 02` | zone, RGB | Fixed-color mode `0x01`; trailing `0x02` constant |
| Set subwoofer volume | `11 FF 09 1C <vol>` | `vol` 0 to 100 | Values above 100 are clamped to 100 |

Whole-device static color sends one report per zone, all four zones in order. Example: painting *Left Primary* (`0x02`) magenta `(255, 0, 128)` sends `11 FF 04 3A 02 01 FF 00 80 02 00 … 00`, padded to 20 bytes.

---

## 3. Parameters

### Frame constants

| Constant | Value | Meaning |
| --- | --- | --- |
| Report ID (byte 0) | `0x11` | HID++-style long report framing |
| Device number (byte 1) | `0xFF` | Always `0xFF` |
| Report size | 20 bytes | Fixed; payload zero-padded |
| Color mode (byte 5) | `0x01` | Fixed color, the only mode exposed |
| Trailing constant (byte 9) | `0x02` | Follows the RGB triple |
| Volume range | 0 to 100 | Clamped |

### Zone bytes (byte 4 of the color command)

| Zone byte | Zone |
| --- | --- |
| `0x00` | Left Secondary |
| `0x01` | Right Secondary |
| `0x02` | Left Primary |
| `0x03` | Right Primary |

### Color encoding

Plain R, G, B byte order at bytes 6, 7, 8; one whole byte per channel, 0 to 255. Each zone is a single logical LED.

---

## 4. Responses

None. Every command is write-only; the device sends no acknowledgement and no reply frames.

---

## 5. Polling & notifications

None: the device never originates packets, and the host writes only on demand. There is no periodic status report.

---

## Notes

- Only fixed color is exposed; subwoofer volume is the device's sole range control.
- The `g560-led` reference sends `0x00` at byte 9 in solid mode (payload = RGB plus zero bytes) and also documents hardware cycle (`0x02`) and breathe (`0x04`) modes at byte 5; this plugin sends `0x02` at byte 9 and exposes only fixed color. The volume command (`0x09`/`0x1C`) does not appear in the reference.
