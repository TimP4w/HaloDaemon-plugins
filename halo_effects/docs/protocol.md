# Halo effect callback protocol

`halo_effects` is an effect package, not a device package: it has no hardware wire protocol, and its protocol is the Lua effect callback contract used by the RGB engine.

---

## Overview

An effect-only plugin (`type = "effect"`) declares no hardware match and registers straight into the RGB engine's effect catalog. Effects are pure compute: they need no permissions and never touch hardware. The full runtime contract and value limits are documented in the repository's [Lua API reference](../../docs/lua-api.md); `main.lua` is the reference implementation for both callback forms.

There are two callback forms:

- **Pixmap effects** implement `render_effect_<id>(buffer, ctx)` and write one RGB color per canvas pixel into a shared 400x300 linear-RGBA buffer once per render tick; every zone using the effect then samples the buffer at its LED positions.
- **Direct effects** implement `led_effect_<id>(leds, ctx)` and return one linear-light RGB color per LED, computed from each LED's chain position, once per zone per frame.

Direct effects convert manifest sRGB colors to linear light explicitly; the engine applies the device transfer function on output.

---

## 1. Packet layout

The natural data unit is one callback invocation. Every callback receives the same single engine-frame context snapshot of parameters, audio, sensors, timing, seed, and zone identity:

```lua
ctx = {
  time = 1.25,
  dt = 0.016,
  params = {},
  audio = { level = 0, flux = 0, beat = false, seq = 0, bands = {} },
  frame = 42,
  seed = 1234,
  zone = { id = "ring", topology = "ring", led_count = 12, device_id = "device" },
}
```

Pixmap callbacks use the synthetic `canvas` zone and mutate `buffer`: a 400x300 (`halod.canvas_w` x `halod.canvas_h`) linear-RGBA byte buffer written via `buf:set_bytes(offset, bytes)`, 4 bytes (R, G, B, A) per pixel, row stride `w * 4`.

Direct callbacks receive the actual device zone and `leds`, an array of records with stable LED and channel identity:

```lua
-- one entry per LED; id and channel_id remain stable across frames
{ id, channel_id, p, p_ring, nx, ny }
```

`p` is the LED's fractional chain position.

---

## 2. Functions

| Callback | Kind | Behavior |
| --- | --- | --- |
| `render_effect_plasma` | pixmap | Two summed sine fields (x and y) indexed into a 256-entry HSV rainbow palette built once at load time. |
| `render_effect_rainbow` | pixmap | Horizontal hue sweep; one row is built and copied to every scanline since color only varies with x. |
| `render_effect_random_flash` | pixmap | One of `cells` equal columns lights per `interval` seconds and decays exponentially; the column is picked deterministically from the seeded host RNG (`ctx:random`), never repeated back-to-back, as a pure function of `t` (no persisted state). |
| `render_effect_audio_spectrum` | pixmap | `ctx.audio.bands` (64 values, 0 to 1) drawn as a bottom-anchored bar or solid-fill chart, each band lerped between `color_low` and `color_high`; bar mode leaves a 1 px gap between bands. |
| `led_effect_comet` | direct | A comet head at `(t * speed * dir) % 1.0` sweeps the chain with a fading tail (`1.0 - d * 8.0`, wrap-around distance). |
| `led_effect_breathing` | direct | Uniform brightness pulse `sin(t * speed * pi)^2`; pure function of `t`, no persisted state. |
| `led_effect_audio_beat` | direct | Flashes to full brightness when `ctx.audio.flux` crosses the threshold `0.6 - 0.5 * sensitivity` on a new DSP frame (`audio.seq` change), otherwise decays with time constant `decay / 3`. Stateful, `ctx.frame`-guarded. |
| `led_effect_audio_level` | direct | Brightness eases toward `clamp01(audio.level * sensitivity)` with tau `clamp01(smoothing) * 0.5` s; optional `hue_shift` maps brightness to hue `0.66 - 0.66 * level` instead of the fixed color. Stateful, `ctx.frame`-guarded. |
| `led_effect_sensor_gradient` | direct | Colors the zone along a two-stop gradient (`mode = "gradient"`) or fills it up to the reading (`mode = "meter"`), with the sensor value normalized against `[min, max]`. Smoothed with tau `clamp01(smoothing) * 5.0` s; fades to black rather than snapping when the sensor disappears. |
| `led_effect_sensor_steps` | direct | Snaps to the color of the highest step whose threshold the smoothed sensor reading has reached (steps sorted by value). Same sensor lookup and fade-to-black semantics as `sensor_gradient`. |

Sensor effects resolve the selected sensor id through `ctx:data("host.sensors.catalog")`, then read the matching snapshot key; an unavailable catalog or snapshot yields nil (no reading). This requires the manifest `consumes: [host.sensors.*]` declaration.

---

## 3. Parameters

Manifest-declared editor params, delivered in `ctx.params`. Each callback falls back to a hard-coded default when a param is absent.

| Effect | Param id | Kind | Default | Range / options |
| --- | --- | --- | --- | --- |
| `plasma` | `speed` | range | 0.8 | 0.1 to 3.0, step 0.1 |
| `rainbow` | `speed` | range | 0.2 | 0.0 to 2.0, step 0.05 |
| `rainbow` | `scale` | range | 1.0 | 0.5 to 5.0, step 0.5 |
| `random_flash` | `cells` | range | 4.0 | 2 to 8, step 1 |
| `random_flash` | `interval` | range | 1.0 | 0.2 to 5.0, step 0.1 |
| `random_flash` | `decay` | range | 0.6 | 0.05 to 3.0, step 0.05 |
| `random_flash` | `random_color` | boolean | false | - |
| `random_flash` | `color` | color | r 56, g 189, b 248 | - |
| `audio_spectrum` | `color_low` | color | r 0, g 120, b 255 | - |
| `audio_spectrum` | `color_high` | color | r 255, g 0, b 120 | - |
| `audio_spectrum` | `fill` | enum | `bars` | `bars`, `solid` |
| `comet` | `color` | color | r 0, g 160, b 255 | - |
| `comet` | `speed` | range | 0.3 | 0.05 to 3.0, step 0.05 |
| `comet` | `direction` | enum | `forward` | `forward`, `backward` |
| `breathing` | `color` | color | r 0, g 128, b 255 | - |
| `breathing` | `speed` | range | 0.5 | 0.1 to 3.0, step 0.1 |
| `audio_beat` | `color` | color | r 255, g 40, b 40 | - |
| `audio_beat` | `decay` | range | 0.4 | 0.1 to 2.0, step 0.05 |
| `audio_beat` | `sensitivity` | range | 0.5 | 0.0 to 1.0, step 0.05 |
| `audio_level` | `color` | color | r 0, g 200, b 120 | - |
| `audio_level` | `hue_shift` | boolean | false | - |
| `audio_level` | `smoothing` | range | 0.3 | 0.0 to 1.0, step 0.05 |
| `audio_level` | `sensitivity` | range | 1.0 | 0.1 to 3.0, step 0.1 |
| `sensor_gradient` | `sensor` | sensor | (unset) | - |
| `sensor_gradient` | `mode` | enum | `gradient` | `gradient`, `meter` |
| `sensor_gradient` | `color_a` | color | r 0, g 128, b 255 | - |
| `sensor_gradient` | `color_b` | color | r 255, g 0, b 0 | - |
| `sensor_gradient` | `min` | number | 20.0 | -100000 to 100000 |
| `sensor_gradient` | `max` | number | 90.0 | -100000 to 100000 |
| `sensor_gradient` | `smoothing` | range | 0.3 | 0.0 to 1.0, step 0.05 |
| `sensor_steps` | `sensor` | sensor | (unset) | - |
| `sensor_steps` | `steps` | steps | 40 green, 60 orange, 80 red | - |
| `sensor_steps` | `smoothing` | range | 0.3 | 0.0 to 1.0, step 0.05 |

---

## 4. Responses

- **Pixmap callbacks** return nothing; the response is the mutated canvas buffer, fully overwritten each tick.
- **Direct callbacks** return an array with exactly one `{r, g, b}` record per input LED, each channel a linear-light value in 0 to 1.

There is no other return channel; errors abort the callback and effect calls time out after 2 seconds.

---

## 5. Polling & notifications

None in the device sense: effects never originate calls. The engine invokes the callback each render tick (pixmap: once per frame; direct: once per zone per frame) with a fresh context snapshot. Sensor and audio data arrive inside that snapshot (`ctx:data`, `ctx.audio`); `audio.seq` identifies a new DSP frame.

---

## Notes

- A stateful direct effect may run once per zone in the same engine frame. Guard time-dependent state with `ctx.frame` so smoothing and decay advance only once per frame on multi-zone devices; `audio_beat`, `audio_level`, `sensor_gradient`, and `sensor_steps` all use this guard.
- `ctx:random` and the noise helpers are seeded and deterministic: identical seeds and inputs produce bit-identical values, which is why `random_flash` can be stateless.
- Smoothing uses `ease_toward` with `alpha = 1 - exp(-dt / tau)` (tau at or below 1e-6 snaps instantly), so responsiveness is independent of tick rate.
- The plasma palette (256 entries) and the shared scratch tables are built once per worker VM to avoid per-pixel allocation; only one effect callback ever runs in a given worker VM instance.
