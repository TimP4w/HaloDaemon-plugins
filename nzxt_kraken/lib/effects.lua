-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- Firmware lighting effects (`2A 04`), shared by nzxt_kraken and
-- nzxt_kraken_x3. Report: 2A 04 ch ch, mode, speed u16 LE, 16 GRB slots,
-- byte 55 = direction<<1 | moving, 56 = colour count, 57 = effect constant,
-- 58 = channel LED count, 59 = effect length.

local SPEEDS = { "slowest", "slow", "normal", "fast", "fastest" }
local RAINBOW = { 350, 300, 250, 150, 80 }

local function color_param(id, label, c)
  return { id = id, label = label, kind = { kind = "color" }, default = c }
end
local SPEED = { id = "speed", label = "Speed", kind = { kind = "enum", options = SPEEDS }, default = "normal" }
local DIRECTION = { id = "direction", label = "Direction", kind = { kind = "enum", options = { "forward", "backward" } }, default = "forward" }
local MOVING = { id = "moving", label = "Moving", kind = { kind = "boolean" }, default = false }
local WHITE, RED, BLUE = { r = 255, g = 255, b = 255 }, { r = 255, g = 0, b = 0 }, { r = 0, g = 0, b = 255 }

-- colors: parameter ids in report order; k: byte 57.
local EFFECTS = {
  { id = "breathing", name = "Breathing", mode = 0x07, speeds = { 40, 30, 20, 10, 4 }, colors = { "color" }, k = 8 },
  { id = "fading", name = "Fading", mode = 0x01, speeds = { 80, 60, 40, 20, 10 }, colors = { "color1", "color2" }, k = 8 },
  { id = "covering_marquee", name = "Covering Marquee", mode = 0x04, speeds = RAINBOW, colors = { "color1", "color2" }, direction = true },
  { id = "pulse", name = "Pulse", mode = 0x06, speeds = { 25, 20, 15, 7, 4 }, colors = { "color" }, k = 8 },
  { id = "spectrum_wave", name = "Spectrum Wave", mode = 0x02, speeds = RAINBOW, colors = {}, direction = true },
  { id = "alternating", name = "Alternating", mode = 0x05, speeds = { 1600, 1300, 1000, 800, 600 },
    moving_speeds = { 800, 700, 500, 400, 300 }, colors = { "color1", "color2" }, direction = true, moving = true },
  { id = "starry_night", name = "Starry Night", mode = 0x09, speeds = { 25, 20, 15, 7, 4 }, colors = { "color" } },
  { id = "rainbow_flow", name = "Rainbow Flow", mode = 0x0B, speeds = RAINBOW, colors = {}, direction = true },
  { id = "super_rainbow", name = "Super Rainbow", mode = 0x0C, speeds = RAINBOW, colors = {}, direction = true },
  { id = "rainbow_pulse", name = "Rainbow Pulse", mode = 0x0D, speeds = RAINBOW, colors = {}, direction = true },
  { id = "candle", name = "Candle", mode = 0x08, fixed_speed = 50, colors = { "color" } },
  { id = "tai_chi", name = "Tai Chi", mode = 0x0E, speeds = { 50, 40, 30, 20, 10 }, colors = { "color1", "color2" }, direction = true, k = 5 },
  { id = "water_cooler", name = "Water Cooler", mode = 0x0F, speeds = { 50, 40, 30, 20, 10 }, colors = { "color1", "color2" }, k = 5 },
  { id = "swish", name = "Swish", mode = 0x10, speeds = { 20, 15, 10, 7, 4 }, colors = { "color" }, k = 4 },
}

local by_id = {}
for _, e in ipairs(EFFECTS) do by_id[e.id] = e end

local M = {}

function M.descriptors()
  local out = {}
  for _, e in ipairs(EFFECTS) do
    local params = {}
    for i, id in ipairs(e.colors) do
      local label = #e.colors > 1 and ("Color " .. i) or "Color"
      params[#params + 1] = color_param(id, label, i == 1 and (#e.colors > 1 and RED or WHITE) or BLUE)
    end
    if not e.fixed_speed then params[#params + 1] = SPEED end
    if e.direction then params[#params + 1] = DIRECTION end
    if e.moving then params[#params + 1] = MOVING end
    out[#out + 1] = { id = e.id, name = e.name, params = params }
  end
  return out
end

local function speed_value(e, params)
  if e.fixed_speed then return e.fixed_speed end
  local table_ = (e.moving and params.moving) and e.moving_speeds or e.speeds
  for i, name in ipairs(SPEEDS) do
    if params.speed == name then return table_[i] end
  end
  return table_[3]
end

-- One `2A 04` report for channel byte `ch` driving `leds` LEDs.
function M.packet(id, params, ch, leds)
  local e = by_id[id]
  if not e then error("NZXT: unknown native effect " .. tostring(id)) end
  params = params or {}
  local b = halod.buffer(64)
  b:set_u8(0, 0x2A)
  b:set_u8(1, 0x04)
  b:set_u8(2, ch)
  b:set_u8(3, ch)
  b:set_u8(4, e.mode)
  b:set_u16_le(5, speed_value(e, params))
  for i, pid in ipairs(e.colors) do
    local c = params[pid] or WHITE
    local base = 7 + (i - 1) * 3
    b:set_u8(base, c.g)
    b:set_u8(base + 1, c.r)
    b:set_u8(base + 2, c.b)
  end
  local dir = (e.direction and params.direction == "backward") and 1 or 0
  local moving = (e.moving and params.moving) and 1 or 0
  b:set_u8(55, (dir << 1) | moving)
  b:set_u8(56, #e.colors)
  b:set_u8(57, e.k or 0)
  b:set_u8(58, math.min(leds, 255))
  b:set_u8(59, 3)
  return b
end

return M
