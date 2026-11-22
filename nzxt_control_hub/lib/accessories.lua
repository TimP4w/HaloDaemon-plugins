-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- NZXT V2 accessory catalogue, keyed by the id the `21 03` lighting-info reply
-- reports. Shared verbatim by the nzxt_kraken, nzxt_kraken_x3 and
-- nzxt_control_hub packages. Layout: "ring", "linear", or a ring count for
-- multi-fan frames; `fan` marks accessories that sit on a fan header.

local ROWS = {
  { 1, "HUE+ LED Strip", 10, "linear" },
  { 2, "Aer RGB", 8, "ring", true },
  { 4, "HUE 2 LED Strip (10 LEDs)", 10, "linear" },
  { 5, "HUE 2 LED Strip (8 LEDs)", 8, "linear" },
  { 6, "HUE 2 LED Strip (6 LEDs)", 6, "linear" },
  { 7, "HUE 2 Cable Comb", 18, "linear" },
  { 8, "HUE 2 Cable Comb", 14, "linear" },
  { 9, "HUE 2 Underglow (300 mm)", 15, "linear" },
  { 10, "HUE 2 Underglow (200 mm)", 10, "linear" },
  { 11, "Aer RGB 2 (120 mm)", 8, "ring", true },
  { 12, "Aer RGB 2 (140 mm)", 8, "ring", true },
  { 13, "Vertagear Chair Head", 10, "linear" },
  { 14, "Vertagear Chair Head", 40, "linear" },
  { 15, "Vertagear Chair Bottom", 10, "linear" },
  { 16, "Kraken X3 Ring", 8, "ring", false, true },
  { 17, "Kraken X3 Logo", 1, "linear", false, true },
  { 18, "Kraken 120", 9, "ring", false, true },
  { 19, "F120 RGB", 18, "ring", true },
  { 20, "F140 RGB", 18, "ring", true },
  { 21, "F120 RGB Duo", 20, "ring", true },
  { 22, "F140 RGB Duo", 20, "ring", true },
  { 23, "F120 RGB Core", 8, "ring", true },
  { 24, "F140 RGB Core", 8, "ring", true },
  { 25, "F120 RGB Core (case)", 8, "ring", true },
  { 26, "F140 RGB Core (case)", 8, "ring", true },
  { 27, "F240 RGB Core", 16, 2, true },
  { 28, "F280 RGB Core", 16, 2, true },
  { 29, "F360 RGB Core", 24, 3, true },
  { 30, "Kraken Elite V2 Ring", 24, "ring", false, true },
  { 31, "F420 RGB Core", 24, 3, true },
  { 32, "Performance Fan (120 mm)", 16, "linear", true },
  { 33, "Performance Fan (140 mm)", 16, "linear", true },
  { 34, "Performance Fan (240 mm)", 24, "linear", true },
  { 35, "Performance Fan (280 mm)", 24, "linear", true },
  { 36, "Performance Fan (360 mm)", 32, "linear", true },
  { 38, "Kraken Core", 19, "linear", false, true },
  { 39, "N9 Z890 Cover", 49, "linear" },
  { 40, "N9 Z890 Cover", 31, "linear" },
  { 41, "F240 RGB Core (EV)", 16, 2, true },
  { 42, "F360 RGB Core (EV)", 24, 3, true },
  { 43, "RGB Case Fan (360 mm)", 24, 3, true },
  { 44, "Ultra RGB Fan (120 mm)", 32, "ring", true },
  { 45, "Ultra RGB Fan (140 mm)", 32, "ring", true },
  { 46, "Ultra RGB Fan (240 mm)", 64, 2, true },
  { 47, "Ultra RGB Fan (280 mm)", 64, 2, true },
  { 48, "Ultra RGB Fan (360 mm)", 96, 3, true },
  { 49, "N9 X870E Cover", 17, "linear" },
  { 50, "Ultra RGB Fan (420 mm)", 96, 3, true },
  { 51, "F120 RGB Fan (2026)", 8, "ring", true },
  { 52, "F140 RGB Fan (2026)", 8, "ring", true },
  { 53, "F240 RGB Fan (2026)", 16, 2, true },
  { 54, "F280 RGB Fan (2026)", 16, 2, true },
  { 55, "F360 RGB Fan (2026)", 24, 3, true },
  { 56, "F420 RGB Fan (2026)", 24, 3, true },
  { 62, "F360 RGB Reverse Fan (2026)", 24, 3, true },
  { 63, "F420 RGB Reverse Fan (2026)", 24, 3, true },
  { 64, "F360 RGB Fan (2026)", 24, 3, true },
  { 65, "F420 RGB Fan (2026)", 24, 3, true },
  { 66, "F120 RGB Fan (2026)", 8, "ring", true },
  { 67, "F140 RGB Fan (2026)", 8, "ring", true },
  { 68, "F360 RGB Reverse Fan (2026)", 24, 3, true },
  { 69, "F420 RGB Reverse Fan (2026)", 24, 3, true },
}

local SLOTS_PER_CHANNEL = 6

local M = {}

local builtin = {}
for _, row in ipairs(ROWS) do
  if row[6] then builtin[row[1]] = true end
end

-- Accessory descriptors for the host. `fans = false` for headers that carry
-- lighting only, so no accessory claims a cooling channel.
function M.list(fans)
  local out = {}
  for _, row in ipairs(ROWS) do
    local id, name, leds, layout, fan = row[1], row[2], row[3], row[4], row[5]
    local acc = { id = id, name = name, led_count = leds, fan = (fans and fan) or false }
    if type(layout) == "number" then
      acc.topology, acc.rings = "rings", layout
    else
      acc.topology = layout
    end
    out[#out + 1] = acc
  end
  return out
end

-- True for the pump head's own zones, which some coolers list as channel 0.
function M.is_builtin(id)
  return builtin[id] == true
end

-- `21 03` reply → { [channel] = { id, id, ... } }; byte 14 is the channel
-- count (0 on some firmware, meaning one), then six slots per channel.
function M.parse_reply(r)
  if #r < 15 or r:get_u8(0) ~= 0x21 or r:get_u8(1) ~= 0x03 then return nil end
  local out = {}
  for ch = 0, math.min(math.max(r:get_u8(14), 1), 8) - 1 do
    local ids = {}
    for slot = 0, SLOTS_PER_CHANNEL - 1 do
      local off = 15 + ch * SLOTS_PER_CHANNEL + slot
      if off >= #r then break end
      local id = r:get_u8(off)
      if id ~= 0 then ids[#ids + 1] = id end
    end
    out[ch] = ids
  end
  return out
end

-- Send `20 03` and return the parsed reply, or nil if none arrives.
function M.query(dev, report_size)
  dev.transport:write(string.char(0x20, 0x03))
  for _ = 1, 16 do
    local ok, s = pcall(function() return dev.transport:read(report_size) end)
    if not ok or #s == 0 then return nil end
    local parsed = M.parse_reply(halod.buffer(s))
    if parsed then return parsed end
  end
  return nil
end

-- The first external accessory on any channel, for coolers whose only
-- chainable header is the radiator-fan port.
function M.first_external(channels)
  if not channels then return nil end
  for ch = 0, 15 do
    for _, id in ipairs(channels[ch] or {}) do
      if not builtin[id] then return id end
    end
  end
  return nil
end

return M
