-- SPDX-License-Identifier: GPL-3.0-or-later
-- Stock LCD widgets. Widget policy and composition live here; Rust exposes
-- only bounded drawing primitives and host-owned data/font access.

local function color(value, fallback)
  return value or fallback
end

local PRIMARY = { r = 0, g = 200, b = 220 }
local BRAND_PURPLE = { r = 155, g = 127, b = 224 }
local WHITE = { r = 255, g = 255, b = 255 }
local MUTED = { r = 148, g = 163, b = 184 }

local function center_text(canvas, w, h, text, size, ctx, col, y)
  local tw, th = ctx:measure_text(text, size)
  ctx:draw_text(canvas, text, (w - tw) / 2, y or ((h - th) / 2), size, col)
end

local function center_text_fit(canvas, w, h, text, size, ctx, col, y, max_w)
  local width = ctx:measure_text(text, size)
  if width > (max_w or w) then size = math.max(1, size * (max_w or w) / width) end
  center_text(canvas, w, h, text, size, ctx, col, y)
end

local function clock_text(params, ctx)
  local now = ctx:local_time()
  local variant = params.variant or "24h"
  if variant == "12h" then
    local hour = now.hour % 12
    if hour == 0 then hour = 12 end
    return string.format("%d:%02d %s", hour, now.minute, now.hour >= 12 and "PM" or "AM")
  end
  if variant == "24h_seconds" then
    return string.format("%02d:%02d:%02d", now.hour, now.minute, now.second)
  end
  return string.format("%02d:%02d", now.hour, now.minute)
end

local function date_text(params, ctx)
  local now = ctx:local_time()
  return string.format("%02d/%02d/%04d", now.day, now.month, now.year)
end

local function render_clock(canvas, w, h, params, ctx)
  center_text_fit(canvas, w, h, clock_text(params, ctx), h * 0.64, ctx, nil, nil, w * 0.94)
end

local function render_date(canvas, w, h, params, ctx)
  center_text_fit(canvas, w, h, date_text(params, ctx), h * 0.58, ctx, nil, nil, w * 0.94)
end

local function render_text(canvas, w, h, params, ctx)
  center_text_fit(canvas, w, h, params.text or "TEXT", h * 0.64, ctx, nil, nil, w * 0.96)
end

local function render_sensor(canvas, w, h, params, ctx)
  local id = params.sensor or ""
  local value = ctx:sensor(id)
  local label = params.label
  if not label or label == "" then label = ctx:sensor_label(id) or "Sensor" end
  local shown = value and string.format("%.0f", value) or "--"
  if value and params.show_unit ~= false then shown = shown .. (ctx:sensor_unit(id) or "") end
  if params.show_value ~= false then center_text(canvas, w, h, shown, h * 0.30, ctx, color(params.value_color, WHITE)) end
  center_text(canvas, w, h, label, h * 0.14, ctx, color(params.label_color, MUTED), h * 0.76)
end

local function render_spectrum(canvas, w, h, params, ctx)
  local count = math.max(8, math.min(64, math.floor((params.bands or 32) + 0.5)))
  local available = ctx:audio_band_count()
  local bar_w = w / count
  for i = 0, count - 1 do
    local src = math.floor(i * math.max(1, available) / count)
    if params.mirror then src = math.floor(math.abs(i - (count - 1) / 2) * math.max(1, available) * 2 / count) end
    local level = available > 0 and (ctx:audio_band(src) or 0) or (0.22 + 0.58 * math.abs(math.sin(i * 0.71)))
    local x = params.flip_h and (count - 1 - i) or i
    local bh = math.max(1, h * 0.82 * math.max(0, math.min(1, level)))
    local y = params.flip_v and h * 0.09 or h * 0.91 - bh
    ctx:fill_rect(canvas, x * bar_w, y, math.max(1, bar_w - 1), bh, color(params.fill, PRIMARY))
  end
end

local function render_gauge(canvas, w, h, params, ctx)
  local level
  if (params.input or "audio") == "sensor" then
    local value = ctx:sensor(params.sensor or "")
    local min = params.min or 0
    local max = params.max or 100
    if value then level = (value - min) / math.max(0.001, max - min) end
  else
    level = ctx:audio_level()
  end
  level = math.max(0, math.min(1, level or 0.62))
  local fill = color(params.fill, PRIMARY)
  local track = color(params.track, { r = 30, g = 41, b = 59 })
  local style = params.style or "ring"
  if style == "bar" then
    local x, y, bw, bh = w * 0.08, h * 0.42, w * 0.84, h * 0.16
    local radius = math.min(bh / 2, params.radius or 8)
    ctx:fill_rounded_rect(canvas, x, y, bw, bh, radius, track)
    ctx:fill_rounded_rect(canvas, x, y, bw * level, bh, radius, fill)
  elseif style == "arc" then
    local r = math.min(w, h) * 0.40
    local thickness = math.max(2, math.min(w, h) * 0.10)
    local start = 225 + (tonumber(params.arc_rotation) or 0)
    local sweep = 270
    local cap = thickness * 0.5 * math.max(0, math.min(100, params.border_radius or 100)) / 100
    ctx:draw_arc(canvas, w / 2, h / 2, r, thickness, start, sweep, cap, track)
    if level > 0 then ctx:draw_arc(canvas, w / 2, h / 2, r, thickness, start, sweep * level, cap, fill) end
  else
    local r = math.min(w, h) * 0.40
    local thickness = math.max(2, math.min(w, h) * 0.10)
    if params.transparent_background ~= true then
      ctx:draw_circle(canvas, w / 2, h / 2, math.max(1, r - thickness / 2), true,
        color(params.background, { r = 15, g = 18, b = 28 }))
    end
    ctx:draw_arc(canvas, w / 2, h / 2, r, thickness, 0, 360, 0, track)
    if level > 0 then ctx:draw_arc(canvas, w / 2, h / 2, r, thickness, 0, 360 * level, 0, fill) end
  end
end

local function render_now_playing(canvas, w, h, params, ctx)
  local title = ctx:media_title() or "Not playing"
  local artist = ctx:media_artist() or "No media player"
  local padding = math.max(2, w * 0.04)
  local text_x = padding
  if params.show_art ~= false then
    local side = h * 0.76
    ctx:draw_media_art(canvas, padding, h * 0.12, side, side)
    text_x = padding + side + padding
  end
  local available = math.max(1, w - text_x - padding)
  if params.show_title ~= false then
    local size = h * 0.22
    ctx:draw_text(canvas, ctx:ellipsize_text(title, size, available), text_x, h * 0.25, size, params.title_color)
  end
  if params.show_artist ~= false then
    local size = h * 0.15
    ctx:draw_text(canvas, ctx:ellipsize_text(artist, size, available), text_x, h * 0.58, size, params.artist_color)
  end
end

local function render_shape(canvas, w, h, params, ctx)
  local shape = params.shape or "circle"
  local col = color(params.fill, PRIMARY)
  local filled = params.filled ~= false
  if shape == "circle" then
    ctx:draw_circle(canvas, w / 2, h / 2, math.min(w, h) * 0.42, filled, col)
  elseif shape == "line" then
    ctx:draw_line(canvas, w * 0.08, h / 2, w * 0.92, h / 2, col)
  elseif shape == "triangle" then
    ctx:draw_triangle(canvas, w / 2, h * 0.08, w * 0.92, h * 0.90, w * 0.08, h * 0.90, filled, col)
  else
    if filled then
      ctx:fill_rect(canvas, w * 0.08, h * 0.08, w * 0.84, h * 0.84, col)
    else
      ctx:draw_line(canvas, w * 0.08, h * 0.08, w * 0.92, h * 0.08, col)
      ctx:draw_line(canvas, w * 0.92, h * 0.08, w * 0.92, h * 0.92, col)
      ctx:draw_line(canvas, w * 0.92, h * 0.92, w * 0.08, h * 0.92, col)
      ctx:draw_line(canvas, w * 0.08, h * 0.92, w * 0.08, h * 0.08, col)
    end
  end
end

local function render_logo(canvas, w, h, params, ctx)
  if params.show_img ~= false then
    local side = math.min(w, h) * (params.show_text == false and 0.82 or 0.52)
    ctx:draw_asset(canvas, "logo.svg", (w - side) / 2, h * 0.08, side, side, "contain")
  end
  if params.show_text ~= false then
    local size = h * 0.15
    local halo_w = ctx:measure_text("halo", size)
    local daemon_w = ctx:measure_text("daemon", size)
    local x = (w - halo_w - daemon_w) / 2
    ctx:draw_text(canvas, "halo", x, h * 0.68, size, WHITE)
    ctx:draw_text(canvas, "daemon", x + halo_w, h * 0.68, size, BRAND_PURPLE)
  end
end

local function render_debug(canvas, w, h, dt, params, ctx)
  local text = ctx:is_preview() and "60.0 FPS" or string.format("%.1f FPS", dt > 0 and 1 / dt or 0)
  center_text_fit(canvas, w, h, text, h * 0.58, ctx, nil, nil, w * 0.94)
end

local function render_image(canvas, w, h, params, ctx)
  if not ctx:draw_image(canvas, params.filename or "", 0, 0, w, h, params.fit or "fit", params.shape or "rect") then
    ctx:fill_rect(canvas, w * 0.08, h * 0.08, w * 0.84, h * 0.84, { r = 30, g = 41, b = 59 })
    ctx:draw_line(canvas, w * 0.15, h * 0.78, w * 0.45, h * 0.42, { r = 0, g = 200, b = 220 })
    ctx:draw_line(canvas, w * 0.45, h * 0.42, w * 0.85, h * 0.78, { r = 0, g = 200, b = 220 })
  end
end

return {
  render_widget_clock = function(c,w,h,t,dt,p,x) render_clock(c,w,h,p,x) end,
  preview_widget_clock = render_clock,
  render_widget_date = function(c,w,h,t,dt,p,x) render_date(c,w,h,p,x) end,
  preview_widget_date = render_date,
  render_widget_sensor = function(c,w,h,t,dt,p,x) render_sensor(c,w,h,p,x) end,
  preview_widget_sensor = render_sensor,
  render_widget_text = function(c,w,h,t,dt,p,x) render_text(c,w,h,p,x) end,
  preview_widget_text = render_text,
  render_widget_image = function(c,w,h,t,dt,p,x) render_image(c,w,h,p,x) end,
  preview_widget_image = render_image,
  render_widget_logo = function(c,w,h,t,dt,p,x) render_logo(c,w,h,p,x) end,
  preview_widget_logo = render_logo,
  render_widget_debug = function(c,w,h,t,dt,p,x) render_debug(c,w,h,dt,p,x) end,
  preview_widget_debug = function(c,w,h,p,x) render_debug(c,w,h,0,p,x) end,
  render_widget_audio_spectrum = function(c,w,h,t,dt,p,x) render_spectrum(c,w,h,p,x) end,
  preview_widget_audio_spectrum = render_spectrum,
  render_widget_gauge = function(c,w,h,t,dt,p,x) render_gauge(c,w,h,p,x) end,
  preview_widget_gauge = render_gauge,
  render_widget_now_playing = function(c,w,h,t,dt,p,x) render_now_playing(c,w,h,p,x) end,
  preview_widget_now_playing = render_now_playing,
  render_widget_shape = function(c,w,h,t,dt,p,x) render_shape(c,w,h,p,x) end,
  preview_widget_shape = render_shape,
}
