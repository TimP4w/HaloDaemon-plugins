# Lua plugin API reference

HaloDaemon uses Lua 5.4. `plugin.yaml` declares devices, permissions,
transports, capabilities, config fields, effects, and widgets. The entry script
returns callback functions.

Each physical device gets one Lua VM and one worker. Dynamic children share the
root VM, but each child keeps its own `dev` table. Transport calls are
synchronous from Lua's point of view.

See the [manifest reference](manifest-reference.md) for the YAML format.

## Entry script

```lua
return {
  initialize = function(dev)
    return true
  end,

  write_frame = function(dev, channel_id, bytes)
    -- bytes: flat R,G,B byte array in the channel's declared LED order
  end,

  close = function(dev)
  end,
}
```

HaloDaemon does not run Lua while reading the manifest. It runs the entry script
only after activation and consent. Keep module-level code limited to constants
and helper functions. Do device or network I/O inside callbacks.

## Globals and sandbox

The sandbox includes `string`, `table`, `math`, and Lua 5.4 operators. It also
includes `string.pack` and `string.unpack`. HaloDaemon adds:

| Global | Meaning |
|---|---|
| `log(message)` | Write a plugin log message. Pass a string. |
| `halod.config` | This plugin's resolved config values. Booleans are Lua booleans; number, port, and duration fields are numbers; textual fields are strings. |
| `halod.platform` | Target platform name such as `windows` or `linux`. |
| `halod.sleep_ms(ms)` | Block this device worker for a protocol delay; capped at 5000 ms. |
| `halod.monotonic_ms()` | Permission-free elapsed-milliseconds clock for rate limiting/caching. |
| `halod.buffer(value)` | Allocate a zeroed buffer by length or copy a Lua string. |
| `halod.require(name)` | Load a package-local module, for example `lib.hidpp.v1`. |
| `halod.publish(key, value)` | Publish a declared bounded latest-value record. |
| `halod.invalidate(key)` | Mark a declared provided record unavailable. |
| `halod.data(key)` | Read a declared consumed record snapshot. |

`halod.require` loads only modules indexed from this package's `lib/` directory.
It does not read the filesystem at runtime. Absolute paths, `..`, path
separators, symlinks, and modules from another plugin are rejected.

`os`, `io`, `package`, `require`, `dofile`, `loadfile`, `load`, `debug`, and
`collectgarbage` are removed. With `os` permission, a small `os` table provides
only `os.time()` and `os.clock()`.

Each VM has a 64 MiB Lua memory limit. Each callback has a 50,000,000 instruction
budget. Device calls time out after 30 seconds; effect calls after 2 seconds.
Do not busy-wait. Use `halod.sleep_ms` only for required hardware delays.

## Shared snapshot data

The data API accepts booleans, finite numbers, strings, contiguous arrays, and
string-keyed maps. Functions, userdata, handles, sparse or mixed tables,
cycles, nil values, and non-finite numbers are rejected.

```lua
halod.publish("telemetry.current", {
  load = 0.42,
  observed_at = 1784246400,
})

local snapshot = halod.data("telemetry.current")
if snapshot.status == "fresh" then log(snapshot.value.load) end
```

Snapshots report `fresh`, `stale`, or `unavailable`, plus a revision and host
timestamps. Stale snapshots retain their last value. Widget and effect
contexts also expose `ctx:data(key)`. Audio remains a dedicated stream.

## The `dev` object

Every device callback receives `dev` first.

| Member | Meaning |
|---|---|
| `dev.transport` | Transport userdata documented below. |
| `dev.match.transport` | Transport kind: `hid`, `usb`, `smbus`, `hwmon`, `command`, `amd_smn`, `lpcio`, `tcp`, or `http`. |
| `dev.match.vid`, `.pid` | Matched USB IDs when available. |
| `dev.match.bus`, `.addr` | SMBus bus kind and matched address when available. |
| `dev.match.index` | Remote controller index for an integration child. |
| `dev.match.key` | Optional stable route key for a dynamic child. |
| `dev.match.name` | Optional child name returned by discovery. |
| `dev.channels` | Host-provided static lighting-channel descriptors. |
| `dev.status` | Latest value returned by `read_status`; set by the polling loop. |
| `dev.audio` | Audio-routing userdata when `audio_routing` is granted. |

Extra transport-specific numeric fields may also appear in `dev.match` for a
dynamic child.

## Lifecycle and dynamic identity

### `pre_scan(dev)`

Runs once on each matching SMBus bus before probing addresses. The device match
must set `pre_scan: true`. The callback can access only `addresses` and
`extra_addresses` from the manifest. Plugin config is not available. The call
has a 5-second timeout and requires the `smbus` permission.

### `initialize(dev) -> boolean | table | nil`

Called after the transport opens. Return `false` or `{ ok = false }` to reject
the device. Return `true`, `nil`, or a table to accept it. A table can report
model-specific information:

```lua
return {
  ok = true,
  model = "Firmware " .. version,
  -- Optional device-specific subset of plugin.yaml's advertised union.
  -- Undeclared names are ignored and reported as manifest mismatches.
  capabilities = { "lighting", "controls" },
  channels = {
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
  cooling = { channels = {
    { id = "pump", name = "Pump", kind = "pump", controllable = true },
    { id = "fan1", name = "Radiator fan", kind = "fan", controllable = true },
  } },
  division = { { id = "out1", name = "Output 1", max_leds = 40 } },
  ranges = { brightness = 70 },
  choices = { mode = 1 }, -- option indexes are zero-based
}
```

If `capabilities` is omitted, HaloDaemon uses the full list from the manifest.
Plugins that support several models should return the correct subset.

### `close(dev)`

Optional cleanup before the worker exits. HaloDaemon also removes managed audio
sinks if the worker exits unexpectedly.

### `event(dev, event)`

Optional callback for transport events. HID events contain
`event.transport == "hid"`, `event.endpoint` (`primary` or `companion`), and the
raw `event.report` string. Return `{ button_events = { pressed = {...}, released = {...} } }`
to forward transitions to the host input engine. A dynamic root may define
`event_source(event) -> index | 0 | false`: a positive index dispatches to that
child, `0` or `nil` dispatches to the root, and `false` discards the report.

## Capability callbacks

All signatures below omit return values when the callback returns nothing. Arrays are ordinary
1-based Lua arrays; protocol/control indexes documented as indexes or slots retain their stated
host values and are commonly zero-based.

| Capability | Callback signature |
|---|---|
| Lighting | `apply(dev, state)`; `write_frame(dev, channel_id, bytes)` |
| Cooling | `initialize` returns `cooling = { channels = {{id, name, kind = "fan"|"pump", controllable}, ...} }`; `get_cooling_status(dev, channel_id) -> {id, name, kind, controllable, duty?, rpm?}`; `set_cooling_duty(dev, channel_id, duty)` |
| Sensor | `get_sensors(dev) -> sensors` |
| Poll | `read_status(dev) -> any` for slowly refreshed state without notifications. HID/button notifications use `event()`. |
| Lighting division | `detect_accessories(dev) -> {{channel, accessory}, ...}`; division-channel frames arrive through the same `write_frame(dev, channel_id, bytes)` |
| Division accessory cooling | Accessory children expose their own cooling channel; the parent handles it through `get_cooling_status(dev, channel_id)` and `set_cooling_duty(dev, channel_id, duty)`. |
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

`state` passed to `apply` is tagged by `state.mode` (`static`, `per_led`, or
`native_effect`): `static` carries a single `state.color`, and `per_led` carries
`state.channels[channel_id][led_index]` colour maps. Software `write_frame` frames
receive `bytes` as a flat R,G,B byte array in the channel's declared LED order.

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

Every integration implements the typed validation hook:

```lua
validate = function(context)
  if not context.config.host or context.config.host == "" then
    return { ok = false, reason = "A device address is required." }
  end
  return { ok = true }
end
```

`context.config` contains the integration's declared configuration, including
credentials only when the plugin has `secure_storage` consent. Halo invokes
`validate` before enabling and after an interactive setup. Return `ok` and an
optional user-facing `reason`; setup does not complete when `ok` is false.

For `setup.modes: [automatic]`, Halo performs the manifest-declared mDNS and
SSDP scans, normalizes their output, and calls:

```lua
discover = function(context)
  local candidates = {}
  for _, service in ipairs(context.mdns or {}) do
    candidates[#candidates + 1] = {
      id = service.id,
      name = service.name,
      values = { host = service.addresses[1] },
    }
  end
  return candidates
end
```

mDNS records contain `service`, `id`, `name`, `host`, `port`, `addresses`, and
`txt`. SSDP records contain `service`, `id`, `name`, `location`, `source`, and
`server`. Candidate IDs must be unique and stable. `values` may contain only
non-secure config keys declared by the manifest. Halo renders the candidates;
plugins cannot return arbitrary controls or modal markup.

Button authentication invokes `pair(context)` after the user follows the
manifest instructions:

```lua
pair = function(context)
  local token = try_pair(context.config.host)
  if not token then
    return { ok = false, pending = true, reason = "Press the button, then retry." }
  end
  return { ok = true, values = { token = token } }
end
```

`values` may include declared secure fields; Halo persists them through its
secret store. `pending = true` keeps the user on the pairing screen. Errors
remain retryable. OAuth2 PKCE is host-owned and does not call `pair`.

After setup, an integration root implements:

```lua
enumerate_controllers = function(dev)
  return {
    {
      index = 0,
      name = "Keyboard",
      device_type = "keyboard", -- optional; defaults to "other"
      serial = "ABC123",       -- optional; used for conflict detection
      location = "HID: ...",   -- optional; used for conflict detection
      channels = {
        { id = "main", name = "Main", topology = "linear", led_count = 20 },
      },
    },
  }
end
```

Each record describes identity and routing. It may include `id`, `key`, `serial`,
`location`, numeric `extra` fields, and simple `channels` data used by tests. Each
record becomes a separate device. The child receives its index in
`dev.match.index` and its optional key in `dev.match.key`.

Children use the normal callbacks, such as `initialize`, `apply`, and
`write_frame`. Use `dev.match.index` or `dev.match.key` to route the call.

## Stream transport: HID and TCP

Byte inputs accept a Lua string or `halod.buffer`. Reads return Lua strings.

| Method | Result |
|---|---|
| `dev.transport:write(data)` | Write bytes. |
| `:read(size)` | Read bytes. |
| `:read_nonblocking(size)` | Read without waiting. |
| `:read_any(size)` | Read from either HID collection. |
| `:defer_event(data)` | Put a report back into the HID event path. |
| `:write_then_read(data, size)` | Write, then read a reply. |
| `:feature_exchange(data, size)` | HID feature-report exchange (send then get). |
| `:send_feature_report(data)` | Send a feature report; no reply. `data[1]` is the report id. |
| `:get_feature_report(report_id, size)` | Read a feature report for `report_id`; `size` excludes the report-id byte. |
| `:get_input_report(report_id, size)` | Read an input report for `report_id`; `size` excludes the report-id byte. |
| `:write_many({data, ...})` | Write several packets. |
| `:has_companion()` | Whether a companion HID collection is open. |
| `:write_companion(data)` | Write to the companion collection. |
| `:read_companion(size)` | Read from the companion collection. |
| `:write_then_read_companion(data, size)` | Write and read on the companion. |
| `:write_many_companion({data, ...})` | Write several companion packets. |

Companion methods work only when `transports.hid.companion` is declared and the
collection opens successfully.

TCP has no message framing. Its `read(size)` returns exactly `size` bytes or
fails on timeout or EOF. Read a fixed header first, then read its stated payload
length. HID padding is handled by the HID transport.

Serial ports are the same exact-length byte stream as TCP, plus line control:

| Method | Purpose |
| --- | --- |
| `:set_dtr(level)` | Assert/clear the DTR line. |
| `:set_rts(level)` | Assert/clear the RTS line. |
| `:send_break(duration_ms)` | Assert BREAK for a bounded duration, then clear. |
| `:flush_input()` | Discard buffered inbound bytes. |

When the manifest sets `serial.events: true` and the package declares an
`event()` callback, unsolicited inbound bytes arrive through the event path.

## USB endpoint transport

```lua
local written = dev.transport:usb_write(endpoint, bytes, timeout_ms, device_id)
local bytes = dev.transport:usb_read(endpoint, length, timeout_ms, device_id)
local result = dev.transport:usb_control(
  request_type, request, value, index, bytes, read_length, timeout_ms, device_id)
```

`device_id` is optional and defaults to `"primary"`. Bulk and interrupt reads
may return fewer bytes than requested. Writes send all bytes or fail.

For control IN, pass `""` as `bytes` and set `read_length`. The result is a Lua
string. For control OUT, pass the bytes and set `read_length` to `0`. The result
is the transferred byte count. The device, endpoint, size, and timeout must all
fit the manifest rules.

## Command transport

The command transport exposes an allowlisted runner:

```lua
local result = command.run("nvidia-smi", { "--query-gpu=name" })
-- result = {
--   success = true,
--   exit_code = 0,
--   stdout = "...",
--   stderr = "...",
--   timed_out = false,
-- }
```

The executable must appear in `transports.command.commands`. Arguments are
passed directly without a shell. Non-zero exits return `success = false` with
their exit code and bounded stderr. A timeout returns `timed_out = true`; a
failure to resolve or spawn the executable raises a Lua error. The same result
is returned by `dev.transport:run(executable, args)`.

## Windows typed transports

AMD SMN provides:

```lua
local value = dev.transport:amd_smn_read(offset)
```

LPCIO provides these typed methods:

```text
lpcio_select_slot(slot)
lpcio_find_bars()
lpcio_prepare_hwm(slot, unlock)
lpcio_read_port(port)
lpcio_write_port(port, value)
lpcio_hwm_read(base, register)
lpcio_hwm_write(base, register, value)
lpcio_superio_inb(register)
lpcio_superio_outb(register, value)
```

These methods are available only on Windows and only with the matching
permission and transport. They do not expose the raw broker handle.

## Linux hwmon transport

An hwmon integration root can enumerate the scoped collection:

```lua
for _, chip in ipairs(dev.transport:hwmon_list()) do
  local value = dev.transport:hwmon_read(chip.key, "temp1_input")
  dev.transport:hwmon_write(chip.key, "pwm1", "128")
end
```

Each record contains `key`, `stable_id`, `name`, and an `attributes` array.
Keys are opaque and paths are never exposed. Reads return a string or `nil` for
an unavailable supported attribute. Writes accept unsigned-integer strings and
are restricted to available `pwmN` and `pwmN_enable` attributes. The host
meters writes and restores original PWM-enable values during teardown.

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

An address outside the manifest scope raises an error. The `ops` value is valid
only inside the `batch` callback. Do not save it for later use.

## Scoped HTTP requests

A plugin that declares an `http` transport and holds the `network` permission
gets `halod.http:request{…}`. It is a capability global (like `halod.publish`),
not `dev.transport:` userdata; there is no persistent socket. Each call is a
synchronous, bounded request validated against the declared origins before a
socket opens.

```lua
local r = halod.http:request{
  method = "GET",                       -- optional, defaults to GET
  origin = "https://api.example.com",   -- required; must be a declared origin
  path = "/v1/status",                  -- optional
  headers = { ["accept"] = "application/json" },
  body = "",                            -- optional string
  timeout_ms = 3000,                    -- optional; capped by max_timeout_ms
}

print(r.status)                         -- numeric HTTP status
print(r.headers["content-type"])        -- header names are lowercased
if r.json then print(r.json.value) end  -- parsed JSON body when the body is JSON
print(r.body)                           -- always the raw response body string
```

`origin` must exactly match one of the manifest's `origins`. When an origin uses
the `{host}` placeholder, pass the resolved `scheme://host[:port]` form (the
value substituted from the `host_key` config field). Requests that exceed the
declared method set, size limits, timeout, or origin scope raise an error.

## Scoped UDP datagrams

A plugin that declares a `udp` transport and holds the `network` permission gets
`halod.udp`, a capability global for exchanging datagrams with the single
configured destination. There is no `send_to`; every datagram goes to the one
vetted host/port.

```lua
halod.udp:send{ bytes = "\x01\x02\x03" }        -- returns the byte count sent

local reply = halod.udp:receive{ timeout_ms = 1000 }  -- capped by recv_timeout_ms
if reply then print(#reply) end                 -- a datagram string, or nil on timeout
```

`send` raises an error if the payload exceeds `max_datagram_bytes`. `receive`
returns the next datagram (truncated to `max_datagram_bytes`) or `nil` when no
datagram arrives before the timeout.

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

## Widget callbacks

Widget callbacks are returned from `main.lua` alongside the other callbacks.
Every widget declared in `plugin.yaml` implements both functions below.

| Callback | Meaning |
|---|---|
| `render_widget_<id>(buffer, width, height, time, dt, params, ctx)` | Render the current frame. `time` is elapsed engine time and `dt` is the frame interval. |
| `preview_widget_<id>(buffer, width, height, params, ctx)` | Render a deterministic, non-transparent still frame without live data. This callback is mandatory. |

`buffer` is bounded RGBA data, `width` and `height` are its canvas dimensions,
and `params` contains the editor values declared by the widget manifest.
HaloDaemon uses the preview when a declared data or audio source is
unavailable. `halod plugin-test` verifies that its 128×128 output is visible.

### Widget context

All context methods are bounded to the widget canvas.

| Method | Meaning |
|---|---|
| `ctx:is_preview()` | Whether the callback is producing a preview. |
| `ctx:color()` | Selected widget color. |
| `ctx:data(key)` | Read a manifest-declared immutable snapshot. |
| `ctx:local_time()` | Host-local date and time. |
| `ctx:audio()` | `{ level, flux, beat, seq, bands }`, or `nil`. |
| `ctx:push_clip(x, y, width, height)`, `ctx:pop_clip()` | Intersect drawing with a canvas-space clip rectangle. |
| `ctx:push_opacity(value)`, `ctx:pop_opacity()` | Multiply image and primitive opacity by a value from 0 to 1. |
| `ctx:push_rotation(degrees, center_x, center_y)`, `ctx:pop_rotation()` | Rotate subsequent drawing around a canvas point. |
| `ctx:fill_rect(...)`, `ctx:fill_rounded_rect(...)` | Draw a filled rectangle. |
| `ctx:draw_line(...)`, `ctx:draw_circle(...)`, `ctx:draw_arc(...)`, `ctx:draw_triangle(...)` | Draw bounded vector primitives; lines and hollow shapes accept an optional final stroke width. |
| `ctx:draw_polyline(buffer, points, color?, stroke_width?)` | Draw 2–64 points as connected line segments. |
| `ctx:draw_polygon(buffer, points, filled, color?, stroke_width?)` | Draw 3–64 points as a filled or stroked closed polygon. |
| `ctx:draw_image(...)` | Draw host-provided declared image data. |
| `ctx:draw_asset(...)` | Draw the widget icon or an SVG listed in its manifest `assets`; undeclared names return `false`. |
| `ctx:draw_media_art(...)` | Draw current album art. |
| `ctx:measure_text(text, size)` | Measure text in the selected system font. |
| `ctx:ellipsize_text(text, size, max_width)` | Truncate text at Unicode character boundaries. |
| `ctx:draw_text(buffer, text, x, y, size, color?)` | Draw styled text. |
| `ctx:measure_text_box(text, width, style)` | Return the width and height of host-laid-out text. |
| `ctx:draw_text_box(buffer, text, x, y, width, height, style, color?)` | Draw the same layout, clipped to the text box and widget canvas. |

`fill_rounded_rect(buffer, x, y, width, height, radius, color?)` rasterizes the
complete rounded rectangle on one pixel grid. `draw_arc(buffer, cx, cy, radius,
thickness, start_degrees, sweep_degrees, cap_radius, color?)` draws clockwise
from the top; `cap_radius` is clamped to half the stroke thickness.

Preview callbacks receive deterministic audio and time records. Snapshot data
reports `unavailable` rather than returning a partial table.

Text uses the host-selected system font. Widgets declaring `uses_font`
automatically receive the editor's weight, italic, underline, and
strikethrough settings. Lua never loads or rasterizes font files.

Text-box `style` requires `size` and accepts `horizontal` (`left`, `center`, or
`right`), `vertical` (`top`, `middle`, or `bottom`), `wrap` (`none`, `word`, or
`character`), `max_lines` (1–64), and `overflow` (`clip` or `ellipsis`). The
host owns shaping, Unicode boundaries, font selection, measurement, and bounds
checking; unknown fields and invalid sizes are rejected.

Polyline and polygon points use `{x = 10, y = 20}` or `{10, 20}` entries.
Clip, opacity, and rotation calls are nested independently and must be balanced;
each stack has a maximum depth of eight. Coordinates, opacity, stroke widths,
and rotations must be finite. Stroke widths are limited to 0.25–32 pixels, and
the host enforces a per-frame drawing-work budget so valid callbacks remain
inside the widget timeout. These APIs do not expose paths, shaders, font files,
or filesystem-backed image access.

## Effect API

Pixmap callbacks mutate a 400×300 linear-RGBA buffer:

```lua
render_effect_plasma = function(buf, ctx)
end
```

Direct effects return one linear-light `{r, g, b}` value (0..1) per input LED:

```lua
led_effect_comet = function(leds, ctx)
  -- leds entries: { id, channel_id, p, p_ring, nx, ny }
  return colors
end
```

Only the declared-id callback forms are accepted. Every callback receives the
same engine-frame snapshot:

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

Pixmap callbacks use the synthetic `canvas` zone. Direct callbacks receive the
actual device zone, and LED `id` and `channel_id` remain stable across frames.
Effects read declared sensor and scalar host data through `ctx:data(key)`.

Context helpers are deterministic for a stable effect seed:

| API | Meaning |
|---|---|
| `halod.canvas_w`, `halod.canvas_h` | Pixmap dimensions. |
| `halod.hsv(h, s, v)` | HSV to sRGB byte triplet. |
| `ctx:random(stream)` | Seeded value in `[0, 1)`; the optional integer stream selects a reproducible value. |
| `ctx:noise1d(x)`, `ctx:noise2d(x, y)` | Seeded, platform-stable value noise in `[0, 1]`. |
| `ctx:lerp_color(a, b, amount)` | Clamp and interpolate `{r, g, b}` records. |
| `ctx:gradient(stops, amount)` | Interpolate 2–16 `{at, color}` stops. |
| `ctx:srgb_to_linear(value)` | Convert a normalized sRGB channel to linear light. |
| `ctx:linear_to_srgb(value)` | Convert a normalized linear-light channel to sRGB. |

A stateful direct effect may run once per zone in the same engine frame. Guard
time-dependent state with `ctx.frame` so smoothing and decay advance only once
on multi-zone devices. Identical seeds and inputs produce bit-identical random
and noise values across frames and supported platforms.

## `test.lua` harness

Run a package through the current daemon build:

```powershell
halod plugin-test .\openrgb
```

`test.lua` returns `function(h) ... end`.

| Harness API | Meaning |
|---|---|
| `h:open({ reads = {...}, pid = ..., companion = ... })` | Open the first declared HID, USB, or TCP device with recording transports. |
| `h:open_integration({ reads = {...} })` | Open an integration root over mock TCP. |
| `h:open_integration({ hwmon = {...} })` | Open an hwmon integration over fixture chips. |
| `h:assert(condition, message)` | Record an assertion. |
| `h:assert_eq(actual, expected, message)` | Record an equality assertion. |
| `dev:initialize()` | Run the real plugin initialization path. |
| `dev:apply(state)` | Run lighting state application. |
| `dev:write_frame(channel, bytes)` | Run a software lighting frame. |
| `dev:write_divided_frame(channel, bytes)` | Run a lighting-division frame. |
| `dev:get_cooling_status(channel)` | Read a cooling channel's status. |
| `dev:set_cooling_duty(channel, duty)` | Exercise a cooling duty write. |
| `dev:lcd_stream_frame(bytes, width, height, rotation, raw, brightness)` | Run an LCD frame callback. |
| `dev:get_batteries()` | Run the declared battery capability and return its readings. |
| `dev:set_range(key, value)` | Exercise a runtime range-control write. |
| `dev:set_choice(key, value)` | Exercise a choice control. |
| `dev:set_dpi(dpi)` | Exercise a direct DPI write through the host's bound validation. |
| `dev:enumerate_controllers()` | Return integration controller records. |
| `dev:open_controller(index)` | Open one enumerated integration child for capability tests. |
| `dev:hwmon_read(key, attribute)` | Inspect a fixture attribute after plugin writes. |
| `dev:keyboard_layout_status()` | Return resolved runtime keyboard keys/layout. |
| `dev:lighting_descriptor()` | Return the resolved lighting channels and LED positions. |
| `dev:writes()` | Recorded byte writes. |
| `dev:usb_writes()` | Recorded USB endpoint/control writes with device routing metadata. |
| `dev:queue_read(bytes)` | Add a scripted transport reply. |
| `dev:queue_event(bytes)` | Add a scripted HID event. |
| `dev:pump_events()` | Deliver queued HID events. |
| `dev:clear()` | Clear recorded writes. |

An hwmon fixture record contains `stable_id`, `name`, and an `attributes` string
map. The recording harness covers HID, TCP, USB endpoint/control, and scoped
hwmon traffic.
Physical timing, interface claims, and firmware behavior still need hardware
tests.
