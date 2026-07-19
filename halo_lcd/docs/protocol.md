# Halo LCD rendering contract

Host-rendered LCD widget package: no hardware communication, only a rendering contract between the daemon's LCD engine and this package's Lua callbacks.

---

## Overview

`halo_lcd` does not talk to a device. The daemon supplies a bounded canvas and a rendering context; Lua selects and composes stock widgets using only the drawing, text, asset, clock, audio, media, and data-bus operations exposed by that context. The package returns widget and template declarations to the LCD engine. Pixel format conversion and transfer to an LCD device belong to that device's plugin, not to this package.

Images and packaged assets are decoded and bounded by the host before drawing. Preview rendering uses deterministic placeholder data and does not initiate I/O.

---

## 1. Packet layout

There are no wire packets. The natural data unit is one render invocation: the engine calls a per-widget Lua callback with a canvas handle, the widget's pixel bounds, timing, user parameters, and the rendering context.

```text
render_widget_<id>(canvas, w, h, t, dt, params, ctx)
preview_widget_<id>(canvas, w, h, params, ctx)
```

- `canvas`: opaque handle passed back into every `ctx` drawing call.
- `w`, `h`: widget bounds in pixels; all drawing is clipped to them by the host.
- `t`, `dt`: elapsed time and delta time in seconds (render path only).
- `params`: table of the widget's manifest-declared parameter values.
- `ctx`: rendering context (drawing primitives, text metrics, `data`, `audio`, `local_time`, `is_preview`).

Data-bus reads go through `ctx:data(key)`, which returns a snapshot table with `status` (`"unavailable"`, `"stale"`, or live) and `value`.

---

## 2. Functions

The entry script returns a table with one `render_widget_<id>` and one `preview_widget_<id>` callback per widget declared in `plugin.yaml`.

| Widget id | Renders | Data consumed |
| --- | --- | --- |
| `clock` | Time text, variants `24h`, `24h_seconds`, `12h` | clock (`ctx:local_time()`) |
| `date` | `DD/MM/YYYY` text | clock |
| `sensor` | Sensor value with unit plus label line | `host.sensors.catalog`, then the advertised sensor key |
| `text` | Static user text, auto-fit to width | none |
| `image` | User image with fit and shape options, placeholder graphic on failure | host-decoded image |
| `logo` | Packaged `logo.svg` asset plus brand wordmark | packaged asset |
| `debug` | Current FPS derived from `dt` | none |
| `audio_spectrum` | Bar spectrum, 8 to 64 bands, flip and mirror options | `ctx:audio()` bands |
| `gauge` | Ring, arc, or bar level display | `ctx:audio()` level or a sensor key, by `input` param |
| `now_playing` | Album art, title, artist | `host.media.playback`, media art via `ctx:draw_media_art` |
| `shape` | Circle, rectangle, triangle, or line with rotation | none |

Sensor widgets resolve `host.sensors.catalog` and then read the advertised sensor key for the chosen sensor id. Media widgets consume `host.media.playback`; weather widgets consume `weather.current`.

---

## 3. Parameters

Widget parameters are declared in `plugin.yaml` (`params` per widget) and delivered as the `params` table. Kinds used: `enum`, `text`, `boolean`, `color`, `sensor`, `image`, `number`, `range`. Colors are `{ r, g, b }` tables, 0 to 255 per channel. `param_visibility` rules in the manifest gate parameter display on other parameter values (for example gauge's `sensor`, `min`, `max` only when `input = sensor`).

The manifest also declares per-widget presentation hints consumed by the engine, not by Lua: `resize`, `default_scale`, `default_aspect`, `min_scale`, `auto_width_param`, `uses_color`, `uses_font`, `font_controls`, `default_font`, `fixed_text_weight`, and `icon` (packaged SVG). Package-level `consumes` lists the data-bus keys the package may read: `host.sensors.*` and `host.media.playback`.

Sensor units arrive as stable protocol names on the data bus (`celsius`, `fahrenheit`, `percent`, `megahertz`, `hours`, `rpm`) and are converted to compact display labels before drawing.

---

## 4. Responses

There are no device responses. The package's outputs are:

- The callback table returned by `main.lua` (widget and template declarations to the LCD engine).
- Draw calls made against the supplied canvas; callbacks return no meaningful value.
- Data-bus snapshots are read-only inputs: `ctx:data(key)` yields `{ status, value }`, and a sensor read is marked stale when its snapshot status is `"stale"`.

---

## 5. Polling & notifications

The engine schedules re-renders from each widget's manifest `updates` block; Lua never polls on its own.

- `interval_ms`: periodic redraw (for example clock 1000, debug 50, audio_spectrum 33, date and text 60000).
- `data: [key, ...]`: redraw when a listed data-bus key changes (sensor, now_playing).
- `audio: true`: redraw on new audio analysis frames (audio_spectrum).
- Conditional triggers: `data_when` and `audio_when` gate a trigger on a parameter value (gauge uses data when `input = sensor`, audio when `input = audio`).

In preview (`ctx:is_preview()`), widgets substitute deterministic placeholder data instead of live reads.

---

## Notes

- The package ships two presets (`preset-clock.json`, `preset-stats.json`) referenced from the manifest.
- Missing or unavailable data degrades gracefully: sensors show `--`, now_playing shows "Not playing", images fall back to a placeholder graphic, spectrum bars fall back to a deterministic pattern.
- Related packages: LCD device plugins own pixel format and transfer for their hardware; this package owns only widget composition.
