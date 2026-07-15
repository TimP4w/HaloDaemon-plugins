-- SPDX-License-Identifier: MIT
-- SPDX-FileCopyrightText: 2021 Smasty <hello@smasty.net>
--
-- G560 vendor long reports, derived from g560-led by Smasty.  This is not
-- HID++ device feature traffic: every command is a fixed 0x11/20-byte packet
-- addressed to receiver device number 0xff.

local ZONES = {
  { id = "zone_0", name = "Left Secondary", address = 0x00 },
  { id = "zone_1", name = "Right Secondary", address = 0x01 },
  { id = "zone_2", name = "Left Primary", address = 0x02 },
  { id = "zone_3", name = "Right Primary", address = 0x03 },
}

local function long_report(feature, fn, payload)
  local packet = string.char(0x11, 0xff, feature, fn) .. (payload or "")
  return packet .. string.rep("\0", 20 - #packet)
end

local function write_zone(dev, zone, color)
  dev.transport:write(long_report(0x04, 0x3a,
    string.char(zone.address, 0x01, color.r, color.g, color.b, 0x02)))
end

local function color_or_black(color)
  return color or { r = 0, g = 0, b = 0 }
end

return {
  initialize = function(_dev)
    return {
      ok = true,
      zones = {
        { id = "zone_0", name = "Left Secondary", topology = "linear", led_count = 1 },
        { id = "zone_1", name = "Right Secondary", topology = "linear", led_count = 1 },
        { id = "zone_2", name = "Left Primary", topology = "linear", led_count = 1 },
        { id = "zone_3", name = "Right Primary", topology = "linear", led_count = 1 },
      },
      controls = {
        ranges = {
          { key = "subwoofer_volume", label = "Subwoofer Volume", min = 0, max = 100,
            step = 1, default = 50, category = "Audio" },
        },
      },
      ranges = { subwoofer_volume = 50 },
    }
  end,

  apply = function(dev, state)
    if state.mode == "static" then
      for _, zone in ipairs(ZONES) do write_zone(dev, zone, state.color) end
    elseif state.mode == "per_led" then
      local values = state.zones or {}
      for _, zone in ipairs(ZONES) do
        write_zone(dev, zone, color_or_black((values[zone.id] or {})["0"]))
      end
    end
  end,

  write_frame = function(dev, zone_id, colors)
    for _, zone in ipairs(ZONES) do
      if zone.id == zone_id then
        write_zone(dev, zone, color_or_black(colors[1]))
        return
      end
    end
  end,

  set_range = function(dev, key, value)
    if key ~= "subwoofer_volume" then error("unknown range key: " .. key) end
    local volume = math.max(0, math.min(100, math.floor(value)))
    dev.transport:write(long_report(0x09, 0x1c, string.char(volume)))
  end,
}
