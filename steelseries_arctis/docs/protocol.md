<!--
SPDX-License-Identifier: GPL-3.0-or-later
SPDX-FileCopyrightText: linux-arctis-manager contributors <https://github.com/elegos/Linux-Arctis-Manager>
-->

# SteelSeries Arctis protocol

SteelSeries vendor HID protocol for the Arctis Nova Pro Wireless headset family: a 64-byte report-ID-prefixed command/notification format on HID interface 4, polled at 250 ms with a persist-after-write commit. Implemented by the [`steelseries_arctis`](../../steelseries_arctis/) plugin.

**Credits:** based on the [linux-arctis-manager](https://github.com/elegos/Linux-Arctis-Manager) project (GPL-3.0), and sennheiser-gsx-control (MIT).

---

## Overview

A SteelSeries vendor HID protocol spoken on **HID interface 4** (the plugin's device spec matches `interface: 4`). Every packet is **64 bytes** and begins with a report ID and a message ID.

Supported base stations: `0x1038:0x12E0` (Nova Pro Wireless), `0x1038:0x12E5` and `0x1038:0x225D` (Nova Pro Wireless X). The two **X** PIDs additionally expose a Bluetooth status block in the status response (see §1); the plugin gates the BT booleans to them via `dev.match.pid`.

The host polls by sending command requests and reading the device's replies; the device also emits **unsolicited notifications** (ChatMix dial, mic-volume dial). On Linux, hidapi prepends a `0x00` numbered-report byte to inbound packets, which is stripped before parsing (`strip_report_id`); a real payload always starts with `0x06`/`0x07`, so dropping a leading `0x00` is a safe no-op where it isn't added. All byte-offset maps below run on the *stripped* slice.

> **ChatMix** is implemented through the daemon's `dev.audio` API: on `initialize` the plugin creates two virtual sinks (**Media** + **Chat**) looped into the headset's physical sink, and the `0x45` balance notification drives their volumes so the dial mixes game/media against chat. Sinks are host-owned (torn down on close). Station-volume (`0x25`), microphone-volume (`0x37`), and ChatMix notifications also update the typed controls exposed to the GUI.

---

## 1. Packet layout

Offsets are 0-based into the stripped slice. Unlisted bytes are zero. Bytes 0 and 1 are always a **report ID** and a **message ID**:

- Byte 0 - report ID: `0x06` (`REPORT_CMD`, host→device command *and* the device's reply to one) or `0x07` (`REPORT_NOTIFY`, unsolicited device→host notification).
- Byte 1 - message ID. A host command and its matching notification share the same message ID (e.g. `0x37` mic-volume is both set and reported).

There is no checksum and no ACK.

### Generic command packet (host→device)

```text
byte 0   0x06              report ID (REPORT_CMD)
byte 1   <cmd>             message ID
byte 2…  command-specific payload
```

### Status-poll response (`0x06 0xB0`)

Requires `len ≥ 0x10`, byte 0 = `0x06`, byte 1 = `0xB0`.

```text
byte 0x02   BT powerup state  raw (X/BT variants only)
byte 0x03   BT auto-mute      raw (X/BT variants only)
byte 0x04   BT power status   raw (X/BT variants only)
byte 0x05   BT connection     raw, non-zero = connected (X/BT variants only)
byte 0x06   headset battery   raw 0-8
byte 0x07   slot battery      raw 0-8
byte 0x08   NC level          0-10
byte 0x09   mic muted         non-zero = muted
byte 0x0A   NC mode           0=off 1=transparent 2=on
byte 0x0B   mic LED level     raw 0-10
byte 0x0C   auto-off index    0-6
byte 0x0D   wireless mode     0=speed 1=range
byte 0x0E   BT wireless pair  raw (X/BT variants only)
byte 0x0F   power status      0x01 offline / 0x02 charging / 0x08 online
```

The **Bluetooth status block** (bytes `0x02`-`0x05`, `0x0E`) is only meaningful on
the X/BT base stations (PIDs `0x12E5`, `0x225D`); on the non-X `0x12E0` these bytes
are zero.

### Settings-poll response (`0x06 0x20`)

Requires `len ≥ 0x13`, byte 0 = `0x06`, byte 1 = `0x20`. Always carries the **Custom** EQ curve regardless of the active preset.

```text
byte 0x04        microphone gain   0x02=high, else low
byte 0x06        EQ preset byte    raw (see §3 preset table)
bytes 0x07-0x10  EQ bands 0-9      one raw byte/band (raw 0x14 = 0 dB)
byte 0x12        sidetone          0-3
```

### ChatMix unsolicited packet (`0x07 0x45`)

Requires `len ≥ 4`, byte 0 = `0x07`, byte 1 = `0x45`.

```text
byte 0   0x07
byte 1   0x45
byte 2   game/media volume   0-100
byte 3   chat volume         0-100
```

### Mic-volume notification (`0x07 0x37`)

Requires `len ≥ 3`, byte 0 = `0x07`, byte 1 = `0x37`.

```text
byte 0   0x07
byte 1   0x37
byte 2   capture level   1-10
```

Emitted when the base-station capture dial is changed.

### Station-volume notification (`0x07 0x25`)

Requires `len ≥ 3`, byte 0 = `0x07`, byte 1 = `0x25`.

```text
byte 0   0x07
byte 1   0x25
byte 2   main volume   signed dB attenuation (0x00 = full, ≈ -56 floor)
```

Emitted when the base-station main volume dial is turned. Byte 2 is a **signed**
dB attenuation, not a percentage: `0x00` is full volume and the dial floor is
≈ `-56` dB (`0xC8`). The plugin drains and ignores it.

---

## 2. Functions

Every write uses report ID `0x06`.

| Function | Bytes sent (exact, `<param>`) | Params | Notes |
|----------|-------------------------------|--------|-------|
| NC mode | `06 BD <mode>` | `mode` 0-2 (`min(2)`) | shared write flow; opcode inferred. See subsection |
| NC level | `06 B9 <level>` | `level` 0-10 (`min(10)`) | shared write flow. See subsection |
| Sidetone | `06 39 <level>` | `level` 0-3 (`min(3)`) | shared write flow |
| Mic gain | `06 27 <raw>` | `0x02` high / `0x01` low | shared write flow |
| Wireless mode | `06 C3 <mode>` | `mode` 0-1 (`min(1)`) | shared write flow |
| Auto-off timeout | `06 C1 <index>` | `index` 0-6 (`min(6)`) | shared write flow |
| Sonar EQ enable | `06 8D <en>` | `en` 0/1 | shared write flow; not read back |
| Screen mode | `06 89 <simple>` | `simple` 0/1 | shared write flow; not read back |
| Mic LED brightness | `06 BF <raw>` | `raw` 0-10 = `(percent/10).min(10)` | shared write flow |
| Mic volume | `06 37 <level>` | `level` 1-10 (`clamp(1,10)`) | shared write flow; not read back |
| EQ preset select | `06 2E <preset>` | raw preset byte (not clamped) | shared write flow. See *Set custom EQ* |
| EQ band write | `06 33 <b0>…<b9>` | 10 raw band bytes | preceded by preset `0x04`; shared write flow. See *Set custom EQ* |
| ChatMix display activate | `06 49 01` | fixed `0x01` | sent once on init; no persist |
| Persist | `06 09` | - | commit prior write to NVRAM |
| Status-poll request | `06 B0` | - | reply = status response (§4) |
| Settings-poll request | `06 20` | - | reply = settings response (§4) |

### Shared write flow (write → persist)

Every user-driven setting write (`set_choice`, `set_range`, the equalizer setters) follows the same flow:

1. **Write** the command packet, e.g. `06 39 <level>` for sidetone.
2. **Persist** - send `06 09`, committing the value to NVRAM. Best-effort: a failure is swallowed because the hardware already holds the value.

The plugin does not run a read-back suppression window. Choice/range values are seeded on initialize, reflected immediately after writes, and updated from matching command replies or unsolicited hardware notifications. Battery, mic-mute, and the equalizer are also read live from the poll.

`ChatMix display activate` (`06 49 01`) and the poll requests (`06 B0`, `06 20`) are not settings writes and skip this flow.

### NC mode (`06 BD <mode>`)

`mode` 0 = off, 1 = transparent, 2 = noise cancelling; clamped with `min(2)`. The opcode `0xBD` is **inferred and unconfirmed on hardware**. NC mode is read back from the status response at byte `0x0A`.

### NC level / transparency (`06 B9 <level>`)

`level` 0-10 (clamped with `min(10)`) sets the transparency strength used when NC mode is *transparent*. Distinct from NC mode: it has its own opcode `0xB9` (not the shared-`0x33` form, see below). Read back from the status response at byte `0x08`.

### Set custom EQ

Custom band values require a three-write sequence (`set_eq_bands`):

1. **Select the Custom preset:** `06 2E 04` (`EQ_CUSTOM_BYTE`). Only this preset is editable.
2. **Write the 10 bands:** `06 33 <b0>…<b9>`, where each `b_i` is a dB value encoded to a raw byte via `raw = 20 + round(dB / 0.5)` after clamping the dB to ±10 (see §3).
3. **Persist:** `06 09`.

Selecting a non-custom preset is just step 1 with the chosen preset byte, then persist (`set_eq_preset`).

### Shared `0x33` opcode (length disambiguation)

Message ID `0x33` is disambiguated by **payload length**: a short payload is interpreted by the device as an NC-level write, a **10-byte payload** as an EQ-band write. The plugin **only ever sends the 10-byte EQ-band form**; NC level is always sent on its own opcode `0xB9`, so the short `0x33` form is never emitted.

---

## 3. Parameters

This section defines every value, range, enum, and formula used above.

### Battery level (raw 0-8 → percent)

The headset and slot battery bytes are a raw level **0-8** (clamped with `min(8)`), converted to a percentage as `percent = level × 100 / 8` (integer division):

| Raw | % | Raw | % | Raw | % |
|-----|----|-----|----|-----|----|
| 0 | 0 | 3 | 37 | 6 | 75 |
| 1 | 12 | 4 | 50 | 7 | 87 |
| 2 | 25 | 5 | 62 | 8 | 100 |

### Power status

| Byte | Meaning |
|------|---------|
| `0x01` | Offline (headset disconnected) |
| `0x02` | Charging |
| `0x08` | Online |

### NC mode

| Value | Meaning |
|-------|---------|
| 0 | Off |
| 1 | Transparent |
| 2 | Noise cancelling (on) |

### NC level (transparency)

Integer **0-10**; higher = stronger transparency passthrough. UI exposes 1-10.

### EQ dB encoding

Each EQ band is one raw byte. The conversion is:

```
dB  = (raw − 20) × 0.5
raw = 20 + round(dB / 0.5)          (clamped to 0…255)
```

- Baseline **raw `0x14` (= 20) is 0 dB**.
- One raw step = **0.5 dB**.
- Band values are clamped to **±10 dB**, i.e. raw `0x00` (−10 dB) … raw `0x28` (+10 dB).

There are **10 bands**, in this fixed frequency order:

| Index | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|-------|---|---|---|---|---|---|---|---|---|---|
| Freq | 31 Hz | 62 Hz | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | 8 kHz | 16 kHz |

On the wire the bands occupy bytes `0x07`-`0x10` of the settings response (band *i* at `0x07 + i`).

### EQ presets

The preset byte is non-contiguous; only `0x04` (Custom) is editable:

| Byte | Preset | Byte | Preset |
|------|--------|------|--------|
| `0x00` | Flat | `0x08` | Call of Duty: Warzone |
| `0x01` | Bass Boost | `0x0C` | FPS Footsteps |
| `0x02` | Focus | `0x0D` | GTA V |
| `0x03` | Smiley | `0x0F` | Overwatch 2 |
| `0x04` | **Custom (editable)** | `0x10` | PUBG |
| `0x05` | Apex Legends | | |
| `0x07` | Call of Duty: MWII | | |

Uncatalogued bytes map to the Custom slot.

### Microphone gain

| Wire byte | Meaning |
|-----------|---------|
| `0x01` | Low |
| `0x02` | High |

### Sidetone

| Value | Meaning |
|-------|---------|
| 0 | Off |
| 1 | Low |
| 2 | Medium |
| 3 | High |

### Mic volume

Capture level **1-10** (`clamp(1,10)`): **1 = muted**, 10 = 100 %.

### Mic LED brightness

On the wire a raw level **0-10**. The plugin encodes a percentage as `raw = (percent / 10).min(10)` and surfaces it as UI values 0-100 % in steps of 10.

### Auto-off timeout

The byte is an index into a fixed table:

| Index | Timeout | Index | Timeout |
|-------|---------|-------|---------|
| 0 | Off | 4 | 15 min |
| 1 | 1 min | 5 | 30 min |
| 2 | 5 min | 6 | 60 min |
| 3 | 10 min | | |

### Wireless mode

| Value | Meaning |
|-------|---------|
| 0 | Maximum Speed |
| 1 | Maximum Range |

### Screen mode

| Value | Meaning |
|-------|---------|
| 0 | Detailed |
| 1 | Simple |

### Sonar EQ

`0` = off, `1` = on.

---

## 4. Responses

### Status-poll reply (`0x06 0xB0`)

| Offset | Field | Encoding |
|--------|-------|----------|
| `0x02` | BT powerup state | raw (X/BT variants only; encoding unconfirmed) |
| `0x03` | BT auto-mute | raw, surfaced as read-only boolean `!= 0` (X/BT variants only) |
| `0x04` | BT power status | raw (X/BT variants only; encoding unconfirmed) |
| `0x05` | BT connection | raw, surfaced as read-only boolean `!= 0` (X/BT variants only) |
| `0x06` | Headset battery | raw 0-8 → `× 100 / 8` % (§3) |
| `0x07` | Slot/dock battery | raw 0-8 → `× 100 / 8` % (§3) |
| `0x08` | NC level | `min(10)` → 0-10 |
| `0x09` | Mic muted | non-zero = muted |
| `0x0A` | NC mode | `min(2)`: 0=off, 1=transparent, 2=on |
| `0x0B` | Mic LED brightness | `min(10)` → `× 10` % |
| `0x0C` | Auto-off timeout | `min(6)` → index 0-6 |
| `0x0D` | Wireless mode | `min(1)`: 0=speed, 1=range |
| `0x0E` | BT wireless pairing | raw (X/BT variants only; encoding unconfirmed) |
| `0x0F` | Power status | `0x01` offline / `0x02` charging / `0x08` online (default offline if absent) |

### Settings-poll reply (`0x06 0x20`)

| Offset | Field | Encoding |
|--------|-------|----------|
| `0x04` | Microphone gain | `0x02` → high, else low (default `0x01`) |
| `0x06` | EQ preset | raw preset byte (kept raw) |
| `0x07`-`0x10` | Custom-EQ bands 0-9 | each raw → `(raw − 20) × 0.5` dB (default `0x14` = 0 dB) |
| `0x12` | Sidetone | `min(3)`: 0-3 |

### Settings absent from aggregate poll replies

`sonar_eq` (`0x8D`), `screen_mode` (`0x89`), and `mic_volume` (`0x37`) appear in neither aggregate poll reply. The plugin retains their initial/default value, reflects host writes immediately, and decodes a matching dedicated reply or notification whenever the station emits one.

---

## 5. Polling & notifications

### Polling (250 ms)

A poll pass writes the status request `06 B0` then the settings request `06 20`, then **drains** up to 32 packets. Each packet is classified as aggregate status/settings, a dedicated control update, or a ChatMix/volume dial notification; the newest value in the stream wins. Draining (rather than request/response matching) is required because a status reply can be buried behind streamed dial notifications. The pass runs on a 250 ms interval.

### Host-cached controls (no suppress window)

The daemon caches choice/range control values host-side: seeded from the device on `initialize`, then updated on each write. There is therefore no read-back suppression window: a stale poll read cannot clobber a just-written value, because poll only refreshes the live-read state (battery, mic-mute, equalizer), not the cached controls.

### ChatMix

On `initialize` the plugin registers two virtual audio sinks, **Media** and **Chat**, via the daemon's `dev.audio` API, each looped into the headset's physical sink. On every poll pass it parses any `07 45 <game> <chat>` dial notification and sets the Media sink's volume to `game` and the Chat sink's to `chat`, so the physical dial balances game/media audio against chat audio. The notification is emitted only when the dial moves, so `set_volume` runs only on an actual change. Both sinks are required: if either fails to register (e.g. no matching physical sink, or Windows), ChatMix stays inactive. The sinks are host-owned and torn down when the device closes.

### Unsolicited notifications

- **ChatMix** - `07 45 <game> <chat>`, each 0-100. Drives the Media/Chat sink volumes (see above).
- **Mic volume** - `07 37 <level>`, level 1-10. Updates the microphone-volume control.
- **Station volume** - `07 25 <level>`, a signed dB attenuation. Updates the 0-100 volume control.

---

## Notes

- **NC mode opcode `0xBD` is inferred** and needs hardware confirmation.
- **Mic mute is read-only** - no write opcode exists for it.
- **`0x47` sets the ChatMix balance** - the host→device frame `06 47 <game> 00 <chat>` writes the game/chat split, mirroring the `07 45` notification. The plugin does not emit it: it balances ChatMix through two virtual audio sinks (see §5) rather than the device's hardware split. Documented here for reference only.
- **Shared `0x33`** - length-disambiguated; the plugin only emits the 10-byte EQ-band form, never the NC-level form (NC level uses `0xB9`).
- **No checksum / ACK** - writes are fire-and-forget; `persist` failures are not surfaced.
- **Settings frame always carries the Custom curve** - band values read back reflect the Custom preset regardless of the active preset.
