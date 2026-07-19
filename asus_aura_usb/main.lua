-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: Martin Hartl (inlart) and OpenRGB contributors <https://gitlab.com/CalcProgrammer1/OpenRGB>
--
-- ASUS Aura USB motherboard RGB. Ported from OpenRGB's AsusAuraUSBController
-- (and the legacy HaloDaemon Rust driver): raw 65-byte HID reports beginning
-- with 0xEC, per-LED "direct" streaming to each channel, and the on-board
-- native effects (off / breathing / spectrum cycle / rainbow wave).
--
-- Channels and per-channel LED counts are read from the device's config table
-- at `initialize` time and exposed as RGB channels: the fixed on-board zone
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
local COLOR_PARAM = {
  id = "color",
  label = "Color",
  kind = { kind = "color" },
  default = { r = 255, g = 255, b = 255 },
}
local NATIVE_EFFECTS = {
  { id = "off", name = "Off", params = {} },
  { id = "breathing", name = "Breathing", params = { COLOR_PARAM } },
  { id = "spectrum_cycle", name = "Spectrum Cycle", params = {} },
  { id = "rainbow_wave", name = "Rainbow Wave", params = {} },
}

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
local st = {
  -- Fixed on-board channels (the mainboard LEDs and any board-specific named zone
  -- like the ROG logo): { id, name, led_count, direct_channel }.
  channels = {},
  -- Effect (hardware) channels for the native effects — every ARGB header,
  -- 1..argb_count. The on-board mainboard channel (0) is not an effect channel.
  effect_channels = {},
}

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

local function direct_channel_for(list, id)
  for _, e in ipairs(list) do
    if e.id == id then return e.direct_channel end
  end
  return nil
end

-- ── Plugin ───────────────────────────────────────────────────────────────────

return {
  initialize = function(dev)
    stop_gen2(dev)

    local fw = get_firmware(dev)
    if fw then log("[ASUS Aura USB] firmware " .. fw) end

    local cfg = command_read(dev, CMD_CONFIG, 0x30, 8)
    if not cfg then
      log("[ASUS Aura USB] could not read config table")
      return { ok = false }
    end

    local argb_count = math.min(cfg:get_u8(4 + CT_ARGB_CH), 9)
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

    -- Split the channels: the on-board mainboard LEDs and any board-specific
    -- named header (e.g. the ROG logo) are fixed RGB channels; every other ARGB
    -- header is a chainable channel the user attaches a strip to. Every ARGB
    -- header (0..argb_count-1) is also a native-effect channel (effect_channel = i+1).
    st.channels = {}
    st.effect_channels = {}
    local zones_out = {}
    local chain_out = {}

    if mb_leds > 0 then
      st.channels[#st.channels + 1] =
        { id = "motherboard", name = "Motherboard", led_count = mb_leds, direct_channel = MB_DIRECT_CHANNEL }
      zones_out[#zones_out + 1] =
        { id = "motherboard", name = "Motherboard", topology = "linear", led_count = mb_leds }
    end

    local named = NAMED_ZONES[pid] or {}
    for i = 0, argb_count - 1 do
      st.effect_channels[#st.effect_channels + 1] = i + 1
      local nm = named[i]
      if nm then
        -- A board-specific fixed header (e.g. logo): a plain RGB zone.
        st.channels[#st.channels + 1] =
          { id = nm.id, name = nm.name, led_count = led_counts[i + 1], direct_channel = i }
        zones_out[#zones_out + 1] =
          { id = nm.id, name = nm.name, topology = "linear", led_count = led_counts[i + 1] }
      else
        -- A generic ARGB header: a chain channel. `max_leds` is the header's
        -- capacity; the user composes strips up to it.
        local id = "argb_" .. i
        st.channels[#st.channels + 1] = { id = id, name = "ARGB Header " .. (i + 1), direct_channel = i }
        chain_out[#chain_out + 1] =
          { id = id, name = "ARGB Header " .. (i + 1), max_leds = led_counts[i + 1] }
      end
    end

    return {
      ok = true,
      model = MODELS[pid],
      channels = zones_out,
      division = chain_out,
      native_effects = NATIVE_EFFECTS,
    }
  end,

  -- User-driven mode change. Static/per-led touch only the fixed on-board channels;
  -- the chainable ARGB headers are driven by the host's chain composition via
  -- write_frame. Native effects run on the hardware for every ARGB header.
  apply = function(dev, state)
    local mode = state.mode
    if mode == "static" then
      for _, z in ipairs(st.channels) do
        -- Divisible ARGB headers have no direct LED count: their final encoded
        -- frames are delivered exclusively through write_frame().
        if z.led_count then
          local colors = {}
          for i = 1, z.led_count do colors[i] = state.color end
          send_direct(dev, z.direct_channel, colors)
        end
      end
    elseif mode == "per_led" then
      local zmap = state.channels or {}
      for _, z in ipairs(st.channels) do
        local led_map = zmap[z.id]
        if led_map and z.led_count then
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
      for _, ec in ipairs(st.effect_channels) do
        send_effect(dev, ec, m, color)
      end
    end
    -- "engine" / "direct_effect": handled per-frame via write_frame / write_frame.
  end,

  -- Direct and divided channels share the encoded-byte callback.
  write_frame = function(dev, channel_id, bytes)
  local colors = {}
  for i = 1, #bytes, 3 do colors[#colors + 1] = { r = bytes[i] or 0, g = bytes[i + 1] or 0, b = bytes[i + 2] or 0 } end
    local dc = direct_channel_for(st.channels, channel_id)
    if dc then send_direct(dev, dc, colors) end
  end,
}
