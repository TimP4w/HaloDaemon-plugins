-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: tomasf <https://github.com/tomasf/evnia>
--
-- Philips Evnia 49M2C8900. The monitor exposes two independent USB devices: a
-- DDC/CI control interface (via the USB hub chip, 2109:8884) for picture/OSD
-- settings, and an ENE KB7730 RGB controller (0cf2:b201) for the rear
-- Ambiglow LEDs. This plugin matches the DDC chip and opens the Ambiglow
-- chip as a bundled companion USB device, presenting both as a
-- single device.
--
-- The 44-LED Ambiglow control path (capture-block enable, 0xE100 frame buffer,
-- baseline-region restore) is adapted from tomasf/evnia (MIT). DDC/CI details:
-- philips_evnia/docs/ddc-ci.md; Ambiglow: philips_evnia/docs/ambiglow.md.

-- ── DDC/CI USB control-transfer parameters ───────────────────────────────────
local DDC_BMREQ_OUT = 0x40 -- vendor | host-to-device | device recipient
local DDC_BMREQ_IN  = 0xC0 -- vendor | device-to-host  | device recipient
local DDC_BREQ_WRITE = 0xB2
local DDC_BREQ_READ  = 0xA3
local DDC_READ_W_INDEX = 0x006F
local WRITE_GAP_MS = 50   -- minimum gap between DDC writes (MCCS §4.5)
local READ_DELAY_MS = 150 -- time the monitor needs to assemble a reply
local MODE_CHECK_S = 30   -- idle cadence of the SmartImage change check in read_status
local REFRESH_DELAY_S = 2 -- quiet time after the last mode change before re-reading
local ERROR_BACKOFF_S = 60 -- no polling reads for this long after a transport error
local ERROR_RECOVER_MS = 500
local DDC_TIMEOUT_MS = 250
local MAX_FAIL_STREAK = 3 -- consecutive transport errors before the remaining reads are skipped

-- ── Ambiglow (ENE) control-transfer parameters ───────────────────────────────
local AMBI_BMREQ_OUT = 0x40
local AMBI_BREQ = 0x80
local LED_COUNT = 44
local FRAME_ADDR = 0xE100
local EFFECT_COLOR_SLOTS = { 0xE980, 0xE983, 0xE986, 0xE989 }
local CONTROL_BLOCKS = { 0xE020, 0xE030 }
local BASELINE_ADDR = 0xE020
local HOST_LINK_ADDR = 0x0023 -- 0x04: host owns the LEDs, 0x00: monitor scaler owns them
local HOST_LINK_ON, HOST_LINK_OFF = 0x04, 0x00
local FRAME_SETTLE_MS = 10 -- let a frame settle before a baseline restore
-- Full 132-byte frame writes can take longer than the short DDC probe window.
-- This matches the companion transport's declared control-transfer limit and
-- preserves the timeout behavior of the pre-usb_control API.
local AMBI_TIMEOUT_MS = 1000

-- 16-byte zone block selecting the host frame buffer as the LED source.
local CAPTURE_BLOCK = string.char(
  0x01, 0x00, 0x02, 0x04, 0x00, 0x05, 0x00, 0x00,
  0x00, 0x02, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x01)

-- 64-byte region selecting the controller's static effect; only a hand-back
-- together with the host-link register (see release).
local BASELINE_REGION = string.char(
  0x00, 0x01, 0x02, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x02, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

-- ── Small helpers ────────────────────────────────────────────────────────────
local byte = string.byte

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

local function set_of(list)
  local t = {}
  for _, v in ipairs(list) do t[v] = true end
  return t
end

-- ── DDC/CI packet encode / decode ────────────────────────────────────────────
-- Each builder takes the payload bytes and appends the XOR-fold checksum.
local function pack_with_xor(bytes)
  local x = 0
  for i = 1, #bytes do x = x ~ bytes[i] end
  bytes[#bytes + 1] = x
  return string.char(table.unpack(bytes))
end

local function build_write(vcp, value)
  return pack_with_xor({ 0x6e, 0x51, 0x84, 0x03, vcp, (value >> 8) & 0xFF, value & 0xFF })
end

local function build_extended_set(sub, value)
  return pack_with_xor({ 0x6e, 0x51, 0x86, 0x03, 0xe2, 0xa0, sub, 0x00, value })
end

local function build_get_standard(vcp)
  return pack_with_xor({ 0x6e, 0x51, 0x82, 0x01, vcp })
end

local function build_get_extended(sub)
  return pack_with_xor({ 0x6e, 0x51, 0x84, 0x01, 0xe2, 0xa0, sub })
end

local function build_get_info(a0, a1, a2, a3)
  return pack_with_xor({ 0x6e, 0x51, 0x86, 0x01, 0xfe, a0, a1, a2, a3 })
end

-- Standard MCCS get-VCP reply: 6e 88 02 00 vcp type maxH maxL curH curL xor.
-- Returns the current value, or nil on any malformed/errored reply (the caller
-- skips it, exactly as the native driver logged-and-skipped a failed read).
local function parse_get_reply(s)
  if #s < 12 or byte(s, 1) ~= 0x6e or byte(s, 3) ~= 0x02 or byte(s, 4) ~= 0x00 then
    return nil
  end
  local x = 0
  for i = 1, 10 do x = x ~ byte(s, i) end
  if byte(s, 11) ~= (0x50 ~ x) then return nil end
  return (byte(s, 9) << 8) | byte(s, 10)
end

-- Info-string reply: standard `02 fe <addr>` envelope or raw asset-EEPROM ASCII.
local function parse_info_reply(s)
  if #s < 4 or byte(s, 1) ~= 0x6e then return nil end
  local n = byte(s, 2) & 0x7f
  if #s < 2 + n + 1 then return nil end
  local x = 0
  for i = 1, 2 + n do x = x ~ byte(s, i) end
  if byte(s, 2 + n + 1) ~= (0x50 ~ x) then return nil end
  local from = 3
  if n >= 3 and byte(s, 3) == 0x02 and byte(s, 4) == 0xfe then from = 6 end
  local payload = string.sub(s, from, 2 + n)
  local nul = string.find(payload, "\0", 1, true)
  if nul then payload = string.sub(payload, 1, nul - 1) end
  return (payload:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ── VCP value tables (code, label) ───────────────────────────────────────────
-- Option indexes are persisted by the host, so entries are never reordered.
local INPUT_PORTS = {
  { code = 0x0F, label = "DisplayPort 1" },
  { code = 0x15, label = "USB-C" },
  { code = 0x11, label = "HDMI 1" },
  { code = 0x12, label = "HDMI 2" },
}

local OSD_LANGUAGES = {
  { code = 0x01, label = "Chinese (Traditional)" }, { code = 0x02, label = "English" },
  { code = 0x03, label = "French" }, { code = 0x04, label = "German" },
  { code = 0x05, label = "Italian" }, { code = 0x06, label = "Japanese" },
  { code = 0x07, label = "Korean" }, { code = 0x08, label = "Portuguese" },
  { code = 0x09, label = "Russian" }, { code = 0x0A, label = "Spanish" },
  { code = 0x0B, label = "Swedish" }, { code = 0x0C, label = "Turkish" },
  { code = 0x0D, label = "Chinese (Simplified)" }, { code = 0x0E, label = "Brazilian Portuguese" },
  { code = 0x12, label = "Czech" }, { code = 0x14, label = "Dutch" },
  { code = 0x16, label = "Finnish" }, { code = 0x17, label = "Greek" },
  { code = 0x1A, label = "Hungarian" }, { code = 0x1E, label = "Polish" },
  { code = 0x24, label = "Ukrainian" },
}

-- SDR and HDR presets share VCP 0xDC. The monitor only accepts presets from the
-- family matching the current signal, so each family is its own choice.
local SMART_IMAGE_MODES = {
  { code = 0x00, label = "Standard" }, { code = 0x01, label = "FPS" },
  { code = 0x03, label = "Movie" }, { code = 0x04, label = "Game 1" },
  { code = 0x05, label = "Game 2" }, { code = 0x06, label = "Racing" },
  { code = 0x07, label = "RTS" }, { code = 0x08, label = "Economy" },
  { code = 0x0B, label = "LowBlue Mode" }, { code = 0x0E, label = "EasyRead" },
  { code = 0x11, label = "Console Mode" },
}

local SMART_IMAGE_HDR_MODES = {
  { code = 0x21, label = "HDR Game" }, { code = 0x22, label = "HDR Movie" },
  { code = 0x23, label = "HDR Photo" }, { code = 0x30, label = "HDR True Black" },
  { code = 0x24, label = "HDR Personal" }, { code = 0x20, label = "HDR Off" },
}

local SI_LOWBLUE, SI_EASYREAD = 0x0B, 0x0E
local SI_HDR_OFF, SI_HDR_TRUE_BLACK = 0x20, 0x30
local HDR_CODES = set_of({ 0x20, 0x21, 0x22, 0x23, 0x24, 0x30 })

local function is_hdr_code(code) return HDR_CODES[code] == true end

local COLOR_TEMPERATURES = {
  { code = 0x02, label = "Native" }, { code = 0x04, label = "5000K" },
  { code = 0x05, label = "6500K" }, { code = 0x06, label = "7500K" },
  { code = 0x07, label = "8200K" }, { code = 0x08, label = "9300K" },
  { code = 0x0A, label = "11500K" }, { code = 0x0D, label = "Preset" },
}
local CT_USER_RGB = 0x0D

local GAMMA_VALUES = {
  { code = 0x50, label = "1.0" }, { code = 0x64, label = "2.0" },
  { code = 0x78, label = "2.2" }, { code = 0x8C, label = "2.4" },
  { code = 0xA0, label = "2.6" },
}

local PIXEL_ORBITING = {
  { code = 0x00, label = "Off" }, { code = 0x02, label = "Slow" },
  { code = 0x03, label = "Normal" }, { code = 0x04, label = "Fast" },
}

local SCREEN_SAVER = {
  { code = 0x00, label = "Off" }, { code = 0x02, label = "Slow" }, { code = 0x03, label = "Fast" },
}

local POWER_MODES = { { code = 0x01, label = "On" }, { code = 0x04, label = "Standby" } }

-- Selected 0-based index -> raw VCP code.
local function code_at(tbl, selected)
  return tbl[math.min(selected, #tbl - 1) + 1].code
end

-- Raw VCP value -> selected 0-based index (low byte carries the code), or nil
-- for codes outside the table (e.g. color temperature 0x0B while sRGB is on).
local function index_of_code(tbl, raw)
  local code = raw & 0xFF
  for i, e in ipairs(tbl) do
    if e.code == code then return i - 1 end
  end
  return nil
end

local function indexes_where(tbl, pred)
  local out = {}
  for i, e in ipairs(tbl) do
    if pred(e.code) then out[#out + 1] = i - 1 end
  end
  return out
end

-- ── Ambiglow LED geometry (front-facing, x left→right, y top→bottom) ──────────
local function ambiglow_positions()
  local leds = {}
  local function push(id, x, y) leds[#leds + 1] = { id = id, x = x, y = y } end
  for i = 0, 2 do push(i, 0.98, 1.0 - i / 2.0) end             -- right edge, bottom→top
  for j = 0, 8 do push(3 + j, 0.90 - 0.38 * j / 8.0, 0.0) end  -- top, right of center
  for j = 0, 8 do push(12 + j, 0.48 - 0.38 * j / 8.0, 0.0) end -- top, left of center
  for i = 0, 2 do push(21 + i, 0.02, i / 2.0) end              -- left edge, top→bottom
  for k = 0, 10 do push(24 + k, 0.5, 0.05 + 0.40 * k / 10.0) end -- upper center column
  for k = 0, 8 do push(35 + k, 0.5, 0.55 + 0.40 * k / 8.0) end   -- lower center column
  return leds
end

-- ── Ambiglow native effects ──────────────────────────────────────────────────
-- Scaler effects are selected over DDC (E2A0 19, brightness E2A0 1C). Colour
-- effects run on the ENE controller itself and take their colour from the
-- frame buffer; their "rainbow" variant is the next mode number.
local AMBI_MODE_SUB, AMBI_BRIGHTNESS_SUB = 0x19, 0x1C

local SCALER_LEVELS = { { label = "Bright", code = 0 }, { label = "Brighter", code = 1 },
  { label = "Brightest", code = 2 } }
local ENE_LEVELS = { { label = "Bright", code = 0x04 }, { label = "Brighter", code = 0x02 },
  { label = "Brightest", code = 0x00 } }
local ENE_SPEEDS = { { label = "Low", code = 0x02 }, { label = "Normal", code = 0x00 },
  { label = "High", code = 0xFE } }

local function enum_param(id, label, options, default)
  local labels = {}
  for i, e in ipairs(options) do labels[i] = e.label end
  return { id = id, label = label, kind = { kind = "enum", options = labels }, default = default }
end

local P_COLOR = { id = "color", label = "Color", kind = { kind = "color" }, default = { r = 255, g = 255, b = 255 } }
local P_RAINBOW = { id = "rainbow", label = "Rainbow", kind = { kind = "boolean" }, default = false }
local P_SCALER_BRIGHTNESS = enum_param("brightness", "Brightness", SCALER_LEVELS, "Brightest")
local P_BRIGHTNESS = enum_param("brightness", "Brightness", ENE_LEVELS, "Brightest")
local P_SPEED = enum_param("speed", "Speed", ENE_SPEEDS, "Normal")

local NATIVE_EFFECTS = {
  { id = "off", name = "Off", scaler = 0, params = {} },
  { id = "follow_video", name = "Follow Video", scaler = 1, params = { P_SCALER_BRIGHTNESS } },
  { id = "follow_audio", name = "Follow Audio", scaler = 2, params = {} },
  { id = "static", name = "Static", ene = 1, params = { P_COLOR, P_RAINBOW, P_BRIGHTNESS } },
  { id = "color_shift", name = "Color Shift", ene = 3, params = { P_COLOR, P_RAINBOW, P_BRIGHTNESS, P_SPEED } },
  { id = "color_wave", name = "Color Wave", ene = 5, params = { P_COLOR, P_RAINBOW, P_BRIGHTNESS, P_SPEED } },
  { id = "breathing", name = "Breathing", ene = 7, params = { P_COLOR, P_RAINBOW, P_BRIGHTNESS, P_SPEED } },
  { id = "starry_night", name = "Starry Night", ene = 12, params = { P_COLOR, P_RAINBOW, P_BRIGHTNESS, P_SPEED } },
}

local function find_effect(id)
  for _, e in ipairs(NATIVE_EFFECTS) do
    if e.id == id then return e end
  end
  return nil
end

local function option_code(list, label, fallback)
  for _, e in ipairs(list) do
    if e.label == label then return e.code end
  end
  return fallback
end

-- Zone block: source 0x00 (controller effect), mode, speed, direction, …,
-- brightness at +9. Written uncommitted; the +F commit byte follows the frame
-- so the controller switches effect and colour in one step.
local COMMIT_OFFSET = 0x0F

local function effect_block(mode, speed, brightness)
  return string.char(0x00, mode, speed, 0x00, 0x00, 0x05, 0x00, 0x00,
    0x00, brightness, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00)
end

-- ── Transport helpers ────────────────────────────────────────────────────────
local function ddc_write(dev, payload)
  halod.sleep_ms(WRITE_GAP_MS)
  dev.transport:usb_control(DDC_BMREQ_OUT, DDC_BREQ_WRITE, 0x00, 0x00, payload, 0, DDC_TIMEOUT_MS)
end

local function ddc_read(dev)
  halod.sleep_ms(READ_DELAY_MS)
  return dev.transport:usb_control(DDC_BMREQ_IN, DDC_BREQ_READ, 0x00, DDC_READ_W_INDEX, "", 32, DDC_TIMEOUT_MS)
end

-- Reading the startup snapshot is best-effort. Some VCPs are unavailable in
-- particular picture modes, and this USB bridge can time out individual
-- control transfers while the monitor is waking. Keep the device usable with
-- defaults/partial state instead of failing the whole initialize callback.
-- Writes initiated by the user deliberately do not use this wrapper, so their
-- transport errors still propagate to the daemon.
local function ddc_query(dev, payload, parse)
  if (dev.polling and dev.ddc_failed) or (dev.fail_streak or 0) >= MAX_FAIL_STREAK then return nil end
  local ok, value = pcall(function()
    ddc_write(dev, payload)
    return parse(ddc_read(dev))
  end)
  if not ok then
    log("Philips Evnia 49: DDC probe failed: " .. tostring(value))
    dev.ddc_failed = true
    dev.fail_streak = (dev.fail_streak or 0) + 1
    halod.sleep_ms(ERROR_RECOVER_MS)
    return nil
  end
  dev.fail_streak = 0
  return value
end

local function ddc_get_standard(dev, vcp)
  return ddc_query(dev, build_get_standard(vcp), parse_get_reply)
end

local function ddc_get_extended(dev, sub)
  return ddc_query(dev, build_get_extended(sub), parse_get_reply)
end

local function ddc_get_info(dev, a0, a1, a2, a3)
  return ddc_query(dev, build_get_info(a0, a1, a2, a3), parse_info_reply)
end

local function ambiglow_write(dev, address, data)
  dev.transport:usb_control(
    AMBI_BMREQ_OUT, AMBI_BREQ, 0x00, address, data, 0, AMBI_TIMEOUT_MS, "ambiglow"
  )
end

-- Arm direct frame control once (idempotent until a release).
local function take_host_link(dev)
  if dev.host_link then return end
  ambiglow_write(dev, HOST_LINK_ADDR, string.char(HOST_LINK_ON))
  dev.host_link = true
end

local function ensure_capture(dev)
  if dev.captured then return end
  take_host_link(dev)
  for _, addr in ipairs(CONTROL_BLOCKS) do
    ambiglow_write(dev, addr, CAPTURE_BLOCK)
  end
  dev.captured = true
end

-- Pack a colour list into the fixed LED_COUNT*3 RGB frame buffer (short list
-- leaves the tail black; extra colours are dropped).
local function build_frame(colors)
  local b = halod.buffer(LED_COUNT * 3)
  for i = 0, LED_COUNT - 1 do
    local c = colors[i + 1]
    if c then
      b:set_u8(i * 3, c.r)
      b:set_u8(i * 3 + 1, c.g)
      b:set_u8(i * 3 + 2, c.b)
    end
  end
  return b
end

local function write_colors(dev, colors)
  ensure_capture(dev)
  ambiglow_write(dev, FRAME_ADDR, build_frame(colors))
  dev.has_frame = true
end

-- Hand the LEDs back to the monitor scaler (wait out any in-flight frame
-- first); the scaler then resumes its DDC E2A0 19 effect.
local function release(dev)
  if dev.host_link == false then return end
  if dev.has_frame then halod.sleep_ms(FRAME_SETTLE_MS) end
  ambiglow_write(dev, BASELINE_ADDR, BASELINE_REGION)
  ambiglow_write(dev, HOST_LINK_ADDR, string.char(HOST_LINK_OFF))
  dev.host_link = false
  dev.captured = false
  dev.has_frame = false
end

local function apply_scaler_effect(dev, effect, params)
  release(dev)
  ddc_write(dev, build_extended_set(AMBI_MODE_SUB, effect.scaler))
  dev.state.ambi_mode = effect.scaler
  if effect.scaler == 1 then
    local level = option_code(SCALER_LEVELS, params.brightness, 2)
    ddc_write(dev, build_extended_set(AMBI_BRIGHTNESS_SUB, level))
  end
end

-- Keeps the host link on; the controller animates the colour in its effect
-- colour slots (one RGB triple per zone block), not the frame buffer.
local function apply_ene_effect(dev, effect, params)
  local color = params.color or P_COLOR.default
  local mode = effect.ene + (params.rainbow == true and 1 or 0)
  if dev.has_frame then halod.sleep_ms(FRAME_SETTLE_MS) end
  take_host_link(dev)
  local block = effect_block(mode, option_code(ENE_SPEEDS, params.speed, 0x00),
    option_code(ENE_LEVELS, params.brightness, 0x00))
  for _, addr in ipairs(CONTROL_BLOCKS) do
    ambiglow_write(dev, addr, block)
  end
  local rgb = string.char(color.r, color.g, color.b)
  for _, addr in ipairs(EFFECT_COLOR_SLOTS) do
    ambiglow_write(dev, addr, rgb)
  end
  for _, addr in ipairs(CONTROL_BLOCKS) do
    ambiglow_write(dev, addr + COMMIT_OFFSET, string.char(0x01))
  end
  dev.captured = false
  dev.has_frame = false
end

local function resume_monitor_effect(dev)
  release(dev)
  local mode = dev.state.ambi_mode
  if mode and mode ~= 0 then ddc_write(dev, build_extended_set(AMBI_MODE_SUB, mode)) end
end

-- ── Mode-scoped picture state ────────────────────────────────────────────────
local function sdr(s) return s.dc == nil or not is_hdr_code(s.dc) end
local function hdr(s) return s.dc == nil or is_hdr_code(s.dc) end
local function picture_adjustable(s) return s.dc ~= SI_HDR_OFF and s.dc ~= SI_HDR_TRUE_BLACK end
local function color_managed(s) return sdr(s) and s.dc ~= SI_LOWBLUE and s.dc ~= SI_EASYREAD end
local function single_input(s) return not s.pbp end

-- Which controls the monitor accepts in its current state. A gated write is
-- skipped; the control is hidden in that state, so nothing needs re-reading.
local GATES = {
  brightness = picture_adjustable,
  contrast = function(s) return picture_adjustable(s) and s.dc ~= SI_EASYREAD end,
  sharpness = sdr,
  gamma = sdr,
  color_temperature = color_managed,
  srgb = color_managed,
  gain_red = function(s) return sdr(s) and s.ct == CT_USER_RGB end,
  light_enhancement = function(s) return hdr(s) and picture_adjustable(s) end,
  adaptive_sync = single_input,
  crosshair = single_input,
  smart_response = single_input,
  low_input_lag = function(s) return single_input(s) and not s.sharpshooter end,
}
GATES.gain_green = GATES.gain_red
GATES.gain_blue = GATES.gain_red
GATES.color_enhancement = GATES.light_enhancement

local function allowed(dev, key)
  local gate = GATES[key]
  if not gate or gate(dev.state) then return true end
  log("Philips Evnia 49: " .. key .. " is not available in the current monitor mode; skipped")
  return false
end

-- Mode-scoped picture values: the monitor keeps them per SmartImage preset and
-- only answers the set belonging to the current SDR/HDR family.
local function read_picture(dev, ranges, choices)
  local s = dev.state
  local v = ddc_get_standard(dev, 0xDC)
  if v then
    s.dc = v & 0xFF
    choices.smart_image = index_of_code(SMART_IMAGE_MODES, v)
    choices.smart_image_hdr = index_of_code(SMART_IMAGE_HDR_MODES, v)
  end
  v = ddc_get_standard(dev, 0x10); if v then ranges.brightness = clamp(v, 0, 100) end
  v = ddc_get_standard(dev, 0x12); if v then ranges.contrast = clamp(v, 0, 100) end
  if s.dc ~= nil and is_hdr_code(s.dc) then
    v = ddc_get_extended(dev, 0x3D); if v then ranges.light_enhancement = clamp(v, 0, 3) end
    v = ddc_get_extended(dev, 0x3E); if v then ranges.color_enhancement = clamp(v, 0, 3) end
    return
  end
  v = ddc_get_standard(dev, 0x72); if v then choices.gamma = index_of_code(GAMMA_VALUES, v) end
  v = ddc_get_standard(dev, 0x87); if v then ranges.sharpness = clamp(v, 0, 100) end
  v = ddc_get_extended(dev, 0x20); if v then s.srgb = v ~= 0 end
  v = ddc_get_standard(dev, 0x14)
  if v then
    s.ct = v & 0xFF
    choices.color_temperature = index_of_code(COLOR_TEMPERATURES, v)
  end
  if s.ct == CT_USER_RGB then
    v = ddc_get_standard(dev, 0x16); if v then ranges.gain_red = clamp(v, 0, 100) end
    v = ddc_get_standard(dev, 0x18); if v then ranges.gain_green = clamp(v, 0, 100) end
    v = ddc_get_standard(dev, 0x1A); if v then ranges.gain_blue = clamp(v, 0, 100) end
  end
end

-- ── Manifest ─────────────────────────────────────────────────────────────────
local CAT_PICTURE, CAT_COLOR, CAT_AUDIO = "picture", "color", "audio"
local CAT_OSD, CAT_SETUP, CAT_GAMING = "osd", "setup", "gaming"
local CAT_SYSTEM_USB, CAT_SMART_IMAGE = "system_usb", "smart_image"

local function table_choice(key, label, category, values, default)
  local options = {}
  for index, value in ipairs(values) do
    options[#options + 1] = { id = tostring(index - 1), label = value.label }
  end
  return { key = key, label = label, category = category, options = options, default = default or 0 }
end

local function numeric_choice(key, label, category, labels, default)
  local options = {}
  for index, option in ipairs(labels) do
    options[#options + 1] = { id = tostring(index - 1), label = option }
  end
  return { key = key, label = label, category = category, options = options, default = default or 0 }
end

local function visible(control, rule)
  control.visible_when = rule
  return control
end

local VISIBLE_SDR = { key = "hdr_active", equals = { 0 } }
local VISIBLE_HDR = { key = "hdr_active", equals = { 1 } }
local VISIBLE_GAINS = {
  key = "color_temperature",
  equals = indexes_where(COLOR_TEMPERATURES, function(c) return c == CT_USER_RGB end),
}

-- The catalog intentionally contains only inert identity and transport data.
-- These descriptors are runtime data: firmware can expose a different set of
-- controls, so they travel with initialize instead of plugin.yaml.
local RUNTIME_CONTROLS = {
  choices = {
    table_choice("input_source", "Input Source", CAT_SYSTEM_USB, INPUT_PORTS),
    visible(table_choice("smart_image", "SmartImage", CAT_SMART_IMAGE, SMART_IMAGE_MODES), VISIBLE_SDR),
    visible(table_choice("smart_image_hdr", "SmartImage HDR", CAT_SMART_IMAGE, SMART_IMAGE_HDR_MODES), VISIBLE_HDR),
    visible(table_choice("color_temperature", "Color Temperature", CAT_COLOR, COLOR_TEMPERATURES), VISIBLE_SDR),
    visible(table_choice("gamma", "Gamma", CAT_PICTURE, GAMMA_VALUES, 2), VISIBLE_SDR),
    table_choice("osd_language", "OSD Language", CAT_OSD, OSD_LANGUAGES),
    numeric_choice("smart_response", "SmartResponse", CAT_GAMING, { "Off", "Fast", "Faster", "Fastest" }),
    table_choice("power_mode", "Power", CAT_SETUP, POWER_MODES),
    table_choice("pixel_orbiting", "Pixel Orbiting", CAT_SETUP, PIXEL_ORBITING),
    table_choice("screen_saver", "Screen Saver", CAT_SETUP, SCREEN_SAVER),
    numeric_choice("crosshair", "Crosshair", CAT_GAMING, { "Off", "On", "Smart" }),
    numeric_choice("osd_transparency", "OSD Transparency", CAT_OSD, { "Off", "1", "2", "3", "4" }),
    numeric_choice("osd_timeout", "OSD Timeout", CAT_OSD, { "10s", "20s", "30s", "40s", "50s" }),
    numeric_choice("usb_c_setting", "USB-C Setting", CAT_SYSTEM_USB, { "High Resolution", "High Data" }),
    numeric_choice("kvm", "KVM", CAT_SYSTEM_USB, { "Auto", "USB Up", "USB-C" }),
  },
  ranges = {
    { key = "brightness", label = "Brightness", category = CAT_PICTURE, min = 0, max = 100, default = 50 },
    { key = "contrast", label = "Contrast", category = CAT_PICTURE, min = 0, max = 100, default = 50 },
    { key = "volume", label = "Volume", category = CAT_AUDIO, min = 0, max = 100, default = 0 },
    { key = "sharpness", label = "Sharpness", category = CAT_PICTURE, min = 0, max = 100, default = 50,
      visible_when = VISIBLE_SDR },
    { key = "light_enhancement", label = "Light Enhancement", category = CAT_PICTURE, min = 0, max = 3, default = 0,
      visible_when = VISIBLE_HDR },
    { key = "color_enhancement", label = "Color Enhancement", category = CAT_PICTURE, min = 0, max = 3, default = 0,
      visible_when = VISIBLE_HDR },
    { key = "osd_h_position", label = "OSD Horizontal Position", category = CAT_OSD, min = 0, max = 100, default = 50 },
    { key = "osd_v_position", label = "OSD Vertical Position", category = CAT_OSD, min = 0, max = 100, default = 50 },
    { key = "power_led", label = "Power LED Brightness", category = CAT_SETUP, min = 0, max = 4, default = 2 },
    { key = "gain_red", label = "Red Gain", category = CAT_COLOR, min = 0, max = 100, default = 100,
      visible_when = VISIBLE_GAINS },
    { key = "gain_green", label = "Green Gain", category = CAT_COLOR, min = 0, max = 100, default = 100,
      visible_when = VISIBLE_GAINS },
    { key = "gain_blue", label = "Blue Gain", category = CAT_COLOR, min = 0, max = 100, default = 100,
      visible_when = VISIBLE_GAINS },
  },
  booleans = {
    { key = "adaptive_sync", label = "Adaptive Sync", category = CAT_GAMING },
    { key = "low_input_lag", label = "Low Input Lag", category = CAT_GAMING },
    { key = "audio_mute", label = "Mute Audio", category = CAT_AUDIO },
    { key = "resolution_notice", label = "Resolution Notice", category = CAT_OSD },
    { key = "usb_standby", label = "USB Standby Mode", category = CAT_SYSTEM_USB },
    { key = "smart_power", label = "Smart Power", category = CAT_SETUP },
    { key = "cec", label = "CEC", category = CAT_SETUP },
    { key = "auto_warning", label = "Auto Warning", category = CAT_SETUP },
    { key = "srgb", label = "sRGB", category = CAT_PICTURE },
    { key = "hdr_active", label = "HDR Active", category = CAT_SMART_IMAGE, read_only = true },
  },
  actions = { { key = "pixel_refresh", label = "Pixel Refresh", category = CAT_SETUP } },
}

local function native_effects()
  local list = { { id = "monitor", name = "Monitor (firmware control)", params = {} } }
  for _, e in ipairs(NATIVE_EFFECTS) do
    list[#list + 1] = { id = e.id, name = e.name, params = e.params }
  end
  return list
end

local RANGE_WRITES = {
  brightness = { std = 0x10, max = 100 }, contrast = { std = 0x12, max = 100 },
  volume = { std = 0x62, max = 100 }, sharpness = { std = 0x87, max = 100 },
  power_led = { std = 0xF2, max = 4 }, gain_red = { std = 0x16, max = 100 },
  gain_green = { std = 0x18, max = 100 }, gain_blue = { std = 0x1A, max = 100 },
  light_enhancement = { ext = 0x3D, max = 3 }, color_enhancement = { ext = 0x3E, max = 3 },
  osd_h_position = { ext = 0x0E, max = 100 }, osd_v_position = { ext = 0x0F, max = 100 },
}

local BOOLEAN_WRITES = {
  adaptive_sync = { ext = 0x40 }, low_input_lag = { ext = 0x07 },
  audio_mute = { std = 0x8D, on = 0x01, off = 0x02 },
  resolution_notice = { std = 0xE9, on = 0x02, off = 0x00 },
  usb_standby = { ext = 0x13 }, smart_power = { ext = 0x16 }, cec = { ext = 0x17 },
  auto_warning = { ext = 0x43 }, srgb = { ext = 0x20, on = 0x02, off = 0x00 },
}

local MODE_CHANGING = set_of({ "smart_image", "smart_image_hdr", "color_temperature", "input_source" })

return {
  initialize = function(dev)
    dev.state = { checked_at = os.time() }
    dev.captured = false
    dev.has_frame = false
    dev.host_link = nil -- unknown until the first take or release
    local s = dev.state
    local ranges, choices = {}, {}
    local v

    local model = ddc_get_info(dev, 0xE9, 0x0D, 0x00, 0x00)
    if model == "" then model = nil end

    read_picture(dev, ranges, choices)

    v = ddc_get_standard(dev, 0x62); if v then ranges.volume = clamp(v, 0, 100) end
    v = ddc_get_standard(dev, 0xF2); if v then ranges.power_led = clamp(v, 0, 4) end
    v = ddc_get_extended(dev, 0x0E); if v then ranges.osd_h_position = clamp(v, 0, 100) end
    v = ddc_get_extended(dev, 0x0F); if v then ranges.osd_v_position = clamp(v, 0, 100) end

    v = ddc_get_standard(dev, 0x60)
    if v then
      s.input_secondary = (v >> 8) & 0xFF
      choices.input_source = index_of_code(INPUT_PORTS, v)
    end
    v = ddc_get_standard(dev, 0xA5); if v then s.pbp = v > 0 end
    v = ddc_get_standard(dev, 0xCC); if v then choices.osd_language = index_of_code(OSD_LANGUAGES, v) end
    v = ddc_get_standard(dev, 0xEB); if v then choices.smart_response = math.min(v, 3) end
    v = ddc_get_standard(dev, 0xD6); if v then choices.power_mode = index_of_code(POWER_MODES, v) end
    v = ddc_get_extended(dev, 0x04); if v then choices.crosshair = math.min(v, 2) end
    v = ddc_get_extended(dev, 0x06); if v then s.sharpshooter = v ~= 0 end
    v = ddc_get_extended(dev, 0x10); if v then choices.osd_transparency = math.min(v, 4) end
    v = ddc_get_extended(dev, 0x11); if v then choices.osd_timeout = math.min(v, 4) end
    v = ddc_get_extended(dev, 0x12); if v then choices.usb_c_setting = math.min(v, 1) end
    v = ddc_get_extended(dev, 0x15); if v then choices.kvm = math.min(v, 2) end
    v = ddc_get_extended(dev, 0x34); if v then choices.pixel_orbiting = index_of_code(PIXEL_ORBITING, v) end
    v = ddc_get_extended(dev, 0x35); if v then choices.screen_saver = index_of_code(SCREEN_SAVER, v) end

    v = ddc_get_extended(dev, 0x40); if v then s.adaptive_sync = v ~= 0 end
    v = ddc_get_extended(dev, 0x07); if v then s.low_input_lag = v ~= 0 end
    v = ddc_get_standard(dev, 0x8D); if v then s.audio_mute = v == 1 end
    v = ddc_get_standard(dev, 0xE9); if v then s.resolution_notice = v ~= 0 end
    v = ddc_get_extended(dev, 0x13); if v then s.usb_standby = v ~= 0 end
    v = ddc_get_extended(dev, 0x16); if v then s.smart_power = v ~= 0 end
    v = ddc_get_extended(dev, 0x17); if v then s.cec = v ~= 0 end
    v = ddc_get_extended(dev, 0x43); if v then s.auto_warning = v ~= 0 end

    v = ddc_get_extended(dev, AMBI_MODE_SUB); if v then s.ambi_mode = v & 0xFF end

    log("Philips Evnia 49 initialized")
    return {
      ok = true,
      model = model,
      controls = RUNTIME_CONTROLS,
      ranges = ranges,
      choices = choices,
      channels = { {
        id = "ambiglow",
        name = "Ambiglow",
        topology = "grid",
        led_count = LED_COUNT,
        leds = ambiglow_positions(),
      } },
      native_effects = native_effects(),
    }
  end,

  close = function(dev)
    if dev.host_link then resume_monitor_effect(dev) end
  end,

  -- Re-reads mode-scoped values after a mode change or when the monitor's
  -- SmartImage changed on its own (OSD, HDR signal), correcting host caches.
  read_status = function(dev)
    local s = dev.state
    if not s then return nil end
    local now = os.time()
    if s.backoff_until and now < s.backoff_until then return nil end
    local due = s.refresh_at and now >= s.refresh_at
    if s.refresh_at and not due then return nil end
    if not due and now - (s.checked_at or 0) < MODE_CHECK_S then return nil end
    s.checked_at = now
    dev.ddc_failed = false
    dev.fail_streak = 0
    dev.polling = true
    if not due then
      local v = ddc_get_standard(dev, 0xDC)
      if dev.ddc_failed then s.backoff_until = now + ERROR_BACKOFF_S end
      if not v or (v & 0xFF) == s.dc then
        dev.polling = false
        return nil
      end
    end
    s.refresh_at = nil
    local ranges, choices = {}, {}
    read_picture(dev, ranges, choices)
    dev.polling = false
    if dev.ddc_failed then s.backoff_until = os.time() + ERROR_BACKOFF_S end
    return { ranges = ranges, choices = choices }
  end,

  set_range = function(dev, key, value)
    local w = RANGE_WRITES[key]
    if not w then error("unknown range key: " .. key) end
    if not allowed(dev, key) then return end
    value = clamp(value, 0, w.max)
    if w.std then ddc_write(dev, build_write(w.std, value))
    else ddc_write(dev, build_extended_set(w.ext, value)) end
  end,

  set_choice = function(dev, key, selected)
    local s = dev.state
    if not allowed(dev, key) then return end
    if key == "input_source" then
      local code = code_at(INPUT_PORTS, selected)
      ddc_write(dev, build_write(0x60, ((s.input_secondary or 0) << 8) | code))
    elseif key == "osd_language" then ddc_write(dev, build_write(0xCC, code_at(OSD_LANGUAGES, selected)))
    elseif key == "smart_image" or key == "smart_image_hdr" then
      local code = code_at(key == "smart_image" and SMART_IMAGE_MODES or SMART_IMAGE_HDR_MODES, selected)
      if s.dc ~= nil and is_hdr_code(code) ~= is_hdr_code(s.dc) then
        log("Philips Evnia 49: " .. (is_hdr_code(code) and "HDR" or "SDR")
          .. " SmartImage presets are only selectable while the monitor shows that signal; skipped")
        return
      end
      ddc_write(dev, build_write(0xDC, code))
      s.dc = code
    elseif key == "color_temperature" then
      local code = code_at(COLOR_TEMPERATURES, selected)
      ddc_write(dev, build_write(0x14, code))
      s.ct = code
    elseif key == "gamma" then ddc_write(dev, build_write(0x72, code_at(GAMMA_VALUES, selected)))
    elseif key == "power_mode" then ddc_write(dev, build_write(0xD6, code_at(POWER_MODES, selected)))
    elseif key == "smart_response" then ddc_write(dev, build_write(0xEB, math.min(selected, 3)))
    elseif key == "pixel_orbiting" then ddc_write(dev, build_extended_set(0x34, code_at(PIXEL_ORBITING, selected)))
    elseif key == "screen_saver" then ddc_write(dev, build_extended_set(0x35, code_at(SCREEN_SAVER, selected)))
    elseif key == "crosshair" then ddc_write(dev, build_extended_set(0x04, math.min(selected, 2)))
    elseif key == "osd_transparency" then ddc_write(dev, build_extended_set(0x10, math.min(selected, 4)))
    elseif key == "osd_timeout" then ddc_write(dev, build_extended_set(0x11, math.min(selected, 4)))
    elseif key == "usb_c_setting" then ddc_write(dev, build_extended_set(0x12, math.min(selected, 1)))
    elseif key == "kvm" then ddc_write(dev, build_extended_set(0x15, math.min(selected, 2)))
    else error("unknown choice key: " .. key) end
    if MODE_CHANGING[key] then s.refresh_at = os.time() + REFRESH_DELAY_S end
  end,

  get_booleans = function(dev)
    local s = dev.state or {}
    return {
      { key = "adaptive_sync", value = s.adaptive_sync or false },
      { key = "low_input_lag", value = s.low_input_lag or false },
      { key = "audio_mute", value = s.audio_mute or false },
      { key = "resolution_notice", value = s.resolution_notice or false },
      { key = "usb_standby", value = s.usb_standby or false },
      { key = "smart_power", value = s.smart_power or false },
      { key = "cec", value = s.cec or false },
      { key = "auto_warning", value = s.auto_warning or false },
      { key = "srgb", value = s.srgb or false },
      { key = "hdr_active", value = s.dc ~= nil and is_hdr_code(s.dc), read_only = true },
    }
  end,

  set_boolean = function(dev, key, value)
    local w = BOOLEAN_WRITES[key]
    if not w then error("unknown boolean key: " .. key) end
    if not allowed(dev, key) then return end
    local raw = value and (w.on or 1) or (w.off or 0)
    if w.std then ddc_write(dev, build_write(w.std, raw))
    else ddc_write(dev, build_extended_set(w.ext, raw)) end
    dev.state[key] = value
    if key == "srgb" then dev.state.refresh_at = os.time() + REFRESH_DELAY_S end
  end,

  trigger_action = function(dev, key)
    if key == "pixel_refresh" then ddc_write(dev, build_extended_set(0x36, 0x01))
    else error("unknown action key: " .. key) end
  end,

  -- ── Ambiglow RGB ──────────────────────────────────────────────────────────
  apply = function(dev, state)
    if state.mode == "native_effect" then
      if state.id == "monitor" then
        resume_monitor_effect(dev)
      else
        local effect = find_effect(state.id)
        if effect and effect.ene then apply_ene_effect(dev, effect, state.params or {})
        elseif effect then apply_scaler_effect(dev, effect, state.params or {}) end
      end
    elseif state.mode == "static" then
      local fill = {}
      for i = 1, LED_COUNT do fill[i] = state.color end
      write_colors(dev, fill)
    elseif state.mode == "per_led" then
      local map = (state.channels or {}).ambiglow or {}
      local fill = {}
      for i = 0, LED_COUNT - 1 do fill[i + 1] = map[tostring(i)] or { r = 0, g = 0, b = 0 } end
      write_colors(dev, fill)
    end
  end,

  write_frame = function(dev, zone_id, bytes)
    local colors = {}
    for i = 1, #bytes, 3 do colors[#colors + 1] = { r = bytes[i] or 0, g = bytes[i + 1] or 0, b = bytes[i + 2] or 0 } end
    if zone_id == "ambiglow" then write_colors(dev, colors) end
  end,
}
