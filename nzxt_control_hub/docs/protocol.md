# NZXT RGB & Fan Control Hub protocol

This document covers only the controller implemented by
[`nzxt_control_hub`](../main.lua), USB PID `0x2022`.

The device uses proprietary USB HID reports. The protocol was reconstructed
from the Linux kernel
[`nzxt-smart2`](https://github.com/torvalds/linux/blob/master/drivers/hwmon/nzxt-smart2.c)
driver and the behavior encoded in this plugin. Ordinary reports are 64 bytes;
RGB payloads may be longer and are sent as one report without truncation.

## Initialization

Commands use a two-byte command/subcommand prefix. Initialization sends:

1. `10 02` - firmware query; reply `11 02` stores the version at offsets
   `0x11..0x13`.
2. `20 03` - RGB accessory detection.
3. `60 03` - fan-type detection.
4. `60 02 01 E8 <ctl> 01 E8 <ctl>` - configure periodic status reports.

The polling control byte is derived from the requested interval and bounded by
the values accepted by the controller.

## Fan channels

The hub exposes five physical channels, numbered `0..4`.

### Status report (`67 02`)

```text
offset 16+i      fan type: 0 none, 1 DC, 2 PWM
offset 24+i*2    RPM, little-endian u16
offset 40+i      duty percentage
```

Fan configuration reply `61 03` carries the same type values at `16+i`.
Channels without a fan are omitted from the dynamic child list.

### Set duty (`62 01`)

```text
62 01 <1 << channel> <duty0> <duty1> ... <duty7>
```

Only the selected channel's slot is populated. Although the wire frame has
eight duty slots, only the first five map to hardware. The plugin accepts duty
values from `0` through `100` percent.

## RGB chains

Each populated RGB channel becomes a dynamic accessory child. Colors use GRB
byte order.

```text
26 04 <1 << channel> 00 <GRB bytes for every LED>
26 06 <1 << channel> 00 01 00 00 18 00 00 80 00 32 00 00 01
```

The first report carries the complete chain and may exceed 64 bytes. It has no
sequence field and must not be split. The second report commits the colors.

Accessory request `20 03` receives `21 03`; the count is at offset 14 and each
record begins at `15 + channel*6`. Reported accessory types are resolved through
the plugin's catalog to determine names and LED counts.

## Runtime behavior

`67 02` reports refresh RPM, duty, and fan type. Accessory notifications cause
the plugin to repeat detection and rebuild dynamic fan/RGB children. This
package does not implement Kraken pump, ring, telemetry, or LCD commands.
