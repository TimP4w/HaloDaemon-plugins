# NZXT Kraken Z/Elite protocol

This document covers the LCD-capable Kraken families implemented by
[`nzxt_kraken`](../main.lua): PIDs `0x3008`, `0x300c`, `0x300e`, `0x3012`, and
`0x3014`.

The cooler is a composite USB device. HID remains the primary command and event
stream; LCD pixels use the plugin's allowlisted USB bulk OUT endpoint `0x02`.
The protocol was reconstructed from
[liquidctl](https://github.com/liquidctl/liquidctl) and the behavior encoded in
this plugin.

## HID framing and initialization

Most commands are padded to 64-byte HID reports. The ring frame is a single
124-byte report and must not be truncated or split.

Commands begin with command/subcommand bytes. Replies commonly increment the
command and retain the subcommand: `30 01` → `31 01`, `36 01` → `37 01`.
Initialization sends:

```text
70 02 01 B8 01   initialize report mode
70 01            secondary handshake
10 01            enable standard reports
10 02            firmware query
30 01            read LCD state
```

The firmware version is at offsets `0x11..0x13` of reply `11 02`.

## Pump, fan, and telemetry

Pump and fan duty are encoded as 40-byte temperature profiles:

```text
72 01 00 00 <profile[40]>   pump
72 02 01 01 <profile[40]>   fan
```

`profile[i]` is the percentage used at `(20+i) °C`, covering `20..59 °C`.
A fixed duty repeats the same value across all 40 entries. Pump duty is clamped
to at least 20 percent.

Status reports `75 01` and `75 02` contain:

```text
offset 15      liquid temperature, whole degrees Celsius
offset 16      tenths digit
offset 17..18  pump RPM, little-endian u16
offset 19      pump duty percentage
offset 23..24  fan RPM, little-endian u16
offset 25      fan duty percentage
```

`FF FF` at offsets 15..16 is the no-reading sentinel. Fractional digits above
9 are clamped while retaining the remaining telemetry.

## RGB

Colors use GRB order. The 24-LED pump ring is transmitted in a fixed 40-slot
buffer; unused slots remain zero:

```text
26 14 01 01 <120-byte ring GRB buffer>
```

An external accessory chain uses the same command with channel `02`:

```text
26 14 02 02 <accessory GRB bytes>
```

When both channels are active, the plugin preserves and re-sends the other
channel's last state so updating one does not blank the other.

Accessory request `20 03` receives `21 03`; the count is at offset 14 and each
record starts at `15 + channel*6`.

## LCD configuration

Brightness and rotation use:

```text
30 02 01 <brightness> 00 00 01 <rotation-index>
```

The index is `(degrees / 90) % 4`. Request `30 01` reads the current state;
reply `31 01` stores brightness at `0x18` and rotation at `0x1a`.
`38 01 02 00` restores the built-in display.

Panel sizes are selected by PID in `main.lua`. Image rotation and resizing are
performed by HaloDaemon before or during the Lua callback.

## USB bulk transfer

Every pixel payload is preceded by a 20-byte header on endpoint `0x02`:

```text
12 FA 01 E8 AB CD EF 98 76 54 32 10
<asset-mode> 00 00 00
<payload-length, little-endian u32>
```

Asset mode `0x08` carries Q565-compressed frames; `0x09` carries raw BGR888.
The manifest bounds each call to 4 MiB and a timeout of at most 10 seconds.
HaloDaemon loops on short bulk writes until the complete header or payload has
been transferred.

### Q565 frame sequence

```text
HID  36 01 00 01 08
HID  wait for 37 01
USB  bulk header, mode 08
USB  Q565 payload
HID  36 02
HID  wait for 37 02
```

### Raw BGR888 sequence

The plugin enters streaming mode once, clears the sixteen image buckets, sends
two color LUT reports, then uses the same sequence with asset mode `0x09`.
RGBA input is rotated and converted to BGR888 before transfer.

### Persistent images and GIFs

Persistent uploads allocate one of sixteen panel buckets. The plugin queries
bucket state, removes or reuses entries as needed, configures the bucket, sends
the bulk header and data, and waits for the matching HID acknowledgements.
GIF frames are resized and encoded according to the panel's native resolution.

## Runtime behavior

The HID stream continues to receive telemetry and acknowledgements while bulk
traffic owns the general USB endpoint collection. Transfers abort when a
required `37 xx` acknowledgement is absent, preventing the panel state machine
from becoming desynchronized. LCD uploads pause normal polling and RGB state is
reapplied afterward when required.
