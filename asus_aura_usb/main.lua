-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: Martin Hartl (inlart) and OpenRGB contributors <https://gitlab.com/CalcProgrammer1/OpenRGB>
--
-- ASUS Aura USB motherboard RGB. Ported from OpenRGB's AsusAuraUSBController
-- (and the legacy HaloDaemon Rust driver): raw 65-byte HID reports beginning
-- with 0xEC, per-LED "direct" streaming to each channel, and the on-board
-- native effects (off / breathing / spectrum cycle / rainbow wave).
--
-- Channels and per-channel LED counts are read from the device's config table
-- at `initialize` time and exposed as RGB zones: the fixed on-board zone
-- (direct channel 4) plus one zone per ARGB header (direct channels 0..N-1).

local AURA_HDR       = 0xEC
local CMD_FIRMWARE   = 0x82
local CMD_CONFIG     = 0xB0
local CMD_DIRECT     = 0x40
local CMD_SETMODE    = 0x35
local CMD_ADDR_EFFECT = 0x3B
local MODE_DIRECT    = 0xFF
local REPORT_SIZE    = 65
local LEDS_PER_PACKET = 20 -- 20 × 3 = 60 bytes fits one 65-byte packet
local MB_DIRECT_CHANNEL = 0x04
local DEFAULT_ARGB_LEDS = 30 -- fallback when the config block reports 0
local MAX_ARGB_LEDS  = 120 -- hardware cap per channel

-- Config-table byte offsets (relative to the 60-byte table, which the reply
-- carries at bytes 4..63 — so the wire offset is `4 + off`).
local CT_ARGB_CH     = 0x02 -- number of 5V ARGB channels
local CT_MB_LEDS     = 0x1B -- total on-board LED count (incl. 12V header positions)
local CT_CH_BLOCK_OFF = 4   -- start of the per-channel 6-byte blocks
local CT_CH_BLOCK_SZ = 6
local CT_CH_LEDS_OFF = 2    -- LED-count offset within each block

-- Native effect id → mode byte.
local MODES = { off = 0x00, breathing = 0x02, spectrum_cycle = 0x04, rainbow_wave = 0x05 }

-- Per-board display name (overrides identity.model once we know the pid).
local MODELS = {
  [0x1AA6] = "ASUS X870E",
  [0x18A3] = "ASUS ROG Strix Z390-F Gaming",
}

-- Per-board friendly names for specific channels (a fixed on-board zone that is
-- not a generic ARGB header, e.g. the ROG logo). Keyed by pid, then by direct
-- channel index.
local NAMED_ZONES = {
  [0x1AA6] = { [3] = { id = "logo", name = "ROG Logo" } },
}

-- Per-device runtime state, populated by initialize(). Each device has its own
-- Lua VM, so a single module-level table is safe.
local st = { zones = {} }
-- st.zones: array of { id, name, led_count, direct_channel, effect_channel|nil }

-- ── Wire helpers ─────────────────────────────────────────────────────────────

local function make_packet(cmd)
  local b = halod.buffer(REPORT_SIZE)
  b:set_u8(0, AURA_HDR)
  b:set_u8(1, cmd)
  return b
end

-- Disable legacy gen-2 continuous-cycle mode so we can take over direct control.
-- Best-effort: some boards NAK it.
local function stop_gen2(dev)
  local b = halod.buffer(REPORT_SIZE)
  b:set_u8(0, AURA_HDR)
  b:set_u8(1, 0x52)
  b:set_u8(2, 0x53)
  b:set_u8(3, 0x00)
  b:set_u8(4, 0x01)
  pcall(function() dev.transport:write(b) end)
end

-- Send `cmd`, then read up to `tries` input reports looking for one whose header
-- is 0xEC followed by `want`. Non-matching reports (e.g. async status) are
-- skipped; a read error (timeout) ends the search. Returns a halod.buffer or nil.
local function command_read(dev, cmd, want, tries)
  dev.transport:write(make_packet(cmd))
  for _ = 1, tries or 8 do
    local ok, reply = pcall(function() return dev.transport:read(REPORT_SIZE) end)
    if not (ok and reply and #reply >= 2) then
      return nil
    end
    local r = halod.buffer(reply)
    if r:get_u8(0) == AURA_HDR and r:get_u8(1) == want then
      return r
    end
  end
  return nil
end

local function get_firmware(dev)
  local r = command_read(dev, CMD_FIRMWARE, 0x02, 8)
  if not r then return nil end
  local chars = {}
  local last = math.min(17, #r - 1)
  for i = 2, last do
    local c = r:get_u8(i)
    if c == 0 then break end
    chars[#chars + 1] = string.char(c)
  end
  local s = table.concat(chars)
  if #s == 0 then return nil end
  return s
end

-- Set one effect channel to direct (software) control. Channel 0 = on-board,
-- channels 1..N = ARGB headers.
local function set_channel_direct(dev, channel)
  local b = make_packet(CMD_SETMODE)
  b:set_u8(2, channel)
  b:set_u8(5, MODE_DIRECT)
  dev.transport:write(b)
end

-- Stream per-LED RGB to one direct channel, split into 20-LED sub-packets. The
-- apply bit (0x80 on the channel byte) is set only on the final sub-packet.
local function send_direct(dev, direct_channel, colors)
  local n = #colors
  if n == 0 then return end
  local offset = 0
  while offset < n do
    local count = math.min(LEDS_PER_PACKET, n - offset)
    local is_last = (offset + count) >= n
    if offset > 255 then error("Aura: LED offset exceeds 255; too many LEDs on one channel") end
    local b = halod.buffer(REPORT_SIZE)
    b:set_u8(0, AURA_HDR)
    b:set_u8(1, CMD_DIRECT)
    b:set_u8(2, direct_channel | (is_last and 0x80 or 0x00))
    b:set_u8(3, offset)
    b:set_u8(4, count)
    for i = 0, count - 1 do
      local c = colors[offset + i + 1] or { r = 0, g = 0, b = 0 }
      b:set_u8(5 + i * 3, c.r or 0)
      b:set_u8(5 + i * 3 + 1, c.g or 0)
      b:set_u8(5 + i * 3 + 2, c.b or 0)
    end
    dev.transport:write(b)
    offset = offset + count
  end
end

-- Send a native-effect command (0x3B packet) to one ARGB effect channel.
local function send_effect(dev, effect_channel, mode, color)
  local b = make_packet(CMD_ADDR_EFFECT)
  b:set_u8(2, effect_channel)
  b:set_u8(4, mode)
  b:set_u8(5, color.r or 255)
  b:set_u8(6, color.g or 255)
  b:set_u8(7, color.b or 255)
  dev.transport:write(b)
end

local function zone_by_id(id)
  for _, z in ipairs(st.zones) do
    if z.id == id then return z end
  end
  return nil
end

-- ── Plugin ───────────────────────────────────────────────────────────────────

return {
  rgb = {
    zones = {}, -- reported dynamically by initialize()
    native_effects = {
      { id = "off", name = "Off", params = {} },
      { id = "breathing", name = "Breathing", params = {
        { id = "color", label = "Color", kind = { kind = "color" }, default = { r = 255, g = 255, b = 255 } },
      } },
      { id = "spectrum_cycle", name = "Spectrum Cycle", params = {} },
      { id = "rainbow_wave", name = "Rainbow Wave", params = {} },
    },
  },

  initialize = function(dev)
    stop_gen2(dev)

    local fw = get_firmware(dev)
    if fw then log("[ASUS Aura USB] firmware " .. fw) end

    local cfg = command_read(dev, CMD_CONFIG, 0x30, 8)
    if not cfg then
      log("[ASUS Aura USB] could not read config table")
      return { ok = false }
    end

    local argb_count = cfg:get_u8(4 + CT_ARGB_CH)
    local mb_leds = cfg:get_u8(4 + CT_MB_LEDS)

    local led_counts = {}
    for i = 0, argb_count - 1 do
      local block_off = CT_CH_BLOCK_OFF + i * CT_CH_BLOCK_SZ + CT_CH_LEDS_OFF
      local leds = (block_off < 60) and cfg:get_u8(4 + block_off) or 0
      if leds == 0 then
        leds = DEFAULT_ARGB_LEDS
      elseif leds > MAX_ARGB_LEDS then
        leds = MAX_ARGB_LEDS
      end
      led_counts[i + 1] = leds
    end

    if argb_count == 0 and mb_leds == 0 then
      log("[ASUS Aura USB] no controllable channels found")
      return { ok = false }
    end

    -- Take over the on-board effect channel (0) and every ARGB effect channel.
    for ch = 0, argb_count do
      pcall(function() set_channel_direct(dev, ch) end)
    end

    local pid = dev.match and dev.match.pid

    -- Build the zone list: fixed on-board zone first (when present), then one
    -- zone per ARGB header.
    st.zones = {}
    local zones_out = {}
    if mb_leds > 0 then
      st.zones[#st.zones + 1] =
        { id = "motherboard", name = "Motherboard", led_count = mb_leds, direct_channel = MB_DIRECT_CHANNEL }
      zones_out[#zones_out + 1] =
        { id = "motherboard", name = "Motherboard", topology = "linear", led_count = mb_leds }
    end

    local named = NAMED_ZONES[pid] or {}
    for i = 0, argb_count - 1 do
      local nm = named[i]
      local id = nm and nm.id or ("argb_" .. i)
      local name = nm and nm.name or ("ARGB Header " .. (i + 1))
      st.zones[#st.zones + 1] =
        { id = id, name = name, led_count = led_counts[i + 1], direct_channel = i, effect_channel = i + 1 }
      zones_out[#zones_out + 1] =
        { id = id, name = name, topology = "linear", led_count = led_counts[i + 1] }
    end

    return { ok = true, model = MODELS[pid], zones = zones_out }
  end,

  -- User-driven mode change.
  apply = function(dev, state)
    local mode = state.mode
    if mode == "static" then
      for _, z in ipairs(st.zones) do
        local colors = {}
        for i = 1, z.led_count do colors[i] = state.color end
        send_direct(dev, z.direct_channel, colors)
      end
    elseif mode == "per_led" then
      local zmap = state.zones or {}
      for _, z in ipairs(st.zones) do
        local led_map = zmap[z.id]
        if led_map then
          local colors = {}
          for i = 0, z.led_count - 1 do
            colors[i + 1] = led_map[tostring(i)] or { r = 0, g = 0, b = 0 }
          end
          send_direct(dev, z.direct_channel, colors)
        end
      end
    elseif mode == "native_effect" then
      local m = MODES[state.id]
      if not m then error("Aura: unknown effect " .. tostring(state.id)) end
      local color = (state.params and state.params.color) or { r = 255, g = 255, b = 255 }
      for _, z in ipairs(st.zones) do
        if z.effect_channel then send_effect(dev, z.effect_channel, m, color) end
      end
    end
    -- "engine" / "direct_effect": handled per-frame via write_frame.
  end,

  -- Canvas-engine per-frame path.
  write_frame = function(dev, zone_id, colors)
    local z = zone_by_id(zone_id)
    if z then send_direct(dev, z.direct_channel, colors) end
  end,
}
