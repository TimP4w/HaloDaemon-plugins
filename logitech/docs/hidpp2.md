# HID++ 2.0 - feature protocol

The modern, **feature-enumerated** half of [HID++](protocol.md). A device exposes a table of *features* identified by 16-bit codes; each present feature is assigned a runtime *index* discovered through the ROOT feature (`0x0000`) before any call. Used by current mice, keyboards and headsets.

Code: [`main.lua`](../main.lua) contains the feature table and the battery, audio, keys, RGB, report-rate, DPI, and onboard-profile codecs. See [protocol.md](protocol.md) for the shared frame format. Historical Rust symbol names are retained below for continuity with the original notes.

**Credits:** Solaar (GPL-2.0-or-later): `hidpp20.py`, `settings_templates.py`, `settings_validator.py` by Daniel Pavel and contributors.

---

## Packet shape

A feature call is a **long (20-byte) report** (`build_packet`, see [protocol.md](protocol.md)); only a ROOT call rides a short report (§1):

```
byte 0     0x11               report ID (HIDPP_LONG; 0x10 for a short ROOT call)
byte 1     dd                 device number (1–6 wireless via receiver; 0xFF wired direct)
byte 2     fi                 feature index (resolved via ROOT; 0 = ROOT itself)
byte 3     func | swid        function high-nibble | software-id (always 1) → e.g. 0x31
byte 4…    params, zero-padded to 20 bytes
```

This is the shape behind every `11 dd fi <func> ··` template in the tables below.

---

## 1. Function + software-ID byte (byte 3)

Every 2.0 function byte is `function | software_id`, where the function occupies the **high nibble** (`0x00`, `0x10`, `0x20`, … `0xF0`) and the software ID the low nibble. HaloDaemon uses a **fixed software ID of 1**, so function `0x30` is sent as byte 3 = `0x31`, function `0x00` as `0x01`. The device echoes the same byte, letting the host correlate replies. (`feature_request` takes the high-nibble byte and stamps swid 1.)

In the tables below, outgoing byte templates are the full report as `build_packet` emits it: `dd` = device number, `fi` = feature index (resolved via ROOT), `··` = zero padding. So a function shown as `0x30` is sent with byte 3 = `0x31`.

**Short vs long selection.** A request is **short** (`0x10`, 7 bytes) only when *both* the feature index is `0` and the payload is ≤ 3 bytes; in practice only ROOT calls. Every other feature has a non-zero index and always uses **long** (`0x11`, 20 bytes). Force-long devices (LIGHTSPEED headsets) route ROOT onto long too; see [protocol.md](protocol.md).

---

## 2. Feature discovery

> **Required sequence (all 2.0 calls):** resolve the feature's index via ROOT *before* any call to it.

### ROOT (`0x0000`) - fixed index 0

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getFeature (`0x00`) | `10 dd 00 01 <code_hi> <code_lo> 00` | feature code (BE u16) | reply byte 0 = runtime index, `0` = absent. Sent short (fi=0, ≤3 params). |

Resolving ADJUSTABLE_DPI (`0x2201`) on device `0x01`: send `10 01 00 01 22 01 00`; the reply's byte 0 is the index (e.g. `04`), used as byte 2 (`fi`) in every later call to that feature.

### FEATURE_SET (`0x0001`) - full enumeration

`Hidpp20::enumerate` resolves FEATURE_SET via ROOT, reads its count, then loops `getFeatureId` for each index, building the whole `code → index` map at discovery.

A receiver answers for a sleeping slot with a zeroed record rather than an error, and it can serve the ROOT index from its pairing cache while the device itself is unreachable — so the zeros surface at the count or at the ids instead. Every device that answers ROOT reports FEATURE_SET itself in the table, so an enumeration that yields no feature means the device is asleep and the whole discovery is rejected.

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getCount (`0x00`) | `11 dd fi 01 ··` | none | reply byte 0 = feature count |
| getFeatureId (`0x10`) | `11 dd fi 11 <index> ··` | table index | reply bytes 0..2 = feature code (BE) |

### Feature codes (`v2/mod.rs`)

ROOT `0x0000`, FEATURE_SET `0x0001`, FIRMWARE_VERSION `0x0003`, DEVICE_NAME `0x0005`, DEVICE_FRIENDLY_NAME `0x0007`, BATTERY_VOLTAGE `0x1001`, UNIFIED_BATTERY `0x1004`, WIRELESS_DEVICE_STATUS `0x1D4B`, ADC_MEASUREMENT `0x1F20`, HIRES_WHEEL `0x2121`, ADJUSTABLE_DPI `0x2201`, K375S_FN_INVERSION `0x40A3`, KEYBOARD_LAYOUT_2 `0x4540`, REPROG_CONTROLS_V4 `0x1b04`, BRIGHTNESS_CONTROL `0x8040`, REPORT_RATE `0x8060`, EXT_REPORT_RATE `0x8061`, RGB_EFFECTS `0x8071`, PER_KEY_LIGHTING_V2 `0x8081`, GKEY `0x8010`, ONBOARD_PROFILES `0x8100`, MOUSE_BUTTON_SPY `0x8110`, SIDETONE `0x8300`, EQUALIZER `0x8310`. Declared but unused: `0x2202`, `0x1b10`, `0x1bc0`, `0x1b05`.

### FIRMWARE_VERSION (`0x0003`) - `v2/firmware.rs`

Informational only. func `0x00` getCount returns the firmware-entity count in `reply[0]`; func `0x10` getFwInfo(`[entity]`) returns one entity. `parse_fw_entity` decodes the getFwInfo reply (Solaar `struct.unpack('!3sBBH', fw_info[1:8])`):

| byte | field |
|------|-------|
| 0 | low nibble = fw type (`0` = main/application) |
| 1–3 | ASCII prefix (3 chars) |
| 4 | major |
| 5 | minor |
| 6–7 | build (BE u16) |

`read_firmware_version` loops entities and returns the **main** (`kind == 0`) entity's version string, formatted `"{prefix}{major:02X}.{minor:02X}.B{build:04X}"` (e.g. `MPM19.02.B0016`). Surfaced in the GUI Info tab via `debug_info_extra`.

### WIRELESS_DEVICE_STATUS (`0x1D4B`) - `v2/mod.rs`

Read-only V0 feature with **no getter**; the only payload is the device-initiated broadcast event (address `0x00`). `parse_wireless_status` decodes `data[0]` = status (`1` = reconnected), `data[1]` = request (`1` = host should reload config), `data[2]` = opaque reason. `handle_wireless_status_notif` gates on the feature index like `handle_fn_inversion_notif`; `reconcile_feature_notification` records the last event into device state (informational, surfaced in the Info tab); it does **not** trigger reinit.

### DEVICE_NAME (`0x0005`) / DEVICE_FRIENDLY_NAME (`0x0007`)

`Hidpp20::device_name` reads func `0x00` (name length) then func `0x10` + offset for up to 16 chars per chunk until the length is reached. `device_friendly_name` (`0x0007`) uses the same length-then-chunk shape for newer devices (MX Keys, Craft, …) but the chunk reply **echoes the offset in byte 0**, so it copies from `reply[1..]`. `init_name` prefers `0x0007` when present and falls back to `0x0005`.

---

## 3. Battery - `v2/battery.rs`

`Hidpp20::battery_source` resolves the source in priority order (UNIFIED preferred), then `read_battery` decodes it.

### UNIFIED_BATTERY (`0x1004`) - percentage

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getStatus (`0x10`) | `11 dd fi 11 ··` | none | reply `[level, ?, charging, …]`: byte 0 = percent (zero uses the coarse level in byte 1); byte 2 is a status enum: 1/2/4 charging, 0/3 discharging, errors unknown |

### ADC_MEASUREMENT (`0x1F20`) / BATTERY_VOLTAGE (`0x1001`) - cell voltage

LIGHTSPEED headsets report a **cell voltage**, not a percentage (the PRO X `0x0ABA` advertises only ADC_MEASUREMENT).

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getVoltage (`0x00`) | `11 dd fi 01 00 ··` | `[0x00]` | reply: BE-u16 mV in bytes 0–1; byte 2 flags: BATTERY_VOLTAGE bit 7 = charging; ADC bit 0 = valid, bit 1 = charging |

`voltage_to_percent` maps mV → 0–100% by piecewise-linear interpolation over a discharge curve. A `0` mV reading means the headset is **asleep** (dongle on, earcups off); the same condition makes SIDETONE/EQUALIZER reads return `logitech_internal` (`0x05`); all are treated as "not yet available" and the 30 s battery poll retries. The two voltage features share this exact reply layout.


**Auto power-off timer** (LIGHTSPEED headsets, ADC_MEASUREMENT): function `0x10` returns the timer in minutes in byte 0 (PRO X Wireless: 30), and `0x20 [minutes]` sets it. Exposed as the `power_off_timer` range control, 1–60 min.

---

## 4. Settings - `v2/settings/`

### REPORT_RATE (`0x8060`) - `settings/report_rate.rs`

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getReportRateList (`0x00`) | `11 dd fi 01 ··` | none | reply byte 0 = bitmask; bit *i* ⇒ rate `(i+1)` ms supported |
| getReportRate (`0x10`) | `11 dd fi 11 ··` | none | reply byte 0 = current rate (ms) |
| setReportRate (`0x20`) | `11 dd fi 21 <ms> ··` | `[ms]` | requires host mode (see ONBOARD_PROFILES setMode) |

### EXT_REPORT_RATE (`0x8061`)

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getReportRateList (`0x10`) | `11 dd fi 11 ··` | none | reply BE-u16 flags; bit *i* ⇒ rate-table index *i* supported |
| getReportRate (`0x20`) | `11 dd fi 21 ··` | none | reply byte 0 = current rate index |
| setReportRate (`0x30`) | `11 dd fi 31 <idx> ··` | `[rate_idx]` | requires host mode |

**Report-rate bitmaps.** REPORT_RATE units are **milliseconds** (bit *i* ⇒ `(i+1)` ms). EXT_REPORT_RATE units are **table indices**: the 7-entry `EXT_REPORT_RATES` table maps each index to a `(label, ms)` (8/4/2/1 ms, then 500/250/125 µs which all store ms = 0). `read_report_rates` normalises both into a `Vec<ReportRateOption { wire_index, ms, label }>` so the device matches the current selection by `wire_index`, never re-deriving sub-ms rates from ms.

**Host-mode dance.** A rate change is only honoured in host mode, so `ChoiceCapability::set_choice` brackets it: read mode → if onboard, `set_onboard_mode(host=true)` → `set_report_rate(wire_index, ext)` → `set_onboard_mode(host=false)` → re-enable SW RGB control (the firmware reclaims the LEDs on the onboard transition). Already-host devices skip the bracketing.

### ADJUSTABLE_DPI (`0x2201`) - `settings/dpi.rs`

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getSensorDpiList (`0x10`) | `11 dd fi 11 00 00 <chunk> ··` | `[sensor=0, dir=0, chunk_idx]` | reply byte 0 = sensor echo, rest = DPI-list bytes; iterate chunks (max 16) until `0x0000` |
| getSensorDpi (`0x20`) | `11 dd fi 21 ··` | none | reply carries current DPI (BE), with/without sensor echo |
| setSensorDpi (`0x30`) | `11 dd fi 31 00 <dpi_hi> <dpi_lo> ··` | `[sensor=0, dpi_hi, dpi_lo]` (`encode_set_dpi`) | 3-byte form; a 5-byte variant is rejected by G502 X Plus (`INVALID_ARGUMENT`) |

**DPI byte order** depends on where the value lives: on the wire (`encode_set_dpi`) it is **big-endian** (`1600 = 0x0640 → 06 40`); in a profile flash sector it is **little-endian** (`40 06`). A zero current DPI uses the default DPI in reply bytes 3–4 (zero-based), as in Solaar.

**DPI-list range markers** (`parse_dpi_list`). `getSensorDpiList` returns BE-u16 entries terminated by `0x0000`. A u16 whose top 3 bits are all set (`value >> 13 == 0b111`) is a **range marker**: low 13 bits = step, the *next* u16 = inclusive end; the range expands from the last explicit value adding `step` while `≤ end`. E.g. `400`, marker `0xE190` (step 400), end `0x0640` → 800, 1200, 1600.

### ONBOARD_PROFILES (`0x8100`) - `settings/onboard.rs`

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getInfo (`0x00`) | `11 dd fi 01 ··` | none | `info[4]` = ROM profile count, `info[7:9]` = sector size (BE), `parse_onboard_caps` |
| setMode (`0x10`) | `11 dd fi 11 <mode> ··` | `[0x02]`=host, `[0x01]`=onboard | |
| getMode (`0x20`) | `11 dd fi 21 ··` | none | reply byte 0: `0x02`=host, `0x01`=onboard |
| setCurrentProfile (`0x30`) | `11 dd fi 31 00 <slot> 00 ··` | `[0x00, slot, 0x00]` | |
| getCurrentProfile (`0x40`) | `11 dd fi 41 ··` | none | reply bytes 0..2 = active sector (BE); `0xFFFF`/`0x0000` = none (host) → `None` |
| memoryRead (`0x50`) | `11 dd fi 51 <sec_hi sec_lo off_hi off_lo> ··` | sector + offset (BE u16) | reply = 16-byte chunk |
| memoryAddrWrite / erase (`0x60`) | `11 dd fi 61 <sec_hi sec_lo> 00 00 <sz_hi sz_lo> ··` | `[sector, 0,0, size]` | addresses the writable RAM sector |
| memoryWrite (`0x70`) | `11 dd fi 71 <16 data bytes>` | 16-byte chunk | repeated per slice |
| memoryWriteEnd / commit (`0x80`) | `11 dd fi 81 ··` | none | commits the staged sector |

**Mode byte:** `0x01` = onboard (firmware drives DPI/LEDs/buttons), `0x02` = host (host software drives them). Host mode is required for report-rate changes and per-control divert.

**Sector read/write** (`Hidpp20::read_profile_sector` / `write_profile_sector`). A read loops memoryRead at 16-byte offsets with a final tail read clamped to the sector size. A write must target a **writable RAM sector** (`0x000N`), never a read-only `0x01xx` ROM address: erase (0x60) → write 16-byte chunks (0x70) → commit (0x80). The sector's trailing 2 bytes must be a valid CRC16 (see [protocol.md](protocol.md)) or the device silently discards the write.

**Profile-sector layout** (255 bytes on the G502 X Plus):

| Byte(s) | Field | Meaning |
|---------|-------|---------|
| 0 | report rate | ms (`01` = 1 ms) |
| 1 | resolution default index | active DPI step; clamped to `step_count − 1` on write |
| 2 | resolution shift index | DPI-shift step; reset to 0 when out of range |
| 3..13 | DPI steps | 5 × u16 **little-endian** (`0x0000`/`0xFFFF` = unused) |
| 13..28 | DPI colours | 5 × RGB |
| 28..30 / 30..32 | power-save / power-off timeout | u16 LE seconds (`60` / `300`) |
| 32..96 | button bindings | 16 × 4 bytes, physical button order (see below) |
| 96..160 | shifted bindings | same format, G-shift layer |
| 160..208 | name | UTF-16; `FF` = unnamed |
| 208..252 | LED effects | 4 × 11 bytes `[effect id, p0..p9]` (active zone 0/1, inactive zone 0/1); ids/params as RGB_EFFECTS |
| (size−2)..size | CRC16 | big-endian, over `bytes[0 .. size−2]`; matches getCRC (`0xA0`) |

Everything outside the DPI bytes is preserved verbatim on a DPI patch.

**Button binding** (4 bytes):

| Bytes | Meaning |
|-------|---------|
| `80 01 hi lo` | HID mouse button bitmask (`00 01` left … `00 10` button 5) |
| `80 02 mod key` | HID keyboard key |
| `80 03 hi lo` | HID consumer usage |
| `90 nn 00 00` | special: `01` wheel left, `02` wheel right, `03` DPI up, `04` DPI down, `07` DPI shift, `0A` profile cycle (G502 X Plus defaults) |
| `00 page 00 offset` | onboard macro at sector page / offset |
| `FF FF FF FF` | disabled / unbound |

G502 X Plus defaults in physical order: left, right, middle, back, DPI shift (thumb), forward, wheel left, wheel right, G9 profile cycle, G8 DPI up, G7 DPI down.

**Codec** (`lib/hidpp2/profile.lua`): `parse` decodes every field above into a table (keeping the source bytes, so anything unknown survives) and `serialize` writes them back with a fresh CRC. DPI edits go through it; sectors shorter than the full layout fall back to patching only the DPI header.

**Signature effect.** LED records 1–2 (active) and 3–4 (power saving) of the G502 X Plus profile hold the firmware's own signature animation, `0x0F`/`0x10` (other pairs: `0x18`/`0x19`, `0x1A`/`0x1B`). It is not in the RGB_EFFECTS table, so it is advertised from the profile as the native effect `signature` (named "Pulsar Point" on the G502 X Plus). Applying it writes all four records (active id in 1–2, inactive id in 3–4, brightness in p7) to the active writable profile when they differ, then releases LED software control (`setSWControl [01 00 00]`) so the firmware plays the profile lighting. Any later host effect reclaims control.

### HIRES_WHEEL (`0x2121`) - `v2/mod.rs`

Scroll-wheel resolution/direction/diversion + ratchet switch. `read_hires_wheel` reads three functions and decodes them via `parse_hires_wheel` into a `HiresWheel` struct; writes go through `set_hires_wheel_mode`, a read-modify-write of the mode byte.

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getCapability (`0x00`) | `11 dd fi 01 ··` | none | reply byte 0 = ratchet multiplier; byte 1 flags: `0x08` = has-invert, `0x04` = has-ratchet |
| getMode (`0x10`) | `11 dd fi 11 ··` | none | reply byte 0 mode bits: `0x04` = invert, `0x02` = hi-res, `0x01` = HID++ target (diversion) |
| setMode (`0x20`) | `11 dd fi 21 <mode> 00 ··` | `[mode, 0]` | RMW: read byte 0, clear `mask`, OR in `value & mask`, write back |
| getRatchet (`0x30`) | `11 dd fi 31 ··` | none | reply byte 0 bit `0x01` = ratchet engaged |

Feature presence over-declares: a keyboard may advertise `0x2121` with no physical wheel. `read_hires_wheel` requires all three reads to succeed with ≥2 bytes, so a device that errors on getRatchet decodes to `None` and exposes no wheel controls.

### K375S_FN_INVERSION (`0x40A3`) - `v2/mod.rs`

F-row inversion (media keys vs F1–F12). Both functions carry a host index; host `0` addresses the current host on single-host keyboards.

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getGlobalFnInversion (`0x00`) | `11 dd fi 01 <host> ··` | `[host]` | reply `[host, inverted, default, caps]`; byte 1 ≠ 0 = inverted |
| setGlobalFnInversion (`0x10`) | `11 dd fi 11 <host> <0/1> ··` | `[host, state]` | |

### BRIGHTNESS_CONTROL (`0x8040`) - `v2/mod.rs`

Keyboard backlight level + optional on/off. `parse_brightness_info` decodes getInfo into a `BrightnessInfo { min, max, has_on_off, steps }`.

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getInfo (`0x00`) | `11 dd fi 01 ··` | none | reply: `[max_be, steps_and_flags, caps, min_be]`; `steps = steps_and_flags & 0x0F`, `has_on_off = caps & 0x04` |
| getBrightness (`0x10`) | `11 dd fi 11 ··` | none | reply bytes 0–1 = level (BE u16) |
| setBrightness (`0x20`) | `11 dd fi 21 <level_be> ··` | level BE u16 | clamped to `[min, max]` before the write |
| getOnOff (`0x30`) | `11 dd fi 31 ··` | none | reply byte 0 bit `0x01` = on (only meaningful when `has_on_off`) |
| setOnOff (`0x40`) | `11 dd fi 41 <0/1> ··` | `[0/1]` | on/off toggle |

---

## 5. RGB - `v2/rgb/`

### Long-only devices

LIGHTSPEED headsets and the G560 speaker expose a vendor collection (usage page `0xFF43`) with no short report. Every request there, ROOT included, is sent as a long report. Known PIDs go long from the start. Any other device is switched to long reports the first time a short write is refused, and the request is resent.

### BASS_TONE (`0x8305`)

`0x00` getBassToneLevel returns `[level]` (0–100), and `0x10 [level]` sets it. Exposed as a range control, named per device: "Subwoofer Volume" (`subwoofer_volume`) on the G560, "Bass" (`bass_tone`) otherwise.

### G560 speaker

Feature table: `0x0003`, `0x0005`, `0x8070` (4 zones), `0x8010` (G1), `0x8310` (10 bands, −20…+6 dB), `0x8320`, `0x8040` (brightness 0–100), `0x8305`. Each zone reports `00` Off, `01` Static, `03` Color Cycle, `07` (unidentified), `0A` Breathing. Native effects use COLOR_LED_EFFECTS `setZoneEffect` (`0x30`) with the same parameter layouts as RGB_EFFECTS. Zone names (Left/Right Secondary, Left/Right Primary) and EQ presets (Flat, FPS, MOBA, Bass Boost, Cinematic, Communications) come from the device profile. The jack detection feature (`0x8320`) isn't used.

### RGB_EFFECTS (`0x8071`)

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getInfo / global (`0x00`) | `11 dd fi 01 FF FF 00 ··` | `[0xFF,0xFF,0x00]` | reply byte 2 = zone count |
| getInfo / zone (`0x00`) | `11 dd fi 01 <z> FF 00 ··` | `[zone,0xFF,0x00]` | reply byte 4 = effect count |
| getInfo / effect (`0x00`) | `11 dd fi 01 <z> <slot> 00 ··` | `[zone,slot,0x00]` | reply bytes 2..4 = firmware effect id (BE) |
| setEffect (`0x10`) | `11 dd fi 11 <zone> <slot> <p0..p9> <persist> 00 00` | 15-byte block | persist `0x01` = apply only, `0x02` = also store |
| setSWControl (`0x50`) | `11 dd fi 51 01 01 ··` | | claim host LED control |

`rgb_static_slots` scans every zone's slots and records the static slot plus a `firmware id → slot` map (`dev.lighting.effect_slots`). A slot is a position in that zone's table, so the same effect sits at different slots on different devices; effects are always addressed by firmware id, never by a fixed slot.

**Static** writes `<zone> <static slot> R G B 64 0B B8 64 00 00 00 01 00 00`.

**Native effects** are derived from the firmware table, not from a per-device list. `resolve_native_effects` picks, per zone, the first variant the zone reports, and advertises an effect when any zone has one. Applying writes every such zone with persist `0x01`.

| Effect | Firmware ids (preferred first) | p0..p9 |
|--------|-------------------------------|--------|
| Off | `0x00` | zeros |
| Breathing | `0x0A` | `R G B per_hi per_lo 00 bright 00 00 00` |
| Color Cycle | `0x15` | `00 sat 00 00 00 00 per_hi per_lo bright 00` |
| | `0x03` | `00 00 00 00 00 per_hi per_lo bright 00 00` |
| Color Wave | `0x16` | `00 sat 00 00 00 00 per_hi per_lo bright dir` |
| | `0x04` | `00 00 00 00 00 00 per_lo dir bright per_hi` |
| Ripple | `0x17` | `R G B sat 00 00 per_hi per_lo 00 00` |
| | `0x0B` | `R G B 00 per_hi per_lo 00 00 00 00` |
| Decomposition | `0x0E` | `00 00 00 00 00 00 per_lo per_hi bright 00` |

`per` is milliseconds (1000–20000; Ripple 2–200), `bright` 1–100 (never 0), `sat` is the 0–100 UI value ×2.55, and `dir` is 1–8 (horizontal, vertical, center-out, inward, outward, reverse horizontal, reverse vertical, center-in). Effect tables: G502 X Plus `00 01 0A 03`; PRO X TKL `00 01 0A 15 16 17`.

### PER_KEY_LIGHTING_V2 (`0x8081`) - `rgb/per_key.rs`

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getInfo / LED bitmap (`0x00`) | `11 dd fi 01 00 <page> 00 ··` | `[0x00,page,0x00]`, pages 0..2 | 3 pages × 14 bytes; zone ID = `page*112 + bit`, capped at the u8 wire limit (`parse_pk_led_bitmap_page`) |
| setIndividual (`0x10`) | `11 dd fi 11 <k r g b ×4>` | up to 4 × `(key,r,g,b)` | `encode_individual_pairs`; unused entries zero |
| setConsecutive (`0x20`) | `11 dd fi 21 <firstId> <r g b ×5>` | run start + ≤5 colours | streaming-frame run-length (`encode_frame`) |
| setRange (`0x50`) | `11 dd fi 51 00 FF r g b ··` | `[0x00,0xFF,r,g,b]` | paints whole key range |
| frameEnd / commit (`0x70`) | `11 dd fi 71 00 ··` | `[0x00]` | applies queued changes |

**Streaming frames** (`encode_frame`). A canvas frame is diffed against the last sent frame, then run-length-encoded: equal-colour spans → `setRange` (0x50), consecutive-id varying runs → `setConsecutive` (0x20), each frame ending in `frameEnd` (0x70). An unchanged frame emits no packets, so the bus write is skipped. Delta-compressed funcs 0x30/0x40 are not used.

The G502 mouse strip uses diffed `setIndividual` batches instead. Its eight LEDs
fit in two reports, and explicit IDs avoid a firmware quirk where optimized
pixmap frames can leave one strip LED at its previous colour.

**Explicit per-key writes** (`encode_individual_pairs`) batch up to four `(key, r, g, b)` per `setIndividual`, padding a short final batch with its last pair (so key 0 is never zero-keyed), then `commit`.

### COLOR_LED_EFFECTS (`0x8070`) - `rgb/color_led.rs`

The **older** LED effect-type system, used by devices that predate `0x8071` RGB_EFFECTS (e.g. G502 Hero). Zones are addressed by index; each zone advertises an effect table. Codecs live in `rgb/color_led.rs`; the typed ops in `rgb/mod.rs`.

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getInfo (`0x00`) | `11 dd fi 01 ··` | none | reply byte 0 = zone count (≥5-byte reply); bytes 2–3 = capabilities (`parse_color_led_zone_count`) |
| getZoneInfo (`0x10`) | `11 dd fi 11 <z> ··` | `[zone]` | reply `[index, loc_hi, loc_lo, count, caps_hi, caps_lo]` → `(zone_index, location, effect_count)` (`parse_color_led_zone_info`) |
| getZoneEffectInfo (`0x20`) | `11 dd fi 21 <z> <slot> ··` | `[zone, slot]` | reply bytes 2–3 = effect_id (BE); slot with `0x0001` = static (`parse_color_led_effect_entry`) |
| setEffect (`0x30`) | `11 dd fi 31 <zone> <slot> <10 param bytes>` | `[zone, slot, params…]` | `encode_color_led_set_effect_static`: Static (ID `0x01`) writes colour at param offset 0, ramp at 3 |
| getSwControl (`0x70`) | `11 dd fi 71 ··` | none | current SW-control state |
| setSwControl (`0x80`) | `11 dd fi 81 01 ··` | `[0x01]` | claim host LED control before writing effects |

**Zone locations** (`color_led_location_name`, per Solaar `LEDZoneLocations`): `0x0001` Primary, `0x0002` Logo, `0x0003` Left Side, `0x0004` Right Side, `0x0005` Combined, `0x0006`–`0x000B` Primary 1–6; anything else → "Unknown".

**Effect table** (`LED_EFFECTS`): Disabled `0x00`, Static `0x01`, Pulse `0x02`, Cycle `0x03`, Wave `0x04`, Boot `0x08`, Demo `0x09`, Breathe `0x0A`, Ripple `0x0B`, Decomposition `0x0E`, Signature1 `0x0F`, Signature2 `0x10`. Each carries a `LedEffectLayout` mapping param names → `(offset, size)` within the 10-byte payload (ID byte stripped). Only the static path is currently encoded; the others are decode/lookup only.

### KEYBOARD_LAYOUT_2 (`0x4540`)

`Hidpp20::read_keyboard_layout` reads func `0x00`; reply byte 0 is a country code (1 → US, 13 → CH, 14 → IT).

---

## 6. Keys / remap - `v2/keys.rs`

### REPROG_CONTROLS_V4 (`0x1b04`)

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getControlCount (`0x00`) | `11 dd fi 01 ··` | none | reply byte 0 = control count |
| getCidInfo (`0x10`) | `11 dd fi 11 <index> ··` | `[index]` | reply `[cid_hi,cid_lo,task_hi,task_lo,flags,pos,group,gmask,…]`; flags bit 5 (`0x20`) = divertable |
| setCidReporting (`0x30`) | `11 dd fi 31 <cid_hi cid_lo flags 00 …0>` | 16-byte block (`encode_set_cid_reporting`) | flags bit 0 (`0x01`) = divert, bit 1 (`0x02`) = update-valid; remap target zero (unchanged) |

**setCidReporting 16-byte block:** bytes 0–1 = CID (BE), byte 2 = flags (`0x03` enables temporary diversion, `0x02` disables it), bytes 3–15 = `0x00` (remap target zero leaves the current target unchanged). Divert only takes effect in host mode and only for controls whose getCidInfo flags have bit 5 set.

### GKEY (`0x8010`) / MOUSE_BUTTON_SPY (`0x8110`)

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| GKEY getCount (`0x00`) | `11 dd fi 01 ··` | none | reply byte 0 = G-key count (only first 16 addressable) |
| GKEY enableSoftwareControl (`0x20`) | `11 dd fi 21 <enabled> ··` | `[0/1]` | **global** toggle, enabled when any mapping exists |
| SPY getNbButtons (`0x00`) | `11 dd fi 01 ··` | none | reply byte 0 = physical button count (G502 X Plus: 11) |
| SPY startSpy (`0x10`) | `11 dd fi 11 ··` | none | sent when the first button is mapped |
| SPY stopSpy (`0x20`) | `11 dd fi 21 ··` | none | sent when the last mapping is cleared |
| SPY getRemapping (`0x30`) | `11 dd fi 31 ··` | none | 16-byte remap table, read at discovery |
| SPY setRemapping (`0x40`) | `11 dd fi 41 <16 bytes>` | remap table | |

GKEY uses a single **global** software-control toggle. MOUSE_BUTTON_SPY reports every button through the spy event once started, and its **remap table** decides what each physical button still sends natively: entry *n−1* is the HID button that physical button *n* reports, `0` reports nothing. A G502 X Plus defaults to `01 02 03 04 00 05 00 00 00 00 00` (left, right, middle, back, -, forward). A button's entry is set to `0` while its action on the current layer is non-native: base mappings always, shifted mappings only while the daemon reports the global layer shift as held (`key_remap_layer`). A button mapped only on the shift layer therefore keeps its native click on the normal layer. Clearing a mapping restores the default entry. REPROG_CONTROLS_V4 applies the same rule to its per-control divert.

Physical button *n* is bit *n−1* of the spy event's **big-endian** u16. The plugin's cids number the same bits little-endian (`cid = bit + 1`), so physical button *n* is cid `((n − 1) XOR 8) + 1`: left click = cid 9, G9 = cid 1.

### Button-event notifications

| Source | Payload | Decoder |
|--------|---------|---------|
| REPROG_CONTROLS_V4 `divertedButtonsEvent` | up to 4 × BE-u16 pressed CIDs, zero-padded | `parse_diverted_buttons_event` |
| GKEY / MOUSE_BUTTON_SPY | 16-bit LE press bitmap; bit *N* = CID `N+1` | `parse_button_bitmap_event` |

---

## 7. Audio - `v2/audio.rs`

### SIDETONE (`0x8300`) - gaming headsets

Mic feedback into the earcups: a single unsigned byte, `0–100`.

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| get (`0x00`) | `11 dd fi 01 ··` | none | reply byte 0 = current level |
| set (`0x10`) | `11 dd fi 11 <level> ··` | `[level]` | clamped 0–100 |

### EQUALIZER (`0x8310`) - gaming headsets

A graphic equalizer of **N signed-dB bands** read from the device; no named presets (one editable custom curve). `Hidpp20::read_equalizer` returns `EqReading { info, freqs, bands }`.

| Function | Bytes sent | Params | Notes |
|----------|-----------|--------|-------|
| getInfo (`0x00`) | `11 dd fi 01 ··` | none | reply `[count, dbRange, _, dbMin, dbMax]` |
| getFrequencies (`0x10`) | `11 dd fi 11 <start> ··` | start band index (`group·7`) | reply byte 0 = echo, then per-band freq BE-u16 at offset `2·b+1` |
| getBands (`0x20`) | `11 dd fi 21 00 ··` | read-prefix `0x00` | reply has **no** echoed prefix; `count` signed `i8` dB from byte 0 |
| setBands (`0x30`) | `11 dd fi 31 02 <b0> <b1> … ··` | `0x02` then `count` signed `i8` | write-prefix `0x02` selects the custom band set |

**getInfo fix-up:** `dbMin`/`dbMax` of 0 mean "use ∓`dbRange`": `[4, 12, 0, 0, 0]` → 4 bands spanning −12..+12 dB. **Band encoding:** the wire byte *is* the signed dB (`-12 → 0xF4`, `+6 → 0x06`), clamped to `[dbMin, dbMax]`; no bias or scale. A round-trip property test lives in `v2/audio.rs`.

**Headset discovery & transport.** LIGHTSPEED headsets (PRO X `0x0ABA`, PRO X 2 `0x0AF7`, G733 `0x0AB5`/`0x0AFE`, G535 `0x0AC4`, G935 `0x0A87`, G533 `0x0A66`) enumerate as a **single composite USB device**; headset and dongle share one PID, no separate receiver. HID++ rides **interface 3** (vendor usage page `0xFF43`; `0` on Linux hidraw), addressed at device index `0xFF`, and the interface declares **no short report**; `open_wired` with `DirectReport::LongOnly` forces every request long. On Linux one hidraw node carries both report IDs as a single handle.

---

## 8. Responses

- **getFeature** (ROOT `0x00`) - byte 0 = the feature's runtime index; `0` = absent.
- **Battery** (UNIFIED getStatus) - byte 0 = percent (zero uses the coarse level in byte 1); byte 2 is a status enum: 1/2/4 charging, 0/3 discharging, errors unknown; voltage features decode BE-u16 mV + status byte.
- **DPI** (`parse_current_dpi`) - DPI big-endian; longer replies echo the sensor in byte 0 (DPI in 1..3), shorter put DPI in 0..2. A decoded `0` reads as unknown (`None`).
- **Error replies** - sub-ID `0x8F`/`0xFF`; see [protocol.md](protocol.md).
- **Firmware / device name** - resolved at enumeration; firmware-string decode is not invoked.

Profile enabling changes only the directory flag and preserves customized profile data.
DPI writes reject ROM/out-of-range sectors and skip unchanged profile bodies.
