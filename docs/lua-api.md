# Lua plugin API reference

HaloDaemon embeds Lua 5.4. `plugin.yaml` contains every declaration: device matching, permissions,
transports, capabilities, configuration, and effects. The entry script returns only callback
functions. Each physical root gets one Lua VM and worker. Dynamic receiver and
integration children route through that root worker using persistent child `dev`
tables, so module-level protocol state is shared while per-child fields remain isolated.
Transport calls look synchronous to Lua and are executed on that worker.

See the [manifest reference](manifest-reference.md) for `plugin.yaml`, device matching, transports,
permissions, and capability-section shapes.

## Entry script

```lua
return {
  initialize = function(dev)
    return true
  end,

  write_frame = function(dev, zone_id, colors)
    -- colors: {{ r = 0..255, g = 0..255, b = 0..255 }, ...}
  end,

  close = function(dev)
  end,
}
```

The daemon reads the entry script as inert source while loading the manifest; it does not compile or
execute Lua to obtain declarations. Normal workers evaluate the source only on activation (after
consent for a plugin that declares permissions). SMBus `pre_scan` also runs only after activation
is ready, in a throwaway VM during discovery before address probes. Keep module scope limited to
constants and helper-function definitions; perform device or service I/O only inside callbacks.

## Globals and sandbox

Available standard libraries include `string`, `table`, and `math`, plus Lua 5.4 operators and
`string.pack`/`string.unpack`. In worker VMs, HaloDaemon adds:

| Global | Meaning |
|---|---|
| `log(message)` | Write a plugin log message. Pass a string. |
| `halod.config` | This plugin's resolved config values, all represented as strings. |
| `halod.platform` | Target platform name such as `windows` or `linux`. |
| `halod.sleep_ms(ms)` | Block this device worker for a protocol delay; capped at 5000 ms. |
| `halod.monotonic_ms()` | Permission-free elapsed-milliseconds clock for rate limiting/caching. |
| `halod.buffer(value)` | Allocate a zeroed buffer by length or copy a Lua string. |

`os`, `io`, `package`, `require`, `dofile`, `loadfile`, `load`, `debug`, `collectgarbage` are removed.
With the `os` permission, a reduced `os` table exposes only `os.time()` and `os.clock()`.

Each runtime VM has a 64 MiB Lua heap limit and a 50,000,000-instruction budget reset per callback.
Device callbacks have a 30-second request deadline; effect callbacks have a 2-second deadline.
These are in-process guardrails, not process isolation. A callback must not busy-wait; use bounded
work and `halod.sleep_ms` only for hardware-mandated gaps.

## The `dev` object

Every device callback receives `dev` first.

| Member | Meaning |
|---|---|
| `dev.transport` | Transport userdata documented below. |
| `dev.match.transport` | `hid`, `smbus`, `lpcio`, `usb_control`, or `tcp`. |
| `dev.match.vid`, `.pid` | Matched USB IDs when available. |
| `dev.match.bus`, `.addr` | SMBus bus kind and matched address when available. |
| `dev.match.index` | Remote controller index for an integration child. |
| `dev.zones` | Host-provided static RGB-zone descriptors. |
| `dev.status` | Latest value returned by `read_status`; set by the polling loop. |
| `dev.audio` | Audio-routing userdata when `audio_routing` is granted. |

LPCIO packages that manage supported Nuvoton HWM chips may call
`dev.transport:lpcio_prepare_hwm(slot, unlock)` at the beginning of a poll.
It atomically selects the broker slot, registers the HWM BAR for that worker,
and (when requested) clears the chip's HWM I/O lock. Raw Super-I/O
configuration mode is deliberately not exposed to Lua.

Do not retain `dev.transport:batch`'s scoped `ops` value after its callback returns.

## Lifecycle and dynamic identity

### `pre_scan(dev)`

Runs once per matching SMBus bus before address probes when the YAML device sets `pre_scan: true`.
Only declared `addresses` and `extra_addresses` are in scope; plugin config is unavailable. The VM
has the normal 64 MiB/instruction limits plus a 5-second wall-clock timeout. The scanner contributes
the declaration only when the plugin is enabled, fully consented, and pinned to its acknowledged
content hash. Transport injection independently requires the effective `smbus` grant. PCI gates,
address scope, rate limits, VM limits, and the timeout remain additional constraints.

### `initialize(dev) -> boolean | table | nil`

Called after the transport opens. `false` or `{ ok = false }` rejects the match; `true` and `nil`
accept it. A table can report runtime information:

```lua
return {
  ok = true,
  model = "Firmware " .. version,
  -- Optional device-specific subset of plugin.yaml's advertised union.
  -- Undeclared names are ignored and reported as manifest mismatches.
  capabilities = { "rgb", "controls" },
  zones = {
    { id = "ring", name = "Ring", topology = "ring", led_count = 12 },
    -- Optional exact normalized geometry; when present it overrides the
    -- topology-derived layout and firmware `led_ids` ordering.
    { id = "panel", name = "Panel", topology = "grid", led_count = 2,
      leds = { { id = 0, x = 0.0, y = 0.0 }, { id = 1, x = 1.0, y = 1.0 } } },
  },
  -- Optional runtime keyboard geometry. Standard keys inherit their cells
  -- from the named base; device-specific keys provide an explicit cell.
  keyboard = {
    ansi = { base = "tkl", keys = {
      { led_id = 1, key = "a" },
      { led_id = 150, cell = { col = 5, row = -1.5 } },
    } },
    iso = { base = "tkl_iso", keys = {} },
    detected_language = "u_s",
    languages = { "u_s", "c_h", "d_e", "f_r", "i_t", "u_k" },
  },
  lcd = {
    shape = "circle", width = 320, height = 320,
    rotations = { 0, 90, 180, 270 },
    image_types = { "image/png", "image/gif" },
    latches = true, raw_streaming = false,
    brightness = 80, rotation = 0,
  },
  chain = { { id = "out1", name = "Output 1", max_leds = 40 } },
  ranges = { brightness = 70 },
  choices = { mode = 1 }, -- option indexes are zero-based
}
```

When `capabilities` is omitted, the host keeps the manifest's advertised set for
compatibility. Product-family and dynamic-child plugins should return it so one
device does not inherit capabilities that only another model supports.

### `close(dev)`

Optional best-effort cleanup called before the worker exits. Host-managed audio sinks are also
removed independently, including abnormal worker exits.

### `event(dev, event)`

Optional callback for event-driven host transports. HID events contain
`event.transport == "hid"`, `event.endpoint` (`primary` or `companion`), and the
raw `event.report` string. Return `{ button_events = { pressed = {...}, released = {...} } }`
to forward transitions to the host input engine. A dynamic controller may define
`event_source(event) -> index | 0 | false`: a positive index dispatches to that
child, `0` or `nil` dispatches to the root, and `false` discards the report.

## Capability callbacks

All signatures below omit return values when the callback returns nothing. Arrays are ordinary
1-based Lua arrays; protocol/control indexes documented as indexes or slots retain their stated
host values and are commonly zero-based.

| Capability | Callback signature |
|---|---|
| RGB | `apply(dev, state)`; `write_frame(dev, zone_id, colors)` |
| Fan | `get_duty(dev) -> u8`; `set_duty(dev, duty)`; optional `get_rpm(dev) -> u32 | nil` |
| Sensor | `get_sensors(dev) -> sensors` |
| Poll | `read_status(dev) -> any` for slowly refreshed state without notifications. HID/button notifications use `event()`. |
| Chain | `detect_accessories(dev) -> {{channel, accessory}, ...}`; `write_ext_frame(dev, channel_id, colors)` |
| Chain fan | `fan_rpm(dev, channel)`, `fan_duty(dev, channel)`, `fan_controllable(dev, channel)`, `set_fan_duty(dev, channel, duty)` |
| LCD | `lcd_stream_frame(dev, rgba, width, height, rotation, raw, brightness)`; `set_image(dev, bytes, rotation)`; `lcd_set_brightness(dev, brightness, rotation)`; `lcd_set_rotation(dev, brightness, degrees)`; `lcd_reset(dev)` |
| DPI | `set_dpi(dev, dpi)` |
| Choice | `set_choice(dev, key, selected)` |
| Range | `set_range(dev, key, value)` |
| Boolean | `get_booleans(dev) -> {{key, value}, ...}`; `set_boolean(dev, key, value)` |
| Action | `trigger_action(dev, key)` |
| Battery | `get_batteries(dev) -> batteries` |
| Connection | `connection_status(dev) -> status | nil` |
| Equalizer | `get_equalizer(dev) -> equalizer`; `set_eq_preset(dev, preset)`; `set_eq_bands(dev, values)` |
| Pairing | `start_pairing(dev, timeout_secs)`; `stop_pairing(dev)`; `unpair(dev, slot)`; `pairing_status(dev) -> status` |
| Onboard profiles | `switch_profile(dev, slot)`; `restore_profile(dev, slot)`; `set_profile_enabled(dev, slot, enabled)`; `onboard_profiles_status(dev) -> status` |
| Key remap | `set_button_mapping(dev, mapping)`; `reset_button_mapping(dev, cid)`; `reset_all_button_mappings(dev)`; optional `key_remap_host_mode(dev) -> bool` |

`state` passed to `apply` is tagged by `state.mode` (`static`, `per_led`, or `native_effect`). For
software frames, `colors` is an array of `{r, g, b}` byte tables in the declared LED order.

Common returned record shapes:

```lua
-- Sensor
{ id = "liquid", name = "Liquid", value = 31.5,
  unit = "celsius", sensor_type = "temperature" }

-- Boolean (label/category/read_only come from the manifest)
{ key = "anc", value = true }

-- Battery
{ key = "headset", label = "Headset", level = 87, status = "discharging" }

-- Connection
{ connection_type = "wireless" } -- or "wired"
```

Sensor units are `celsius`, `fahrenheit`, `percent`, `megahertz`, `hours`, or `rpm`; sensor types are
`temperature`, `load`, `memory`, `frequency`, `uptime`, `fan_speed`, or `fan_duty`.

The richer status return values have these shapes:

```lua
-- Equalizer. Preset and band indexes are host indexes.
{
  presets = {
    { id = "custom", label = "Custom", is_custom = true,
      is_firmware = false, bands = { 0.0, 1.0 } },
  },
  selected_preset = 0,
  bands = {
    { index = 0, label = "32 Hz", min = -10.0, max = 10.0,
      step = 0.5, value = 0.0 },
  },
  editable = true,
}

-- Pairing
{
  state = "idle", -- idle, listening, paired, error
  error = nil,
  max_slots = 2,
  slots = {
    { slot = 1, device_id = "receiver-slot-1", name = "Mouse", connected = true },
  },
}

-- Onboard profiles (slot indexes are 1-based; active_slot 0 means host mode)
{
  active_slot = 1,
  slots = {
    { index = 1, enabled = true, active = true, has_rom_default = true },
  },
}

-- A key-remap write; `base` and `shifted` are tagged ButtonAction tables.
{
  cid = 0x50,
  base = { type = "native" },
  shifted = { type = "media_key", key = "play" },
}
```

Button-action `type` values are `native`, `disable`, `mouse_button`, `scroll`, `key_chord`,
`media_key`, `dpi_cycle`, `profile_cycle`, `momentary_dpi`, `layer_shift`, `macro`, `open_app`, and
`command`. Their payload keys follow the action (`btn`; `axis`/`clicks`; `key`/`modifiers`;
`direction`; `dpi`; `steps`; `path`; or `cmd`/`args`). Use the daemon UI to generate complex macro
and key-action values and the official plugins as executable examples.

## Integration callbacks

An integration root implements:

```lua
enumerate_controllers = function(dev)
  return {
    {
      index = 0,
      name = "Keyboard",
      device_type = "keyboard", -- optional; defaults to "other"
      serial = "ABC123",       -- optional; used for conflict detection
      location = "HID: ...",   -- optional; used for conflict detection
      zones = {
        { id = "main", name = "Main", topology = "linear", led_count = 20 },
      },
    },
  }
end
```

Each record may use `zones` as RGB shorthand or declare any normal capability section (`rgb`,
`fan`, `sensor`, `lcd`, `dpi`, `choice`, `range`, `boolean`, `action`, `battery`, `connection`,
`equalizer`, `pairing`, `onboard_profiles`, `key_remap`, or `chain`). Each becomes an independent
top-level device routed through the physical root's worker. Its persistent child
table receives the controller index in `dev.match.index` and its opaque key in
`dev.match.key`.

Routed children use the same capability callbacks as directly matched devices:
`apply(dev, state)`, `write_frame(dev, zone_id, colors)`, and optional
`write_frame_batch(dev, frames)`. Plugins route through `dev.match.index` or
`dev.match.key`; no controller-specific callback family exists.

## Stream transport: HID and TCP

All byte inputs accept a Lua string or `halod.buffer`; reads return Lua strings.
For HID devices whose manifest declares a companion collection,
`has_companion()` reports whether it was opened. `write_companion(bytes)`,
`read_companion(size)`, and `write_then_read_companion(bytes, size)` access it
explicitly; protocol code decides which collection to use.

| Method | Result |
|---|---|
| `dev.transport:write(data)` | Write one packet/payload. |
| `:read(size)` | Blocking read of up to/requested `size` bytes. |
| `:read_nonblocking(size)` | Non-blocking read. |
| `:write_then_read(data, size)` | Write, then read a reply. |
| `:feature_exchange(data, size)` | HID feature-report exchange. |
| `:write_many({data, ...})` | Write several packets under one backend operation. |
| `:write_bulk(data)` | USB bulk-OUT payload used by LCD-capable devices. |

TCP has no message framing, but HaloDaemon deliberately implements `read(size)` as read-exact: it
returns exactly `size` bytes or errors on timeout/EOF. Read a fixed header first, decode its payload
length, then request exactly that many bytes. HID report sizing/padding is handled by the HID
backend.

## USB vendor-control transport

```lua
dev.transport:control_write(
  endpoint, bm_request_type, b_request, w_value, w_index, data)

local reply = dev.transport:control_read(
  endpoint, bm_request_type, b_request, w_value, w_index, length)
```

Use endpoint `""` for the matched primary device or a named endpoint from YAML. Reads return a Lua
string and may be shorter than the requested length.

## SMBus transport

All register I/O occurs in one scoped bus-lock batch:

```lua
local value = dev.transport:batch(function(ops)
  local id = ops:read_byte_data(dev.match.addr, 0x00)
  if id == nil then return nil end
  if not ops:write_byte_data(dev.match.addr, 0x10, 0xff) then return nil end
  return id
end)
```

| Scoped method | Result |
|---|---|
| `ops:read_byte(addr)` | Byte or `nil` on NAK/error. |
| `ops:read_byte_data(addr, command)` | Byte or `nil`. |
| `ops:write_quick(addr)` | Success boolean. |
| `ops:write_byte_data(addr, command, value)` | Success boolean. |
| `ops:write_word_data(addr, command, value)` | Success boolean. |
| `ops:write_block_data(addr, command, data)` | Success boolean. |
| `ops:supports_block_write()` | Whether native block writes are supported. |

An operation outside the manifest-declared address scope raises an error.

## Byte buffers

`halod.buffer(n)` creates `n` zero bytes; `halod.buffer(str)` copies a string. All offsets are
zero-based and bounds-checked.

| Method | Meaning |
|---|---|
| `#buf`, `buf:len()` | Length. |
| `tostring(buf)`, `buf:tostring()` | Copy to a Lua byte string. |
| `get_u8(i)`, `set_u8(i, v)` | One byte. |
| `get_u16_le/be(i)`, `set_u16_le/be(i, v)` | 16-bit integer. |
| `get_u32_le/be(i)`, `set_u32_le/be(i, v)` | 32-bit integer. |
| `slice(start, len)` | New copied buffer. |
| `set_bytes(start, string_or_buffer)` | Copy a run in one host call. |

Build large chunks with `string.char`/`table.concat` and copy them with `set_bytes`; one host call
per pixel is unnecessarily expensive.

## Image helpers

Inputs accept a string or buffer and results are buffers.

| Function | Meaning |
|---|---|
| `halod.rgba_to_q565(rgba, width, height)` | Encode RGBA as the daemon's Q565 file format. |
| `halod.rgba_to_bgr888(rgba)` | Drop alpha and reorder RGB to BGR. |
| `halod.rgba_rotate_square(rgba, size, degrees)` | Rotate square RGBA data. |
| `halod.image_decode(bytes, width, height)` | Decode and resize a static image to RGBA. |
| `halod.gif_resize(bytes, width, height)` | Resize an animated GIF. |

Dimensions and output allocations are checked against VM/native allocation limits.

## Virtual audio sinks

Requires `audio_routing` and a USB VID/PID match:

```lua
local sink = dev.audio:register("Chat") -- handle or nil
if sink then
  sink:set_volume(75)
  sink:remove() -- idempotent host cleanup also runs on device teardown
end
```

## Effect API

Pixmap callbacks mutate a 400×300 linear-RGBA buffer:

```lua
render_plasma = function(buf, t, dt, params)
end
```

Direct effects return one linear-light `{r, g, b}` value (0..1) per input LED:

```lua
led_colors_comet = function(leds, t, dt, params, sensor)
  -- leds entries: { p, p_ring, nx, ny }
  return colors
end
```

When exactly one effect is declared, bare `render` or `led_colors` is also accepted. Helpers:

| API | Meaning |
|---|---|
| `halod.canvas_w`, `halod.canvas_h` | Pixmap dimensions. |
| `halod.hsv(h, s, v)` | HSV to sRGB byte triplet. |
| `halod.audio()` | Latest `{level, flux, beat, seq, bands}` frame; `bands` has 64 values. |

A stateful direct effect may run once per zone at the same engine time. Update time-dependent state
only when `t` advances to avoid multiplying smoothing/decay on multi-zone devices.

## `test.lua` harness

Run a package through the current daemon build:

```powershell
halod plugin-test .\openrgb
```

`test.lua` returns `function(h) ... end`.

| Harness API | Meaning |
|---|---|
| `h:open({ reads = {...} })` | Open a declared HID device over a recording transport. |
| `h:open_integration({ reads = {...} })` | Open an integration root over mock TCP. |
| `h:assert(condition, message)` | Record an assertion. |
| `h:assert_eq(actual, expected, message)` | Record an equality assertion. |
| `dev:initialize()` | Run the real plugin initialization path. |
| `dev:apply(state)` | Run RGB state application. |
| `dev:get_batteries()` | Run the declared battery capability and return its readings. |
| `dev:set_range(key, value)` | Exercise a runtime range-control write. |
| `dev:set_dpi(dpi)` | Exercise a direct DPI write through the host's bound validation. |
| `dev:enumerate_controllers()` | Return integration controller records. |
| `dev:keyboard_layout_status()` | Return resolved runtime keyboard keys/layout. |
| `dev:rgb_descriptor()` | Return the resolved RGB zones and LED positions. |
| `dev:writes()` | Recorded byte writes. |
| `dev:clear()` | Clear recorded writes. |

The current recording harness covers HID and TCP. SMBus and USB-control packages are still parsed
and validated by the daemon, but need unit/integration coverage in the main repository for mocked
transport behavior.
