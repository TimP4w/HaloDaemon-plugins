-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: Aleksandr Mezin <mezin.alexander@gmail.com>
--
-- NZXT RGB & fan controllers for HaloDaemon: Control Hub, RGB & Fan
-- Controller and Smart Device V2. No LEDs or sensors of their own; every zone
-- lives on a chained accessory.
--
-- Protocol reference: the Linux kernel `nzxt-smart2` hwmon driver by
-- Aleksandr Mezin (GPL-2.0-or-later). Verified offsets: firmware/accessory
-- handshake shared with Kraken (0x10/0x20); lighting 0x26 0x04 (data) / 0x26
-- 0x06 (commit); fan status push 0x67 0x02 (rpm/duty), fan config push 0x61
-- 0x03 (fan type); set fan duty 0x62 0x01.

local catalogue = halod.require("lib.accessories")
local effects = halod.require("lib.effects")

-- channel → LED count of everything chained on it, from the last detection.
local channel_leds = {}

local REPORT = 64

-- `paired`: each port carries both a fan and its RGB chain.
local MODELS = {
  [0x2022] = { fans = 5, rgb = 5, max_leds = 96, paired = true },
}
local DEFAULT_MODEL = { fans = 3, rgb = 2, max_leds = 40, paired = false }

local function model(dev)
  return MODELS[dev.match.pid] or DEFAULT_MODEL
end

local function fan_count(dev)
  return model(dev).fans
end

local function channel_name(i)
  return "Channel " .. (i + 1)
end

-- One 0x26 0x04 GRB data packet (unpadded) plus a 64-byte 0x26 0x06 commit,
-- for the given channel's bitmask.
local function write_channel(dev, channel, colors)
  local ch_byte = 1 << channel
  local parts = {}
  for _, c in ipairs(colors) do
    parts[#parts + 1] = string.char(c.g, c.r, c.b)
  end
  local grb = table.concat(parts)

  local data = halod.buffer(4 + #grb)
  data:set_u8(0, 0x26)
  data:set_u8(1, 0x04)
  data:set_u8(2, ch_byte)
  data:set_u8(3, 0x00)
  data:set_bytes(4, grb)
  dev.transport:write(data)

  local commit = halod.buffer(64)
  commit:set_u8(0, 0x26)
  commit:set_u8(1, 0x06)
  commit:set_u8(2, ch_byte)
  commit:set_u8(3, 0x00)
  commit:set_bytes(4, string.char(0x01, 0x00, 0x00, 0x18, 0x00, 0x00, 0x80, 0x00, 0x32, 0x00, 0x00, 0x01))
  dev.transport:write(commit)
end

-- On paired models `cooling_channel` hands a port's fan to whichever
-- accessory is detected there, so it is never controllable from both places.
local function describe(dev, rgb_count)
  local m = model(dev)
  local channels, cooling = {}, {}
  for i = 0, rgb_count - 1 do
    channels[#channels + 1] = {
      id = tostring(i), name = channel_name(i),
      chainable = true, max_leds = m.max_leds, color_order = "rgb",
      cooling_channel = (m.paired and i < m.fans) and tostring(i) or nil,
    }
  end
  for i = 0, m.fans - 1 do
    cooling[#cooling + 1] = { id = tostring(i), name = channel_name(i), kind = "fan", controllable = true }
  end
  return channels, cooling
end

local function cooling_entry(status, i)
  local t = status.fan_type and status.fan_type[i]
  return {
    id = tostring(i), name = channel_name(i), kind = "fan",
    controllable = t ~= nil and t ~= 0,
    rpm = (status.rpm and status.rpm[i]) or 0,
    duty = (status.duty and status.duty[i]) or 0,
  }
end

local function fan_index(dev, channel_id)
  local ch = assert(tonumber(channel_id), "invalid cooling channel")
  if ch < 0 or ch >= fan_count(dev) then
    error(string.format("fan channel %s out of range (max %d)", tostring(channel_id), fan_count(dev) - 1))
  end
  return ch
end

return {
  initialize = function(dev)
    -- Configure the hardware's own status-push interval to ~1000ms (control
    -- byte 3: 488 + (3-1)*256), matching the `poll` cadence above.
    dev.transport:write(string.char(0x60, 0x02, 0x01, 0xE8, 0x03, 0x01, 0xE8, 0x03))
    dev.transport:write(string.char(0x60, 0x03)) -- detect_fans: triggers a fan-config push
    local reported = catalogue.query(dev, REPORT)
    local rgb_count = model(dev).rgb
    if reported then
      rgb_count = 0
      for ch in pairs(reported) do rgb_count = math.max(rgb_count, ch + 1) end
    end
    local channels, cooling = describe(dev, rgb_count)
    log(string.format("NZXT fan controller initialized: %d RGB, %d fan channels", rgb_count, fan_count(dev)))
    return {
      ok = true,
      channels = channels,
      cooling = { channels = cooling },
      accessories = catalogue.list(model(dev).paired),
      native_effects = effects.descriptors(),
    }
  end,

  apply = function(dev, state)
    if state.mode ~= "native_effect" then return end
    for ch = 0, 7 do
      local leds = channel_leds[ch]
      if leds and leds > 0 then
        dev.transport:write(effects.packet(state.id, state.params, 1 << ch, leds))
      end
    end
  end,

  -- RGB, routed by the host through whichever channel a chained accessory occupies.
  write_frame = function(dev, channel, bytes)
    local colors = {}
    for i = 1, #bytes, 3 do colors[#colors + 1] = { r = bytes[i] or 0, g = bytes[i + 1] or 0, b = bytes[i + 2] or 0 } end
    write_channel(dev, tonumber(channel), colors)
  end,

  -- Status pushes: 0x67 0x02 (rpm+duty+fan_type for every channel) or 0x61
  -- 0x03 (fan_type only, e.g. right after detect_fans). A 0x61 push updates
  -- only fan_type, keeping the last known rpm/duty. Drain every report that is
  -- already queued: these are unsolicited hardware pushes, so consuming only
  -- one per host poll can make tach data trail reality by minutes.
  read_status = function(dev)
    local fans = fan_count(dev)
    local status = dev.status or { rpm = {}, duty = {}, fan_type = {} }
    -- Bound the drain so a broken/noisy device cannot monopolize the plugin
    -- worker. The normal queue contains only a handful of 64-byte reports.
    for _ = 1, 64 do
      local ok, bytes = pcall(function()
        return dev.transport:read_nonblocking(REPORT)
      end)
      if not ok or #bytes == 0 then break end
      local r = halod.buffer(bytes)
      if #r >= 40 + fans and r:get_u8(0) == 0x67 and r:get_u8(1) == 0x02 then
        local rpm, duty, fan_type = {}, {}, {}
        for i = 0, fans - 1 do
          rpm[i] = r:get_u16_le(24 + i * 2)
          duty[i] = r:get_u8(40 + i)
          fan_type[i] = r:get_u8(16 + i)
        end
        status = { rpm = rpm, duty = duty, fan_type = fan_type }
      elseif #r >= 16 + fans and r:get_u8(0) == 0x61 and r:get_u8(1) == 0x03 then
        local fan_type = {}
        for i = 0, fans - 1 do fan_type[i] = r:get_u8(16 + i) end
        status = { rpm = status.rpm, duty = status.duty, fan_type = fan_type }
      end
    end
    status.cooling = {}
    for i = 0, fans - 1 do
      status.cooling[#status.cooling + 1] = cooling_entry(status, i)
    end
    return status
  end,

  -- Per-channel cooling telemetry/control, routed from chained accessories.
  get_cooling_status = function(dev, channel_id)
    return cooling_entry(dev.status or {}, fan_index(dev, channel_id))
  end,
  set_cooling_duty = function(dev, channel_id, duty)
    local ch = fan_index(dev, channel_id)
    local pkt = halod.buffer(11)
    pkt:set_u8(0, 0x62)
    pkt:set_u8(1, 0x01)
    pkt:set_u8(2, 1 << ch)
    pkt:set_u8(3 + ch, math.max(0, math.min(100, duty)))
    dev.transport:write(pkt)
  end,

  -- First accessory on each RGB channel.
  detect_accessories = function(dev)
    local out = {}
    local reported = catalogue.query(dev, REPORT) or {}
    for ch = 0, 7 do
      local ids = reported[ch]
      local leds = 0
      for _, id in ipairs(ids or {}) do leds = leds + catalogue.leds(id) end
      channel_leds[ch] = leds
      if ids and ids[1] then out[#out + 1] = { channel = ch, accessory = ids[1] } end
    end
    return out
  end,
}
