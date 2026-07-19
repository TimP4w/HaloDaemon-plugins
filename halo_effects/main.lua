-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- The official RGB effects plugin for HaloDaemon — the reference
-- implementation for the effect-plugin API and the library of stock
-- pixmap/direct effects.
--
-- An effect-only plugin (`type = "effect"`) declares no hardware match and
-- registers straight into the RGB engine's effect catalog:
--
--   * pixmap effects fill a shared 400x300 linear-RGBA buffer once per
--     frame; every zone using it then samples the buffer at its LED
--     positions.
--   * direct effects compute one color per LED directly from its chain
--     position, once per zone per frame.
--
-- Direct effects convert manifest sRGB colors to linear light explicitly;
-- the engine applies the device transfer function on output. No permissions
-- are needed — effects are pure compute and never touch hardware.

-- 256-entry rainbow palette, built once at load time so plasma's render loop
-- never computes a hue conversion per pixel — 120000 pixels/frame in
-- interpreted Lua adds up fast otherwise.
local PALETTE = {}
for i = 0, 255 do
  PALETTE[i] = { halod.hsv(i / 255.0, 1.0, 1.0) }
end

-- Scratch tables shared by every pixmap render below, hoisted so the worker
-- VM reuses them across frames instead of re-allocating (and GC'ing) a table
-- per frame. Each effect fully overwrites the slots it uses before reading
-- them, so no stale values leak between frames or between effects (only one
-- render_effect_<id> callback ever runs in a given worker VM instance).
local COL, ROW, PARTS = {}, {}, {}

-- Eases `current` toward `target` with time constant `tau` seconds (`<= 0`
-- snaps instantly), so responsiveness is independent of the tick rate. Same
-- formula the native direct effects use.
local function ease_toward(current, target, tau, dt)
  local alpha
  if tau <= 1e-6 then
    alpha = 1.0
  else
    alpha = 1.0 - math.exp(-dt / tau)
  end
  return current + (target - current) * alpha
end

local function clamp01(v)
  return math.max(0.0, math.min(1.0, v))
end

local function sensor_value(ctx, id)
  local catalog = ctx:data("host.sensors.catalog")
  if catalog.status == "unavailable" then return nil end
  for _, item in ipairs(catalog.value) do
    if item.id == id then
      local snapshot = ctx:data(item.key)
      if snapshot.status ~= "unavailable" then return snapshot.value.value end
      return nil
    end
  end
  return nil
end

local function linear_rgb(ctx, color, brightness)
  return ctx:srgb_to_linear(color.r / 255.0) * brightness,
    ctx:srgb_to_linear(color.g / 255.0) * brightness,
    ctx:srgb_to_linear(color.b / 255.0) * brightness
end

local DEFAULT_STEPS = {
  { value = 40, color = { r = 0, g = 255, b = 0 } },
  { value = 60, color = { r = 255, g = 140, b = 0 } },
  { value = 80, color = { r = 255, g = 0, b = 0 } },
}

return {
  render_effect_plasma = function(buf, ctx)
    local t, params = ctx.time, ctx.params
    local w, h = halod.canvas_w, halod.canvas_h
    local speed = params.speed or 0.8
    local sin, char, floor = math.sin, string.char, math.floor

    local col, row, parts = COL, ROW, PARTS
    for x = 0, w - 1 do
      col[x] = sin((x / w) * 10.0 + t * speed)
    end
    for y = 0, h - 1 do
      row[y] = sin((y / h) * 8.0 - t * speed * 0.7)
    end

    local concat = table.concat
    for y = 0, h - 1 do
      local ry = row[y]
      for x = 0, w - 1 do
        local v = 1.0 + 0.5 * col[x] + 0.5 * ry
        -- frac < 1, so * 256 floors to exactly 0..255 (256 buckets, not 255)
        local c = PALETTE[floor((v * 0.5 % 1.0) * 256.0)]
        parts[x + 1] = char(c[1], c[2], c[3], 255)
      end
      buf:set_bytes(y * w * 4, concat(parts))
    end
  end,

  -- Pixmap: a horizontal hue sweep, one row built once and copied to every
  -- scanline (the color only varies with x).
  render_effect_rainbow = function(buf, ctx)
    local t, params = ctx.time, ctx.params
    local w, h = halod.canvas_w, halod.canvas_h
    local speed = params.speed or 0.2
    local scale = params.scale or 1.0
    local offset = t * speed
    local char, concat = string.char, table.concat

    local parts = PARTS
    for x = 0, w - 1 do
      local hue = (x / w) * scale + offset
      local r, g, b = halod.hsv(hue, 1.0, 1.0)
      parts[x + 1] = char(r, g, b, 255)
    end
    local row_bytes = concat(parts, "", 1, w)
    for y = 0, h - 1 do
      buf:set_bytes(y * w * 4, row_bytes)
    end
  end,

  -- Pixmap: one of `cells` equal columns lights up per `interval` seconds,
  -- decaying exponentially and deterministically picked from the seeded host
  -- RNG — a pure function of `t`, so it
  -- needs no persisted state across frames or worker restarts.
  render_effect_random_flash = function(buf, ctx)
    local t, params = ctx.time, ctx.params
    local w, h = halod.canvas_w, halod.canvas_h
    local cells = math.max(2, math.min(8, math.floor((params.cells or 4.0) + 0.5)))
    local interval = params.interval or 1.0
    local decay = params.decay or 0.6
    local random_color = params.random_color or false
    local color = params.color or { r = 56, g = 189, b = 248 }
    local char, floor, exp = string.char, math.floor, math.exp

    local function epoch_seed(epoch)
      return epoch % 16777213
    end
    local function pick(seed, prev)
      if cells <= 1 then
        return 0
      end
      local idx = floor(ctx:random(seed) * cells) % cells
      if prev ~= nil and idx == prev then
        return (idx + 1) % cells
      end
      return idx
    end
    local function pick_for_epoch(epoch)
      return pick(epoch_seed(epoch), nil)
    end

    local epoch = floor(math.max(t, 0.0) / interval)
    local idx = pick_for_epoch(epoch)
    local lit_at = epoch * interval
    local brightness = exp(-math.max(t - lit_at, 0.0) / decay)
    local r, g, b = color.r, color.g, color.b
    if random_color then
      r, g, b = halod.hsv(ctx:random(epoch_seed(epoch) * 7 + 3), 1.0, 1.0)
    end
    local lr = floor(r * brightness + 0.5)
    local lg = floor(g * brightness + 0.5)
    local lb = floor(b * brightness + 0.5)

    local black_row = string.rep(char(0, 0, 0, 255), w)
    for y = 0, h - 1 do
      buf:set_bytes(y * w * 4, black_row)
    end
    local x0 = math.floor(idx * w / cells)
    local x1 = math.floor((idx + 1) * w / cells)
    if x1 > x0 then
      local lit_row = string.rep(char(lr, lg, lb, 255), x1 - x0)
      for y = 0, h - 1 do
        buf:set_bytes(y * w * 4 + x0 * 4, lit_row)
      end
    end
  end,

  -- Pixmap: `ctx.audio.bands` (64 values, 0..1) as a bottom-anchored
  -- bar (or solid-fill) chart, each band lerped between color_low/high.
  render_effect_audio_spectrum = function(buf, ctx)
    local params = ctx.params
    local w, h = halod.canvas_w, halod.canvas_h
    local color_low = params.color_low or { r = 0, g = 120, b = 255 }
    local color_high = params.color_high or { r = 255, g = 0, b = 120 }
    local bars = params.fill ~= "solid"
    local bands = ctx.audio.bands
    local n = #bands
    local char, concat, floor = string.char, table.concat, math.floor
    local black = char(0, 0, 0, 255)

    local starts = {}
    for i = 1, n do
      local x0 = floor((i - 1) * w / n)
      local x1 = floor(i * w / n)
      if x1 < x0 then
        x1 = x0
      end
      local x_end = x1
      if bars and (x1 - x0) >= 2 then
        x_end = x1 - 1
      end
      local amp = clamp01(bands[i])
      local bar_h = floor(amp * h + 0.5)
      local tt = (i - 1) / math.max(n - 1, 1)
      local color = ctx:lerp_color(color_low, color_high, tt)
      starts[i] = {
        x0 = x0,
        x_end = x_end,
        y_start = h - bar_h,
        bytes = char(floor(color.r + 0.5), floor(color.g + 0.5), floor(color.b + 0.5), 255),
      }
    end

    local parts = PARTS
    for y = 0, h - 1 do
      -- Pre-fill the whole row black first: bar mode leaves a 1px gap
      -- between x_end and the next band's x0 that no band segment covers.
      for x = 1, w do
        parts[x] = black
      end
      for i = 1, n do
        local s = starts[i]
        if y >= s.y_start then
          for x = s.x0, s.x_end - 1 do
            parts[x + 1] = s.bytes
          end
        end
      end
      buf:set_bytes(y * w * 4, concat(parts, "", 1, w))
    end
  end,

  -- Direct: `leds` is an array of {id, zone_id, p, p_ring, nx, ny} (`p` is
  -- fractional chain position). Return one linear {r, g, b} per LED, 0..1 —
  -- a comet head sweeping the chain with a short fading tail.
  led_effect_comet = function(leds, ctx)
    local t, params = ctx.time, ctx.params
    local color = params.color or { r = 0, g = 160, b = 255 }
    local cr, cg, cb = linear_rgb(ctx, color, 1.0)
    local speed = params.speed or 0.3
    local dir = (params.direction == "backward") and -1.0 or 1.0
    local head = (t * speed * dir) % 1.0
    local out = {}
    for i, led in ipairs(leds) do
      local d = math.abs(led.p - head)
      d = math.min(d, 1.0 - d) -- wrap around the chain
      local bright = math.max(0.0, 1.0 - d * 8.0)
      out[i] = { r = cr * bright, g = cg * bright, b = cb * bright }
    end
    return out
  end,

  -- Direct: brightness pulses as sin(t*speed*pi)^2 — a pure function of `t`,
  -- so it's safe to call once per zone per tick without persisted state.
  led_effect_breathing = function(leds, ctx)
    local t, params = ctx.time, ctx.params
    local color = params.color or { r = 0, g = 128, b = 255 }
    local speed = params.speed or 0.5
    local phase = math.sin(t * speed * math.pi)
    local bright = phase * phase
    local cr, cg, cb = linear_rgb(ctx, color, bright)
    local out = {}
    for i in ipairs(leds) do
      out[i] = { r = cr, g = cg, b = cb }
    end
    return out
  end,

  -- Direct: flashes on a loud onset (`ctx.audio.flux` crossing a
  -- sensitivity-scaled threshold on a new DSP frame) and decays otherwise.
  -- `leds` is called once per zone per tick, all sharing the same `frame`; the
  -- `last_frame` guard below makes the state update idempotent across those
  -- repeat calls instead of double-decaying multi-zone devices.
  led_effect_audio_beat = (function()
    local state = { pulse = 0.0, last_seq = 0, last_frame = nil }
    return function(leds, ctx)
      local dt, params = ctx.dt, ctx.params
      local decay = params.decay or 0.4
      local sensitivity = params.sensitivity or 0.5
      if state.last_frame ~= ctx.frame then
        local audio = ctx.audio
        local threshold = 0.6 - 0.5 * sensitivity
        if audio.seq ~= state.last_seq and audio.flux >= threshold then
          state.pulse = 1.0
        else
          state.pulse = state.pulse * math.exp(-dt / (decay / 3.0))
        end
        state.last_seq = audio.seq
        state.last_frame = ctx.frame
      end
      local color = params.color or { r = 255, g = 40, b = 40 }
      local cr, cg, cb = linear_rgb(ctx, color, state.pulse)
      local out = {}
      for i in ipairs(leds) do
        out[i] = { r = cr, g = cg, b = cb }
      end
      return out
    end
  end)(),

  -- Direct: brightness eases toward `ctx.audio.level`. Same `last_frame`
  -- idempotency guard as audio_beat above.
  led_effect_audio_level = (function()
    local state = { display_level = 0.0, last_frame = nil }
    local MAX_TAU = 0.5
    return function(leds, ctx)
      local dt, params = ctx.dt, ctx.params
      local smoothing = params.smoothing or 0.3
      local sensitivity = params.sensitivity or 1.0
      if state.last_frame ~= ctx.frame then
        local audio = ctx.audio
        local target = clamp01(audio.level * sensitivity)
        local tau = clamp01(smoothing) * MAX_TAU
        state.display_level = ease_toward(state.display_level, target, tau, dt)
        state.last_frame = ctx.frame
      end
      local bright = state.display_level
      local r, g, b
      if params.hue_shift then
        local hue = 0.66 - 0.66 * bright
        r, g, b = halod.hsv(hue, 1.0, 1.0)
      else
        local color = params.color or { r = 0, g = 200, b = 120 }
        r, g, b = color.r, color.g, color.b
      end
      local out = {}
      local cr, cg, cb = linear_rgb(ctx, { r = r, g = g, b = b }, bright)
      for i in ipairs(leds) do
        out[i] = { r = cr, g = cg, b = cb }
      end
      return out
    end
  end)(),

  -- Direct: colors a zone (`mode = "gradient"`) or fills it up to the
  -- reading (`mode = "meter"`) along a two-stop gradient, normalized against
  -- [min, max]. The selected host sensor snapshot is the live reading, or nil
  -- while unset/unavailable — the effect fades to black rather than snapping
  -- when it disappears.
  led_effect_sensor_gradient = (function()
    local state = { display_level = 0.0, presence = 0.0, last_frame = nil }
    local MAX_TAU = 5.0
    return function(leds, ctx)
      local dt, params = ctx.dt, ctx.params
      local sensor = sensor_value(ctx, params.sensor or "")
      local min = params.min or 20.0
      local max = params.max or 90.0
      local smoothing = params.smoothing or 0.3
      if state.last_frame ~= ctx.frame then
        local target_level, target_presence
        if sensor ~= nil then
          local range = max - min
          if math.abs(range) > 1e-6 then
            target_level = clamp01((sensor - min) / range)
          else
            target_level = 0.0
          end
          target_presence = 1.0
        else
          target_level, target_presence = state.display_level, 0.0
        end
        local tau = clamp01(smoothing) * MAX_TAU
        state.display_level = ease_toward(state.display_level, target_level, tau, dt)
        state.presence = ease_toward(state.presence, target_presence, tau, dt)
        state.last_frame = ctx.frame
      end

      local mode = params.mode or "gradient"
      local color_a = params.color_a or { r = 0, g = 128, b = 255 }
      local color_b = params.color_b or { r = 255, g = 0, b = 0 }
      local level, presence = state.display_level, state.presence
      local out = {}
      for i, led in ipairs(leds) do
        local r, g, b
        if mode == "meter" and led.p > level then
          r, g, b = 0.0, 0.0, 0.0
        elseif mode == "meter" then
          local color = ctx:lerp_color(color_a, color_b, led.p)
          r, g, b = color.r, color.g, color.b
        else
          local color = ctx:lerp_color(color_a, color_b, level)
          r, g, b = color.r, color.g, color.b
        end
        local cr, cg, cb = linear_rgb(ctx, { r = r, g = g, b = b }, presence)
        out[i] = { r = cr, g = cg, b = cb }
      end
      return out
    end
  end)(),

  -- Direct: snaps to the color of the highest step whose threshold the
  -- smoothed sensor reading has reached. Same context sensor and fade-to-black
  -- semantics as sensor_gradient above.
  led_effect_sensor_steps = (function()
    local state = { display_value = nil, presence = 0.0, last_frame = nil }
    local MAX_TAU = 5.0
    return function(leds, ctx)
      local dt, params = ctx.dt, ctx.params
      local sensor = sensor_value(ctx, params.sensor or "")
      local smoothing = params.smoothing or 0.3
      if state.last_frame ~= ctx.frame then
        local tau = clamp01(smoothing) * MAX_TAU
        if sensor ~= nil then
          if state.display_value == nil then
            state.display_value = sensor
          else
            state.display_value = ease_toward(state.display_value, sensor, tau, dt)
          end
        end
        local target_presence = (sensor ~= nil) and 1.0 or 0.0
        state.presence = ease_toward(state.presence, target_presence, tau, dt)
        state.last_frame = ctx.frame
      end

      local steps = params.steps or DEFAULT_STEPS
      local sorted = {}
      for i, s in ipairs(steps) do
        sorted[i] = s
      end
      table.sort(sorted, function(a, b) return a.value < b.value end)

      local color = { r = 0, g = 0, b = 0 }
      if state.display_value ~= nil and #sorted > 0 then
        local v = state.display_value
        local chosen = nil
        for i = 1, #sorted do
          if v >= sorted[i].value then
            chosen = sorted[i]
          end
        end
        if chosen then color = chosen.color end
      end
      local presence = state.presence
      local cr, cg, cb = linear_rgb(ctx, color, presence)
      local out = {}
      for i in ipairs(leds) do
        out[i] = { r = cr, g = cg, b = cb }
      end
      return out
    end
  end)(),
}
