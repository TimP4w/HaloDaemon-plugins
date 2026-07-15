# Logitech G560 protocol

The G560 is deliberately packaged separately from Logitech HID++ devices. It
does **not** use HID++ 2.0 feature enumeration. It uses fixed 20-byte vendor long
reports (`0x11`) addressed to device number `0xff`, sent fire-and-forget, with a
vendor sub-ID in byte 2 and function in byte 3.

**Discovery.** The plugin matches VID `0x046d`, PID `0x0a78`, HID interface 2,
usage page `0xff43`, usage `0x0202`; on platforms where the HID node reports
zero usage values, the manifest includes the equivalent fallback match.

| Function | Bytes sent | Parameters | Notes |
|----------|------------|------------|-------|
| Set zone colour (`0x04 0x3a`) | `11 ff 04 3a <zone> 01 <R> <G> <B> 02 ··` | zone and RGB | fixed-colour mode `0x01`; trailing `0x02` constant |
| Set subwoofer volume (`0x09 0x1c`) | `11 ff 09 1c <vol> ··` | `vol` 0–100 | clamped to 100 |

To paint *Left Primary* (`0x02`) magenta `(255, 0, 128)`, the plugin sends
`11 ff 04 3a 02 01 ff 00 80 02 00 …00`, padded to 20 bytes. Whole-device static
colour sends one report for each zone:

| Zone byte | Zone |
|-----------|------|
| `0x00` | Left Secondary |
| `0x01` | Right Secondary |
| `0x02` | Left Primary |
| `0x03` | Right Primary |

Only fixed colour is exposed; subwoofer volume is the device's sole range
control. The implementation is derived from the MIT-licensed `g560-led`
project; the package and its test fixture retain its attribution.
