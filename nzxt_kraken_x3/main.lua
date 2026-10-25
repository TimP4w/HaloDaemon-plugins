-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: liquidctl contributors <https://github.com/liquidctl/liquidctl>
--
-- NZXT Kraken X53/X63/X73 plugin for HaloDaemon — the older X-series wire
-- protocol, distinct from (and simpler than) the Z/Elite family in
-- `nzxt_kraken.lua`: an 8-LED ring plus a single logo LED, no LCD, and pump speed control.
--
-- Protocol reference: nzxt_kraken_x3/docs/protocol.md and liquidctl's kraken3 driver.
-- Verified offsets: status report 0x75 (shared with Z/Elite); RGB `0x22 0x10`
-- per-channel data packets (60 bytes/packet, two packets for 8 LEDs) + `0x22
-- 0xA0` commit; logo `0x2A 0x04`.

local REPORT = 64

local function grb_string(colors)
  local parts = {}
  for _, c in ipairs(colors) do
    parts[#parts + 1] = string.char(c.g, c.r, c.b)
  end
  return table.concat(parts)
end

-- Two 64-byte `0x22 0x10|n` data packets (60 GRB bytes each) plus a 16-byte
-- `0x22 0xA0` commit, for channel `ch` (0x02 = ring, 0x01 = ext accessory).
local function write_x3_channel(dev, ch, colors)
  local grb = grb_string(colors)
  for pkt_num = 0, 1 do
    local off = pkt_num * 60
    local b = halod.buffer(64)
    b:set_u8(0, 0x22)
    b:set_u8(1, 0x10 | pkt_num)
    b:set_u8(2, ch)
    b:set_u8(3, 0x00)
    if off < #grb then
      b:set_bytes(4, grb:sub(off + 1, math.min(#grb, off + 60)))
    end
    dev.transport:write(b)
  end
  dev.transport:write(string.char(0x22, 0xA0, ch, 0x00,
    0x01, 0x00, 0x00, 0x28, 0x00, 0x00, 0x80, 0x00, 0x32, 0x00, 0x00, 0x01))
end

local function write_logo(dev, color)
  local b = halod.buffer(64)
  b:set_u8(0, 0x2A)
  b:set_u8(1, 0x04)
  b:set_u8(2, 0x04)
  b:set_u8(3, 0x04)
  b:set_u8(4, 0x00)
  b:set_u8(5, 0x32)
  b:set_u8(6, 0x00)
  b:set_u8(7, color.g)
  b:set_u8(8, color.r)
  b:set_u8(9, color.b)
  b:set_u8(56, 0x01)
  b:set_u8(57, 0x00)
  b:set_u8(58, 0x01)
  b:set_u8(59, 0x03)
  dev.transport:write(b)
end

local RING_LEDS = 8
local accessories = {
  { id=19, name="F120 RGB", led_count=8, topology="ring" },
  { id=20, name="F140 RGB", led_count=8, topology="ring" },
  { id=23, name="F140 RGB Core", led_count=8, topology="ring" },
  { id=24, name="F140 RGB Core", led_count=8, topology="ring" },
  { id=27, name="F240 RGB Core", led_count=16, topology="rings", rings=2 },
  { id=28, name="F240 RGB Core", led_count=16, topology="rings", rings=2 },
  { id=29, name="F360 RGB Core", led_count=24, topology="rings", rings=3 },
  { id=30, name="F360 RGB Core", led_count=24, topology="rings", rings=3 },
  { id=31, name="F420 RGB Core", led_count=24, topology="rings", rings=3 },
}

-- 8-LED ring starting at ~1:30 (top-right, offset by π/4 like native), plus
-- the single logo LED at center.
local function ring_zone()
  local l = {}
  for i = 0, RING_LEDS - 1 do
    local angle = (2 * math.pi * i / RING_LEDS) - (math.pi / 2) + (math.pi / 4)
    l[#l + 1] = { id = i, x = 0.5 + 0.42 * math.cos(angle), y = 0.5 + 0.42 * math.sin(angle) }
  end
  return l
end

return {
  initialize = function(dev)
    dev.transport:write(string.char(0x70, 0x02, 0x01, 0xB8, 0x01)) -- INIT_SET
    dev.transport:write(string.char(0x70, 0x01))                   -- firmware push
    dev.transport:write(string.char(0x10, 0x01))                   -- enable status stream
    log("NZXT Kraken X initialized")
    return {
      ok = true,
      channels = {
        { id="ring", name="Ring", topology="ring", led_count=8 },
        { id="logo", name="Logo", topology="linear", led_count=1 },
        -- This accessory header carries lighting only.
        { id="0", name="Aer/F Fan", chainable=true, max_leds=40 },
      },
      cooling = {channels={{id="pump",name="Pump",min_duty=20,max_duty=100,can_stop=false}}},
      accessories = accessories,
    }
  end,

  apply = function(dev, state)
    if state.mode == "static" then
      local fill = {}
      for i = 1, RING_LEDS do fill[i] = state.color end
      write_x3_channel(dev, 0x02, fill)
      write_logo(dev, state.color)
    elseif state.mode == "per_led" then
      local channels = state.channels or {}
      local ring_map = channels.ring or {}
      local fill = {}
      for i = 0, RING_LEDS - 1 do
        fill[i + 1] = ring_map[tostring(i)] or { r = 0, g = 0, b = 0 }
      end
      write_x3_channel(dev, 0x02, fill)
      local logo_map = channels.logo or {}
      write_logo(dev, logo_map["0"] or { r = 0, g = 0, b = 0 })
    end
  end,

  -- A single byte-frame callback serves both direct channels and divisions.
  write_frame = function(dev, channel, bytes)
  local colors = {}
  for i = 1, #bytes, 3 do colors[#colors + 1] = { r = bytes[i] or 0, g = bytes[i + 1] or 0, b = bytes[i + 2] or 0 } end
    if channel == "logo" then
      write_logo(dev, colors[1] or { r = 0, g = 0, b = 0 })
    elseif channel == "ring" then
      write_x3_channel(dev, 0x02, colors)
    else
      write_x3_channel(dev, 0x01, colors)
    end
  end,

  get_cooling_status = function(dev,id)
    if id~="pump" then error("unknown cooling channel: "..tostring(id)) end
    local s=dev.status or {}
    return {id="pump",name="Pump",controllable=true,min_duty=20,max_duty=100,can_stop=false,duty=s.pump_duty or 0,rpm=s.pump_rpm}
  end,
  set_cooling_duty = function(dev,id,duty)
    if id~="pump" then error("unknown cooling channel: "..tostring(id)) end
    local b=halod.buffer(44)
    b:set_bytes(0,string.char(0x72,1,0,0))
    for i=0,38 do b:set_u8(4+i,math.floor(math.max(20,math.min(100,duty)))) end
    b:set_u8(43,100)
    dev.transport:write(b)
  end,
  -- Status stream (0x75): liquid temperature and pump speed/duty.
  read_status = function(dev)
    local status = dev.status
    for _ = 1, 64 do
      local ok, bytes = pcall(function() return dev.transport:read_nonblocking(REPORT) end)
      if not ok or #bytes == 0 then break end
      local r = halod.buffer(bytes)
      if #r >= 26 and r:get_u8(0) == 0x75
          and not (r:get_u8(15) == 0xFF and r:get_u8(16) == 0xFF) then
        local frac = r:get_u8(16)
        if frac > 9 then frac = 9 end
        dev.last_status_ms = halod.monotonic_ms()
        status = { liquid_temp = r:get_u8(15) + frac / 10.0, pump_rpm=r:get_u16_le(17),pump_duty=r:get_u8(19) }
        status.cooling={{id="pump",name="Pump",controllable=true,min_duty=20,max_duty=100,can_stop=false,duty=status.pump_duty,rpm=status.pump_rpm}}
      end
    end
    return status
  end,

  get_sensors = function(dev)
    local s = dev.status or {}
    if s.liquid_temp == nil or halod.monotonic_ms() - (dev.last_status_ms or 0) > 5000 then return {} end
    return {
      { id = "liquid", name = "Liquid Temperature", value = s.liquid_temp or 0,
        unit = "celsius", sensor_type = "temperature" },
    }
  end,

  -- Accessory detection (0x20 0x03 -> 0x21 0x03); accessory id at byte 15.
  detect_accessories = function(dev)
    dev.transport:write(string.char(0x20, 0x03))
    for _ = 1, 8 do
      local reply = halod.buffer(dev.transport:read(REPORT))
      if #reply >= 16 and reply:get_u8(0) == 0x21 and reply:get_u8(1) == 0x03 then
        local acc = reply:get_u8(15)
        if acc ~= 0 then
          return { { channel = 0, accessory = acc } }
        end
        return {}
      end
    end
    return {}
  end,
}
