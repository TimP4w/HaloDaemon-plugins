# Philips Ambiglow protocol

The rear Ambiglow LEDs of the Philips Evnia 49 (49M2C8900) have two control paths:

- **Host path:** the ENE Technology RGB controller (ENE KB7730, USB `0x0CF2:0xB201`), driven by
  USB vendor control transfers. The host streams per-LED frames.
- **Controller effects:** the ENE controller animates its effect colours (static, colour shift,
  colour wave, breathing, starry night) on its own.
- **Scaler path:** the monitor scaler's own Ambiglow (off, follow video, follow audio), selected
  over DDC/CI (vendor VCP `E2 A0 19`, see [ddc-ci.md](ddc-ci.md#ambiglow-scaler-effects)). The
  scaler drives the same ENE controller internally. Its palette colour has no visible effect on
  this model.

A one-byte **host-link register** on the ENE controller decides which path owns the LEDs.

**Credits:** the **44-LED full-frame path** (capture block, `0xE100` frame buffer, baseline region)
is adapted from [`tomasf/evnia`](https://github.com/tomasf/evnia) (MIT).

---

## Overview

Every operation is a single USB vendor control-OUT with the register address in `wIndex` and the
value bytes in the data stage. There is no response and no checksum. The controller
auto-increments `wIndex` across a multi-byte write.

| Field | Value |
|-------|-------|
| `bmRequestType` | `0x40` (vendor / host-to-device / device recipient) |
| `bRequest` | `0x80` |
| `wValue` | `0` |
| `wIndex` | Register address (16-bit) |
| `data` | Register-dependent length |
| Timeout | 1000 ms |

---

## 1. Register map

| Address | Size | Meaning |
|---------|------|---------|
| `0x0023` | 1 | Host link: `0x04` = the host owns the LEDs, `0x00` = the scaler owns them |
| `0xE020` | 16 | Zone block 0 |
| `0xE030` | 16 | Zone block 1 |
| `0xE040` | 16 | Zone block 2 |
| `0xE050` | 16 | Zone block 3 |
| `0xE100` | 3 × LEDs | Frame buffer, `[R, G, B]` per LED, LED 0 first |
| `0xE980`, `0xE983`, `0xE986`, `0xE989` | 3 each | Effect colour `[R, G, B]`, one slot per zone block; the frame buffer is not used by controller effects |
| `0xE960–0xE962`, `0xE970–0xE972` | 1 each | Further parameter banks; not used by the plugin |

### Zone block layout

| Offset | Field |
|--------|-------|
| `+0x0` | Source: `0x01` = host frame buffer, `0x00` = controller effect |
| `+0x1` | Effect mode (see below) |
| `+0x2` | Speed |
| `+0x3` | Direction |
| `+0x9` | Brightness: `0x00` brightest, `0x02` brighter, `0x04` bright |
| `+0xF` | Commit: `0x01` applies the block |

Speed: `0x02` low, `0x00` normal, `0xFE` high.

The remaining bytes are fixed: `+0x5 = 0x05`, `+0xA = 0xFF`.

Controller effect modes: `0` off, `1` static, `2` static rainbow, `3` colour shift,
`4` colour shift rainbow, `5` colour wave, `6` colour wave rainbow, `7` colour breathing,
`8` colour breathing rainbow, `9` follow audio, `10` follow audio rainbow, `11` follow video,
`12` starry night, `13` starry night rainbow, `14` user defined.

### Capture block (16 bytes, written to `0xE020` and `0xE030`)

```
01 00 02 04 00 05 00 00 00 02 FF 00 00 00 00 01
```

Source = host frame buffer, speed 2, direction 4, brightness 2, commit.

### Baseline region (64 bytes, written to `0xE020`)

```
00 01 02 00 00 05 00 00 00 02 FF 00 00 00 00 00
00 00 02 00 00 05 00 00 00 02 FF 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 FF 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Spans all four zone blocks. Block 0 selects the controller's **static** effect (source `0x00`,
mode `1`) without committing. On its own this is not a hand-back: the controller keeps showing
whatever the frame buffer last held. The host link must also be switched off (§2).

---

## 2. Functions

| Function | Transfers | Notes |
|----------|-----------|-------|
| Take host link | `0x0023 ← 04` | Only when the host does not already own the LEDs |
| Take control | Take host link, then the capture block to `0xE020` and `0xE030` | Sent once, before the first frame |
| Write frame | `0xE100 ← 132 RGB bytes` | One write for all 44 LEDs |
| Controller effect | Take host link, zone block (commit `0`) to `0xE020`/`0xE030`, RGB to the four effect colour slots, then `0xE02F`/`0xE03F ← 01` | Effect and colour switch in one step |
| Release | wait 10 ms after the last frame, `0xE020 ← baseline`, `0x0023 ← 00` | Only when the host owns the LEDs; the scaler resumes its DDC-selected effect |
| Scaler effect | Release, then DDC `E2 A0 19 ← mode` | See [ddc-ci.md](ddc-ci.md#ambiglow-scaler-effects) |

Writing the baseline while a frame is still settling makes the controller mis-apply the release.
Rewriting the host link, or changing colour before the new zone block is in place, makes the
LEDs flash; effect changes therefore touch only what changes.

### HaloDaemon mapping

| Lighting state | Behaviour |
|----------------|-----------|
| `static`, `per_led`, canvas frames | Take control (once), write frame |
| Native effect `monitor` | Release, then the scaler mode read at initialize |
| Native effect `off`, `follow_video`, `follow_audio` | Scaler effect (DDC mode `0`, `1`, `2`) |
| Native effect `static`, `color_shift`, `color_wave`, `breathing`, `starry_night` | Controller effect mode `1`, `3`, `5`, `7`, `12`; the Rainbow option selects the next mode; colour, brightness and speed as above |
| `close()` while the host owns the LEDs | Release, then the scaler mode read at initialize |

The host-link state is unknown after the plugin starts; the first release is always sent.

---

## 3. Parameters

### Zone and LEDs

One zone (`ambiglow`) of **44 LEDs**, grid topology, in wire order. The per-model counts are
right 3, top-right 9, top-left 9, left 3, centre 20, bottom 0:

| LEDs | Location |
|------|----------|
| `0..2` | Right edge, bottom → top |
| `3..11` | Top row, right of the centre break (corner → centre) |
| `12..20` | Top row, left of the centre break (centre → corner) |
| `21..23` | Left edge, top → bottom |
| `24..34` | Upper centre column |
| `35..43` | Lower centre column |

The split of the 20 centre LEDs into upper/lower runs follows `tomasf/evnia`.

---

## 4. Responses

OUT-only. Success means the USB stack accepted the transfer. The current firmware effect can be
read back over DDC (`E2 A0 19..1D`), not from the ENE controller.

---

## 5. Polling & notifications

None. The controller never sends data.

---

## Notes

- Controller firmware `03 32 07 10 01` (bcdDevice `0x0101`).
- When the controller disappears from USB (for example a KVM switch to another upstream port),
  set DDC `E2 A0 19` explicitly. The scaler otherwise keeps the last state.
