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

ROOT `0x0000`, FEATURE_SET `0x0001`, FIRMWARE_VERSION `0x0003`, DEVICE_NAME `0x0005`, DEVICE_FRIENDLY_NAME `0x0007`, BATTERY_VOLTAGE `0x1001`, UNIFIED_BATTERY `0x1004`, WIRELESS_DEVICE_STATUS `0x1D4B`, ADC_MEASUREMENT `0x1F20`, HIRES_WHEEL `0x2121`, ADJUSTABLE_DPI `0x2201`, K375S_FN_INVERSION `0x40A3`, KEYBOARD_LAYOUT_2 `0x4540`, REPROG_CONTROLS_V4 `0x1b04`, BRIGHTNESS_CONTROL `0x8040`, REPORT_RATE `0x8060`, EXT_REPORT_RATE `0x8061`, RGB_EFFECTS `0x8071`, PER_KEY_LIGHTING_V2 `0x8081`, GKEY `0x8010`, ONBOARD_PROFILES `0x8100`, MOUSE_BUTTON_SPY `0x8110`, SIDETONE `0x8300`, EQUALIZER `0x8310`. PROFILE_MANAGEMENT `0x8101`, FULL_KEY_CUSTOMIZATION `0x1b05`, CONTROL_LIST `0x1b10`. Declared but unused: `0x2202`, `0x1bc0`.

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

Any strip of eight LEDs or fewer (the G502 X) uses diffed `setIndividual` batches instead. Its LEDs
fit in two reports, and explicit IDs avoid a firmware quirk where optimized
pixmap frames can leave one strip LED at its previous colour.

**Explicit per-key writes** (`encode_individual_pairs`) batch up to four `(key, r, g, b)` per `setIndividual`, padding a short final batch with its last pair (so key 0 is never zero-keyed), then `commit`.

**Per-key takes precedence over zones.** A device that advertises per-key LEDs is exposed as one per-key channel however many `0x8071` zones it reports (a keyboard with a separate logo zone reports two); the zones remain the addressing unit for native effects only.

**Discovered keyboards.** Every per-key keyboard gets its layout from the firmware; no model has a hand-written key table. Standard keys use LED id = HID keyboard usage − 3 (`A` = 1 … `Menu` = 98, modifiers 104–111; id 47 is the ISO hash key). A per-key device whose bitmap contains the letter keys is a keyboard: the full-size template when any numpad id (80–96) is advertised, TKL otherwise. Vendor ids above 111 (media keys, G-keys, logo) are laid out in ascending order in a row above the keys; usage-range ids with no standard key stay addressable but unplaced. A model profile may only add data the firmware cannot report: the physical cell of a vendor key (`extra_key_cells`) and `gkeys_on_function_row` where G-keys share the F-row.

### PROFILE_MANAGEMENT (`0x8101`) - `lib/hidpp2/profile_mgmt.lua`

The file-based successor of ONBOARD_PROFILES on newer keyboards (G515 family, G915 X). Logitech publishes no specification; the layout below was read from a G915 X LIGHTSPEED (every byte of its flash directories and profiles) and cross-checked with [logirgb's research](https://github.com/mevdschee/logirgb/blob/main/research/8101-profile-management.md) (MIT) and Solaar's claim sequence. Nothing in it is model-specific: the plugin uses it for any device that enumerates `0x8101`.

| Function | Bytes sent | Reply | Notes |
|----------|-----------|-------|-------|
| getCapabilities (`0x00`) | none | `01 01 00 80 05 80 7f 7f 07 14 ff ff ff 20 03 07` on the G915 X | bytes 2–3 = buffer size (128), byte 14 = onboard profile count |
| getTagList (`0x10`) | `[00, offset]` | tag bytes from `offset`, `ff` ends | see **Profile tags** |
| startWrite (`0x20`) | `[len u16]` | - | opens the edit buffer |
| writeBuffer (`0x30`) | 16 data bytes | - | appends to the buffer |
| getSetMode (`0x60`) | `[flags]`: `00` read, `05` host mode, `03` onboard | `[mode, active file u16]`, mode bit 0 = onboard, bit 1 = firmware power management | every written value except `05` means onboard |
| save (`0x70`) | `[address u16, len u16, crc32 u32]` | - | commits the buffer to flash. The checksum is CRC-32 (IEEE, big-endian) of the data for a file, and the directory's own header checksum for a directory; HID++ error `0x02` otherwise |
| load (`0x80`) | `[address u16, len u16]` | - | flash to buffer; HID++ error `0x04` for a file never written |
| configure (`0x90`) | `[type u16, 01, file id u16, len u16, crc32 u32]` | - | the firmware reloads the file: `81 01 01 00 01 00 63 <crc>` activates profile 1. Length and checksum must match the directory entry (HID++ error `0x04` otherwise), so the directory is written first |
| readBuffer (`0xc0`) | `[offset u16]` | 16 buffer bytes | |

**Addresses.** The high byte is the partition (`0x00` user, `0x01` factory), the low byte a 128-byte sector. Sector 0 of each partition holds the directory; a file occupies as many consecutive sectors as its length needs. The factory partition is never written.

**Directory.** `[crc32 over the rest][count][count × entry][ff]`; entry = `[id, type u16, flags, len, crc32 of the file, sector]`. Live G915 X user directory: `b8 38 06 b2 03 | 01 8101 40 63 31dc3109 08 | 02 8101 40 63 f502350e 09 | 03 8101 40 63 006734cc 0a | ff` (three profiles in sectors 8–10; the factory copies sit in sectors 1–3 of partition `0x01`). File ids are unique across types; key presets (type `0x1b05`) get the next free id and the first free sector run.

**Profile tags.** The tag list describes the profile layout: `01 02 12 13 03 0c 0d 0e 0f 07 30 e0 1b05 e1 1b05 e2 1b05 e3 1b05 ff` on the G915 X. A tag at or above `0xe0` is a two-byte reference to another feature's file (here four FULL_KEY_CUSTOMIZATION files; `ff ff` = none). The fixed tags give the 91-byte prefix every known profile shares:

| Offset | Size | Field | Live G915 X |
|--------|------|-------|-------------|
| 0 | 1 | profile id | `01`–`03` |
| 1 | 1 | version | `01` |
| 2 | 2 | idle timeout, s, BE | 60 |
| 4 | 2 | sleep timeout, s, BE | 300 |
| 6 | 24 | name (UTF-16 BE) | `ff` |
| 30 | 44 | 4 × LED record `[effect id, p0..p9]` | records 0/2 = `18`/`19` (signature pair), 1/3 zero |
| 74 | 1 | lighting flags: `03` play records 0 and 2 (signature), `00` records 1 and 3 | `03` |
| 75 | 16 | game-mode disabled-controls bitmap over the CONTROL_LIST index | `… 44 00 18 08` |
| 91 | 2 × refs | feature file references | `ff ff` × 4 |

LED records use the RGB_EFFECTS parameter layouts; records 0/1 run while active, 2/3 after the idle timeout.

**What the plugin does with it.**

- *Onboard profiles*: each user directory profile is a slot; the slot is restorable when the factory partition holds the same id, and switching uses configure. Entries cannot be disabled, so that control is rejected.
- *Host mode*: RGB_EFFECTS `manageSwControl` (`0x50`) with flags `1` is accepted but the onboard lighting stays visible, so the claim is `0x8101 0x60 [05]`, then `0x8071 0x50 [01 03 04]` (own clusters and power modes, report the idle timeout), then `0x8071 0x80 [01 01]` because the firmware may have left the LEDs in power save (`02`). Host mode holds between applies: the mode write is only repeated after a release or after a `0x8101` event reports a mode change, and it waits out flash activity like the other profile-management requests; every apply still renews the `0x50`/`0x80` ownership. Devices without `0x8101` keep `[01 01]`. Owning power modes means the firmware no longer turns the LEDs off: the claim moves the idle timeout (`0x70`, `[getOrSet, flags u16, idle u16, sleep u16]`) to the sleep timeout; on the idle event (`0x8071` event `0x10`, byte 0 = `00`) the plugin sets power mode off (`0x80 [01 03]`) and subscribes to activity (`[01 03 02]`), and on activity it re-applies the last lighting state. The idle/active pair the firmware emits right after a claim is ignored for two seconds. The "Host mode" control releases with `0x8071 0x50 [01 00 00]` then `0x8101 0x60 [03]`; turning it back on claims first and replays the last live effect.
- *Onboard lighting*: while host mode is off, a static colour or native effect is stored in the active profile (records 1 and 3, flags `00`) and the profile is re-activated, so the keyboard keeps it without the daemon. Streaming states still claim host mode.
- *Signature*: when record 0 holds a signature pair (`18`/`19`, `1a`/`1b`, `0f`/`10`) the plugin offers it as the native effect `signature` with its two colours (`color1`, `color2`, shown side by side) and brightness read from the record. Applying it writes records 0 and 2, sets flags `03` and hands the LEDs back (the effect is not in the RGB_EFFECTS table, only the firmware plays it).
- *Restore to default*: copies the factory file of the same id over the user file, updates the directory entry's length and checksum, and re-activates the profile when it is the active one.

Every write fills the buffer, reads it back, commits, then reads the flash copy back; a mismatch aborts before the directory is touched. A save or configure keeps the keyboard silent for longer than the usual reply window, so every `0x8101` request waits up to four seconds instead of giving up after a few empty reads. Verified on a G915 X: file and directory saves, adding a `0x1b05` entry, re-configuring a changed profile, and restoring the original bytes.

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

### FULL_KEY_CUSTOMIZATION (`0x1b05`) / CONTROL_LIST (`0x1b10`) - `lib/hidpp2/fkc.lua`

Keyboards without REPROG_CONTROLS or GKEY (G915 X, G515) run their key assignments from a **preset file** in PROFILE_MANAGEMENT flash. The file layout was reconstructed from the vendor software; the G915 X accepts and registers such a file, but whether a row suppresses its key and raises a trigger event is **unverified on hardware**.

| Function | Bytes sent | Reply |
|----------|-----------|-------|
| `0x1b10` getCount (`0x00`) | none | `[count]` (G915 X: 128) |
| `0x1b10` getControlList (`0x10`) | `[index]` | 8 × BE-u16 control ids from `index`; the position is the key's `cidx` |
| `0x1b05` getCapabilities (`0x00`) | none | `[config ver, macro ver, config max u16, macro max u16, max triggers, sw caps]` (G915 X: `01 00 0580 0580 7f 01`) |
| `0x1b05` getSetPowerOnParams (`0x10`) | `[set, state]` | `[power-on state]` |
| `0x1b05` getToggleKeyList (`0x20`) | none | 8 key pairs that toggle customization |
| `0x1b05` getSetEnabled (`0x30`) | `[set flags, fkc state, toggle keys state]`; `00 00 00` reads | `[fkc state, toggle keys state]` (G915 X: `01 01`) |
| `0x1b05` getSetSWConfigCookie (`0x40`) | `[set, cookie]` | `[cookie]` |

**Preset file** (type `0x1b05`): `[00][group count]` then per key `[cidx][row count]` and 9-byte rows `[row index][flags][00][action bits u16][opcode u16][params u16]`, all big-endian. Action bits: `0x8000` disable, `0x4000` press modifiers only, low byte = modifier mask. Opcodes: `0x8000` disable, `0x8001` mouse button (params = button mask), `0x8002` keystroke (action bits = modifier mask, params = HID keycode), `0x8003` consumer usage, `0x8004` with params `0002` = G-shift. The active profile's first `0x1b05` reference names the file. After writing it the plugin configures the preset file (`0x90` with type `1b05`) and then the profile: verified on a G915 X, the firmware keeps running the old rows until the preset itself is configured.

The plugin keeps every assignment host-side like the other backends: a mapped key becomes a disabled row, the firmware swallows it and reports it through the trigger events, and the daemon runs the action. Clearing the last mapping leaves an empty preset. Keys are labelled by control id and bound to the keyboard picture through their control ids (`lib/hidpp2/control_keys.lua`): Logitech's documented standard keys `0x0122`–`0x0161`, plus the numpad (`0x016b`–`0x017b`), alt/start (`0x018b`–`0x018d`) and G-key (`0x018f`–`0x0197`) ids observed on a full-size keyboard. Ids with no known key keep a hexadecimal label.

### Button-event notifications

| Source | Payload | Decoder |
|--------|---------|---------|
| REPROG_CONTROLS_V4 `divertedButtonsEvent` | up to 4 × BE-u16 pressed CIDs, zero-padded | `parse_diverted_buttons_event` |
| GKEY / MOUSE_BUTTON_SPY | 16-bit LE press bitmap; bit *N* = CID `N+1` | `parse_button_bitmap_event` |
| FULL_KEY_CUSTOMIZATION trigger events | function nibble 0/2/4: list of pressed `cidx` (`ff` ends); 1/3/5: 128-bit bitmap over `cidx`; base, Fn and G-shift layer | `fkc.trigger_event` |

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
