# NZXT Kraken X3 protocol

This document covers only the Kraken X53/X63/X73 devices implemented by
[`nzxt_kraken_x3`](../main.lua), USB PIDs `0x2007` and `0x2014`.

The protocol is proprietary USB HID. It was reconstructed from
[liquidctl](https://github.com/liquidctl/liquidctl) and the behavior encoded in
this plugin. All reports are 64 bytes on the wire; shorter commands are padded
by HaloDaemon's HID transport.

## Transport and initialization

The first two bytes are the command and subcommand. Replies normally use the
next command value and repeat the subcommand: `10 02` → `11 02`, `20 03` →
`21 03`.

Initialization sends, in order:

1. `10 02` - firmware query.
2. `20 03` - chained RGB accessory detection.

The firmware reply stores major, minor, and patch at offsets `0x11..0x13`.

## RGB

Colors use GRB byte order.

### Ring and accessory channel

The ring is channel `0x02`; the external accessory chain is channel `0x01`.
Each update always sends two data reports and one commit report:

```text
22 10 <channel> 00 <up to 60 GRB bytes>
22 11 <channel> 00 <remaining GRB bytes>
22 A0 <channel> 00 01 00 00 28 00 00 80 00 32 00 00 01
```

Both data reports are sent even when the second contains only zeros. The commit
is required before the new colors become visible.

The pump-head ring contains eight LEDs. The external channel length comes from
the accessory-detection reply.

### Logo LED

The single logo LED is written and applied by one report:

```text
2A 04 04 04 00 32 00 <G> <R> <B>
... zero padding ...
01 00 01 03                         at offsets 56..59
```

## Accessory detection

Request `20 03` receives `21 03`. The accessory count is at offset 14 and each
channel record begins at `15 + channel*6`. The plugin maps the reported type to
its declared accessory catalog and exposes the resulting LED chain dynamically.

## Telemetry

Kraken X3 periodically sends `75 02` reports. The plugin reads:

```text
offset 15      liquid temperature, whole degrees Celsius
offset 16      tenths digit
offset 17..18  pump RPM, little-endian u16
offset 23..24  fan RPM, little-endian u16
```

`FF FF` at offsets 15..16 means that no liquid-temperature reading is present.
The tenths digit is clamped to `0..9` so malformed firmware data cannot produce
an implausible fractional value.

Pump and fan duty are not exposed by this plugin: on X3 hardware those controls
are not driven through the protocol implemented here.

## Runtime behavior

Unsolicited `75 02` reports update the sensor snapshot. Accessory-change reports
trigger a fresh `20 03` detection so the external RGB child can be rebuilt.
There is no bulk endpoint or LCD protocol in this package.
