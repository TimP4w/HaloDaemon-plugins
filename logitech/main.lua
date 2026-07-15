-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: 2012-2013 Daniel Pavel
-- SPDX-FileCopyrightText: 2014-2024 Solaar Contributors <https://pwr-solaar.github.io/Solaar/>
--
-- Logitech HID++ 2.0.  The framing and feature enumeration below are derived
-- from Solaar's HID++ implementation.  Keep this protocol layer in one place:
-- device feature callbacks must only call `feature()` and never assemble an
-- ad-hoc report.

local SHORT, LONG = 0x10, 0x11
local DIRECT = 0xff
local SW_ID = 0x01

local FEATURE_SET = 0x0001
local DEVICE_NAME = 0x0005
local DEVICE_FRIENDLY_NAME = 0x0007

local BATTERY_VOLTAGE = 0x1001
local UNIFIED_BATTERY = 0x1004
local ADC_MEASUREMENT = 0x1f20
local WIRELESS_DEVICE_STATUS = 0x1d4b
local ADJUSTABLE_DPI = 0x2201
local REPORT_RATE = 0x8060
local EXT_REPORT_RATE = 0x8061
local RGB_EFFECTS = 0x8071
local COLOR_LED_EFFECTS = 0x8070
local PER_KEY_LIGHTING_V2 = 0x8081
local ONBOARD_PROFILES = 0x8100
local KEYBOARD_LAYOUT_2 = 0x4540
local REPROG_CONTROLS_V4 = 0x1b04
local GKEY = 0x8010
local MOUSE_BUTTON_SPY = 0x8110
local SIDETONE = 0x8300
local EQUALIZER = 0x8310
local HIRES_WHEEL = 0x2121
local K375S_FN_INVERSION = 0x40a3
local BRIGHTNESS_CONTROL = 0x8040

local function bytes(...) return string.char(...) end

local function is_long_only(pid)
  -- Composite LIGHTSPEED headset interfaces expose no short HID++ report.
  return pid == 0x0aba or pid == 0x0af7 or pid == 0x0ab5 or pid == 0x0afe
      or pid == 0x0ac4 or pid == 0x0a87 or pid == 0x0a66
end

local function packet(devnum, sub_id, address, payload, long)
  local size, report = long and 20 or 7, long and LONG or SHORT
  local out = bytes(report, devnum, sub_id, address) .. (payload or "")
  if #out > size then error("HID++ payload exceeds report size") end
  return out .. string.rep("\0", size - #out)
end

-- Route a built frame to the collection that accepts its report ID: a long
-- (0x11) frame goes to the companion collection when the device exposes one
-- (Windows splits the HID++ interface into a short and a long collection),
-- otherwise to the primary.  Writes must be routed to the matching collection;
-- replies are matched by `dispatch` wherever they land.
local function send(dev, wire)
  if wire:byte(1) == LONG and dev.transport:has_companion() then
    dev.transport:write_companion(wire)
  else
    dev.transport:write(wire)
  end
end

-- Read replies until the one answering `(devnum, sub)` arrives, mirroring the
-- native messenger's dispatch.
local function dispatch(dev, devnum, sub, address, check_func)
  local empties = 0
  for _ = 1, 64 do
    local reply = dev.transport:read_any(20)
    if #reply < 4 then
      empties = empties + 1
      if empties >= 2 then break end
    else
      empties = 0
      local rsub = reply:byte(3)
      if reply:byte(2) ~= devnum then
        dev.transport:defer_event(reply)
      elseif rsub == 0x8f or rsub == 0xff then
        if reply:byte(4) == sub then
          error(string.format("HID++ error response (code 0x%02x)", reply:byte(6) or 0))
        end
        dev.transport:defer_event(reply)
      elseif rsub == sub and (not check_func or (reply:byte(4) & 0xf0) == (address & 0xf0)) then
        return reply:sub(5)
      else
        dev.transport:defer_event(reply)
      end
    end
  end
  error("HID++ response did not arrive")
end

local function request(dev, devnum, feature_index, func, args)
  args = args or ""
  local long = is_long_only(dev.match.pid) or feature_index ~= 0 or #args > 3
  local address = func | SW_ID
  send(dev, packet(devnum, feature_index, address, args, long))
  return dispatch(dev, devnum, feature_index, address, true)
end

-- HID++ 1.0 receiver register read.  Register 0x2B5 is selected with sub-id
-- 0x83 (the high address bit becomes sub-id bit 1), unlike HID++ 2.0 features.
-- The request is always a short report, but its reply mirrors the payload
-- size: the device-count register answers short, the pairing records answer
-- long — so the reply is matched through `dispatch`, not a fixed collection.
local function v1_read(dev, devnum, reg, args)
  args = args or ""
  local sub = 0x81 | ((reg >> 8) & 0x02)
  send(dev, packet(devnum, sub, reg & 0xff, args, false))
  return dispatch(dev, devnum, sub, reg & 0xff, false)
end

local function v1_write(dev, devnum, reg, args)
  args = args or ""
  local sub = 0x80 | ((reg >> 8) & 0x02)
  send(dev, packet(devnum, sub, reg & 0xff, args, false))
end

local product_name

local function wpid_device_type(wpid)
  if wpid == 0x4099 then return "mouse" end
  if wpid == 0x40b0 then return "keyboard" end
  return "other"
end

local function receiver_children(dev)
  if dev.match.pid ~= 0xc547 then return {} end
  -- The device-count register is not a dense upper bound. Pairing slots remain
  -- sparse after an unpair and powered-off devices may not be counted at all.
  -- Probe all six slots like the native receiver and treat an error response
  -- from an empty slot as `None`, not as failure of the whole receiver.
  pcall(v1_read, dev, DIRECT, 0x0002)
  local out = {}
  for slot = 1, 6 do
    local pair_ok, pair = pcall(v1_read, dev, DIRECT, 0x02b5, bytes(0x20 + slot - 1))
    local hi, lo = pair_ok and pair:byte(4) or nil, pair_ok and pair:byte(5) or nil
    local wpid = hi and lo and ((hi << 8) | lo) or 0
    if wpid ~= 0 and wpid ~= 0xffff then
      local ext_ok, ext = pcall(v1_read, dev, DIRECT, 0x02b5, bytes(0x30 + slot - 1))
      local a, b, c, d
      if ext_ok then a, b, c, d = ext:byte(2, 5) end
      local serial = a and b and c and d and string.format("%02X%02X%02X%02X", a, b, c, d) or nil
      if serial == "00000000" or serial == "FFFFFFFF" then serial = nil end
      out[#out + 1] = {
        index = slot, key = tostring(slot), serial = serial,
        id = serial and ("logitech_" .. serial) or string.format("logitech_%04x_%d", wpid, slot),
        name = product_name(nil, wpid),
        device_type = wpid_device_type(wpid),
        -- Wireless children have a receiver WPID, not the receiver's USB PID.
        -- Keep it distinct from `dev.match.pid`, which is only meaningful for
        -- directly wired HID collections.
        extra = { wpid = wpid },
      }
    end
  end
  return out
end

local function feature_index(dev, devnum, code)
  local reply = request(dev, devnum, 0, 0x00, bytes((code >> 8) & 0xff, code & 0xff))
  local index = reply:byte(1) or 0
  return index ~= 0 and index or nil
end

local function enumerate_features(dev, devnum)
  local fs = feature_index(dev, devnum, FEATURE_SET)
  if not fs then return {} end
  local count = request(dev, devnum, fs, 0x00):byte(1) or 0
  local features = { [0] = 0, [FEATURE_SET] = fs }
  for i = 1, count do
    local reply = request(dev, devnum, fs, 0x10, bytes(i))
    local high, low = reply:byte(1), reply:byte(2)
    if high and low then
      local code = (high << 8) | low
      if code ~= 0 then features[code] = i end
    end
  end
  return features
end

local function read_name(dev, devnum, features)
  local index = features[DEVICE_FRIENDLY_NAME] or features[DEVICE_NAME]
  if not index then return nil end
  local length = request(dev, devnum, index, 0x00):byte(1) or 0
  if length == 0 then return nil end
  local out, offset = {}, 0
  while offset < length do
    local chunk = request(dev, devnum, index, 0x10, bytes(offset)):sub(1, length - offset)
    if #chunk == 0 then break end
    out[#out + 1], offset = chunk, offset + #chunk
  end
  local name = table.concat(out):gsub("%z.*", "")
  return #name > 0 and name or nil
end

product_name = function(pid, wpid)
  local names = {
    [0xc095] = "Logitech G502 X Plus", [0xc08b] = "Logitech G502 Hero",
    [0xc352] = "Logitech G PRO X TKL", [0xc547] = "Logitech LIGHTSPEED Receiver",
    [0x0aba] = "Logitech PRO X Wireless Gaming Headset",
    [0x0af7] = "Logitech PRO X 2 LIGHTSPEED",
    [0x0ab5] = "Logitech G733 LIGHTSPEED", [0x0afe] = "Logitech G733 LIGHTSPEED",
    [0x0ac4] = "Logitech G535 LIGHTSPEED", [0x0a87] = "Logitech G935",
    [0x0a66] = "Logitech G533",
  }
  local wireless = { [0x4099] = "Logitech G502 X Plus", [0x40b0] = "Logitech G PRO X TKL" }
  return names[pid] or wireless[wpid] or "Logitech HID++ Device"
end

local G502X_LED_ORDER = { 3, 4, 8, 7, 6, 5, 2, 1 }
local G502X_BUTTONS = {
  [1] = "G9", [2] = "G8", [3] = "G7", [9] = "Left Click",
  [10] = "Right Click", [11] = "Wheel Center", [12] = "G4",
  [13] = "Thumb Trigger", [14] = "G5", [15] = "Wheel Left", [16] = "Wheel Right",
}
local G502_HERO_BUTTONS = {
  [1] = "G9", [9] = "Left Click", [10] = "Right Click", [11] = "Wheel Center",
  [12] = "G4", [13] = "G5", [14] = "Thumb Trigger", [15] = "G7", [16] = "G8",
}

local function device_profile(dev)
  local pid, wpid = dev.match.pid, dev.match.wpid
  if pid == 0xc095 or wpid == 0x4099 then
    return { name = "Logitech G502 X Plus", device_type = "mouse", wireless = true,
      zone_name = "Lighting", topology = "linear",
      led_order = G502X_LED_ORDER, buttons = G502X_BUTTONS, native_effects = { "color_wave" },
      defaults = {
        { cid = 2, base = { type = "dpi_cycle", direction = "up" }, shifted = { type = "native" } },
        { cid = 3, base = { type = "dpi_cycle", direction = "down" }, shifted = { type = "native" } },
        { cid = 13, base = { type = "momentary_dpi", dpi = 400 }, shifted = { type = "native" } },
      } }
  elseif pid == 0xc08b then
    return { name = "Logitech G502 Hero", device_type = "mouse", buttons = G502_HERO_BUTTONS, native_effects = {},
      defaults = {
        { cid = 16, base = { type = "dpi_cycle", direction = "up" }, shifted = { type = "native" } },
        { cid = 15, base = { type = "dpi_cycle", direction = "down" }, shifted = { type = "native" } },
        { cid = 14, base = { type = "momentary_dpi", dpi = 400 }, shifted = { type = "native" } },
      } }
  elseif pid == 0xc352 or wpid == 0x40b0 then
    return { name = "Logitech G PRO X TKL", device_type = "keyboard", wireless = true,
      zone_name = "Keys", topology = "keyboard",
      native_effects = { "ripple" }, button_prefix = "G" }
  end
  return { name = product_name(pid, wpid), device_type = "other", native_effects = {} }
end

-- G PRO X TKL firmware LED id -> standard host key. Geometry for standard
-- keys comes from Halo's generic TKL templates; only Logitech-specific keys
-- carry explicit cells. This is the same map used by the former native driver.
local GPRO_TKL_KEYS = {
  {38,"escape"},{55,"f1"},{56,"f2"},{57,"f3"},{58,"f4"},{59,"f5"},{60,"f6"},
  {61,"f7"},{62,"f8"},{63,"f9"},{64,"f10"},{65,"f11"},{66,"f12"},
  {67,"print_screen"},{68,"scroll_lock"},{69,"pause"},
  {50,"backtick"},{27,"digit1"},{28,"digit2"},{29,"digit3"},{30,"digit4"},
  {31,"digit5"},{32,"digit6"},{33,"digit7"},{34,"digit8"},{35,"digit9"},
  {36,"digit0"},{42,"minus"},{43,"equals"},{39,"backspace"},
  {70,"insert"},{71,"home"},{72,"page_up"},
  {40,"tab"},{17,"q"},{23,"w"},{5,"e"},{18,"r"},{20,"t"},{25,"y"},
  {21,"u"},{9,"i"},{15,"o"},{16,"p"},{44,"left_bracket"},
  {45,"right_bracket"},{46,"backslash"},{73,"delete"},{74,"end"},
  {75,"page_down"},{37,"enter"},
  {54,"caps_lock"},{1,"a"},{19,"s"},{4,"d"},{6,"f"},{7,"g"},{8,"h"},
  {10,"j"},{11,"k"},{12,"l"},{48,"semicolon"},{49,"quote"},
  {105,"left_shift"},{97,"iso_extra"},{26,"z"},{24,"x"},{3,"c"},{22,"v"},
  {2,"b"},{14,"n"},{13,"m"},{51,"comma"},{52,"period"},{53,"slash"},
  {109,"right_shift"},{79,"up"},
  {104,"left_ctrl"},{107,"left_super"},{106,"left_alt"},{41,"space"},
  {110,"right_alt"},{108,"right_ctrl"},{77,"left"},{78,"down"},{76,"right"},
}

local GPRO_TKL_EXTRA_KEYS = {
  { led_id = 150, cell = { col = 5.0, row = -1.5 } },
  { led_id = 155, cell = { col = 11.0, row = -1.5 } },
  { led_id = 152, cell = { col = 12.0, row = -1.5 } },
  { led_id = 154, cell = { col = 13.0, row = -1.5 } },
  { led_id = 153, cell = { col = 14.0, row = -1.5 } },
  { led_id = 111, cell = { col = 11.25, row = 5.5 } },
  { led_id = 98, cell = { col = 12.25, row = 5.5 } },
}

local function gpro_tkl_variant(iso)
  local keys = {}
  for _, mapping in ipairs(GPRO_TKL_KEYS) do
    local key = mapping[2]
    if not (iso and key == "backslash") and not (not iso and key == "iso_extra") then
      keys[#keys + 1] = { led_id = mapping[1], key = key }
    end
  end
  for _, key in ipairs(GPRO_TKL_EXTRA_KEYS) do keys[#keys + 1] = key end
  if iso then
    -- Logitech firmware zone 47 replaces the standard ISO home-row backslash.
    keys[#keys + 1] = { led_id = 47, cell = { col = 12.75, row = 3.5 } }
  end
  return { base = iso and "tkl_iso" or "tkl", keys = keys }
end

local function gpro_tkl_keyboard(layout)
  return {
    ansi = gpro_tkl_variant(false),
    iso = gpro_tkl_variant(true),
    detected_language = layout or "unknown",
    languages = { "u_s", "c_h", "i_t", "d_e", "f_r", "u_k" },
  }
end

local function has(features, code) return features[code] ~= nil end

local VOLTAGE_CURVE = {
  { 100, 4186 }, { 90, 4067 }, { 80, 3989 }, { 70, 3922 },
  { 60, 3859 }, { 50, 3811 }, { 40, 3778 }, { 30, 3751 },
  { 20, 3717 }, { 10, 3671 }, { 5, 3646 }, { 2, 3579 }, { 0, 3500 },
}

local function voltage_percent(mv)
  if mv >= VOLTAGE_CURVE[1][2] then return 100 end
  if mv <= VOLTAGE_CURVE[#VOLTAGE_CURVE][2] then return 0 end
  for i = 1, #VOLTAGE_CURVE - 1 do
    local high, low = VOLTAGE_CURVE[i], VOLTAGE_CURVE[i + 1]
    if mv <= high[2] and mv >= low[2] then
      return math.floor(low[1] + (high[1] - low[1]) * (mv - low[2]) / (high[2] - low[2]))
    end
  end
  return 0
end

local function battery_reading(dev)
  local state = dev.hidpp
  if not state then return nil end
  local features, devnum = state.features, state.devnum
  local index = features[UNIFIED_BATTERY]
  if index then
    local reply = request(dev, devnum, index, 0x10)
    local level = reply:byte(1)
    if level then return level > 100 and 100 or level, (reply:byte(3) or 0) ~= 0 end
  end
  index = features[ADC_MEASUREMENT] or features[BATTERY_VOLTAGE]
  if not index then return nil end
  local reply = request(dev, devnum, index, 0x00, bytes(0))
  local hi, low = reply:byte(1), reply:byte(2)
  if not hi or not low then return nil end
  local mv = (hi << 8) | low
  if mv == 0 then return nil end -- headset asleep
  return voltage_percent(mv), reply:byte(3) == 0x03
end

local function dpi_list(dev, index)
  local raw = {}
  for chunk = 0, 15 do
    local reply = request(dev, dev.hidpp.devnum, index, 0x10, bytes(0, 0, chunk))
    -- HID++ returns a sensor byte before the list bytes.
    local payload = reply:sub(2)
    raw[#raw + 1] = payload
    if payload:find("\0\0", 1, true) then break end
  end
  raw = table.concat(raw)
  local out, i = {}, 1
  while i + 1 <= #raw do
    local value = (raw:byte(i) << 8) | raw:byte(i + 1)
    if value == 0 then break end
    if (value >> 13) == 7 and i + 3 <= #raw then
      local step, last = value & 0x1fff, (raw:byte(i + 2) << 8) | raw:byte(i + 3)
      if step == 0 or #out == 0 then break end
      local current = out[#out] + step
      while current <= last do out[#out + 1], current = current, current + step end
      i = i + 4
    else
      out[#out + 1], i = value, i + 2
    end
  end
  return out
end

local NATIVE_EFFECTS

local function feature(dev, code, func, args)
  local state = assert(dev.hidpp, "HID++ not initialized")
  local index = assert(state.features[code], "HID++ feature unavailable")
  return request(dev, state.devnum, index, func, args)
end

local function send_feature_packets(dev, packets)
  if #packets == 0 then return end
  if dev.transport:has_companion() then
    dev.transport:write_many_companion(packets)
  else
    dev.transport:write_many(packets)
  end
end

local function select_native_effects(profile)
  local out = {}
  for _, id in ipairs(profile.native_effects or {}) do
    for _, effect in ipairs(NATIVE_EFFECTS or {}) do
      if effect.id == id then out[#out + 1] = effect end
    end
  end
  return out
end

local function keyboard_layout(dev)
  if not dev.hidpp.features[KEYBOARD_LAYOUT_2] then return "unknown" end
  local country = feature(dev, KEYBOARD_LAYOUT_2, 0x00):byte(1)
  return ({ [1] = "u_s", [13] = "c_h", [14] = "i_t" })[country] or "unknown"
end

local function report_rates(dev)
  local state = dev.hidpp
  local index, ext = state.features[EXT_REPORT_RATE], true
  if not index then index, ext = state.features[REPORT_RATE], false end
  if not index then return nil end
  local flags_reply = request(dev, state.devnum, index, ext and 0x10 or 0x00)
  local current = request(dev, state.devnum, index, ext and 0x20 or 0x10):byte(1)
  local flags = ext and (((flags_reply:byte(1) or 0) << 8) | (flags_reply:byte(2) or 0)) or (flags_reply:byte(1) or 0)
  local labels = { "8ms", "4ms", "2ms", "1ms", "500µs", "250µs", "125µs" }
  local options = {}
  for bit = 0, ext and 6 or 7 do
    if (flags & (1 << bit)) ~= 0 then
      local wire = ext and bit or bit + 1
      options[#options + 1] = { id = tostring(wire), label = ext and labels[bit + 1] or (wire .. "ms"), wire = wire }
    end
  end
  return { index = index, ext = ext, current = current, options = options }
end

-- EQUALIZER (0x8310).  The info reply is [band_count, db_range, _, db_min,
-- db_max]; firmware uses zero min/max to mean the symmetric db range.  A
-- frequency reply has an echo byte followed by up to seven BE u16 values.
local function equalizer_read(dev)
  local state = assert(dev.hidpp, "HID++ not initialized")
  if not has(state.features, EQUALIZER) then return nil end
  local info = feature(dev, EQUALIZER, 0x00)
  local count = info:byte(1) or 0
  if count == 0 then return nil end
  local span, raw_min, raw_max = info:byte(2) or 0, info:byte(4) or 0, info:byte(5) or 0
  local min = raw_min >= 0x80 and raw_min - 0x100 or raw_min
  local max = raw_max >= 0x80 and raw_max - 0x100 or raw_max
  if min == 0 then min = -span end
  if max == 0 then max = span end
  local freqs = {}
  for start = 0, count - 1, 7 do
    local reply = feature(dev, EQUALIZER, 0x10, bytes(start))
    local remaining = math.min(7, count - start)
    for band = 0, remaining - 1 do
      local hi, lo = reply:byte(2 + band * 2), reply:byte(3 + band * 2)
      if hi and lo then freqs[#freqs + 1] = (hi << 8) | lo end
    end
  end
  local levels = feature(dev, EQUALIZER, 0x20, bytes(0))
  local bands = {}
  for i = 1, count do
    local raw = levels:byte(i) or 0
    local value = raw >= 0x80 and raw - 0x100 or raw
    local hz = freqs[i]
    local label
    if hz then
      if hz >= 1000 and hz % 1000 == 0 then label = (hz // 1000) .. " kHz"
      elseif hz >= 1000 then label = string.format("%.1f kHz", hz / 1000)
      else label = hz .. " Hz" end
    else label = "Band " .. i end
    bands[#bands + 1] = { index = i - 1, label = label, min = min, max = max, step = 1, value = value }
  end
  local result = { presets = {{ id = "custom", label = "Custom", is_custom = true, is_firmware = false }},
    selected_preset = 0, bands = bands, editable = true }
  dev.equalizer = { min = min, max = max, count = count, result = result }
  return result
end

NATIVE_EFFECTS = {
  { id = "color_wave", name = "Color Wave", params = {},
    block = { 0xff, 0x00, 0, 0, 0, 0, 0, 0, 0x88, 0x01, 0x64, 0x13, 0x01, 0, 0 } },
  { id = "ripple", name = "Ripple", params = {
      { id = "background", label = "Background Color", kind = { kind = "color" }, default = { r = 0x5e, g = 0x5e, b = 0x5e } },
      { id = "rate", label = "Effect Rate (ms)", kind = { kind = "range", min = 2, max = 200, step = 1 }, default = 20 },
      { id = "saturation", label = "Saturation", kind = { kind = "range", min = 0, max = 100, step = 1 }, default = 100 },
    }, block = { 0xff, 0x03, 0x5e, 0x5e, 0x5e, 0xff, 0, 0, 0, 0x14, 0, 0, 0x01, 0, 0 } },
}

local function apply_native_effect(dev, id, params)
  local effect
  for _, candidate in ipairs(NATIVE_EFFECTS) do if candidate.id == id then effect = candidate; break end end
  if not effect then error("unknown Logitech native effect: " .. tostring(id)) end
  local block = {}
  for i, value in ipairs(effect.block) do block[i] = value end
  if id == "ripple" then
    local background = params.background
    if background then block[3], block[4], block[5] = background.r or 0, background.g or 0, background.b or 0 end
    if params.rate ~= nil then block[10] = math.floor(math.max(2, math.min(200, params.rate)) + 0.5) end
    if params.saturation ~= nil then block[6] = math.floor(math.max(0, math.min(100, params.saturation)) * 2.55 + 0.5) end
  end
  feature(dev, RGB_EFFECTS, 0x10, bytes(table.unpack(block)))
end

local function ordered_led_ids(ids, preferred)
  if not preferred then table.sort(ids); return ids end
  local present, out = {}, {}
  for _, id in ipairs(ids) do present[id] = true end
  for _, id in ipairs(preferred) do if present[id] then out[#out + 1] = id end end
  return #out > 0 and out or ids
end

local function discover_per_key_ids(dev, index, preferred)
  local ids = {}
  for page = 0, 2 do
    local reply = request(dev, dev.hidpp.devnum, index, 0x00, bytes(0, page, 0))
    local bitmap = reply:sub(3, 16)
    for bit = 0, 111 do
      local byte = bitmap:byte((bit // 8) + 1) or 0
      local id = page * 112 + bit
      if id > 0 and id <= 255 and (byte & (1 << (bit % 8))) ~= 0 then ids[#ids + 1] = id end
    end
  end
  return ordered_led_ids(ids, preferred)
end

local function rgb_static_slots(dev, index, count)
  local slots = {}
  for zone = 0, count - 1 do
    local info = request(dev, dev.hidpp.devnum, index, 0x00, bytes(zone, 0xff, 0))
    local effect_count, static = info:byte(5) or 0, 0
    for slot = 0, effect_count - 1 do
      local effect = request(dev, dev.hidpp.devnum, index, 0x00, bytes(zone, slot, 0))
      local id = ((effect:byte(3) or 0) << 8) | (effect:byte(4) or 0)
      if id == 0x0001 then static = slot end
    end
    slots[zone + 1] = static
  end
  return slots
end

local COLOR_ZONE_NAMES = {
  [1] = "Primary", [2] = "Logo", [3] = "Left Side", [4] = "Right Side",
  [5] = "Combined", [6] = "Primary 1", [7] = "Primary 2", [8] = "Primary 3",
  [9] = "Primary 4", [10] = "Primary 5", [11] = "Primary 6",
}

local function color_led_zones(dev, index, count)
  local zones, slots = {}, {}
  for zone = 0, count - 1 do
    local info = request(dev, dev.hidpp.devnum, index, 0x10, bytes(zone, 0xff, 0))
    local actual = info:byte(1) or zone
    local location = ((info:byte(2) or 0) << 8) | (info:byte(3) or 0)
    local effect_count, static = info:byte(4) or 0, 0
    for slot = 0, effect_count - 1 do
      local effect = request(dev, dev.hidpp.devnum, index, 0x20, bytes(actual, slot, 0))
      local id = ((effect:byte(3) or 0) << 8) | (effect:byte(4) or 0)
      if id == 0x0001 then static = slot end
    end
    zones[#zones + 1] = { id = "zone_" .. actual,
      name = COLOR_ZONE_NAMES[location] or "Unknown", topology = "linear", led_count = 1 }
    slots[#slots + 1] = static
  end
  return zones, slots
end

local function write_per_key_frame(dev, colors)
  local ids = dev.rgb.led_ids or {}
  local cache, states = dev.rgb.frame_cache or {}, {}
  dev.rgb.frame_cache = cache
  for i = 1, math.min(#ids, #colors) do
    local color, id = colors[i], ids[i]
    local r, g, b = color.r or 0, color.g or 0, color.b or 0
    local old = cache[id]
    states[#states + 1] = { id = id, r = r, g = g, b = b,
      dirty = not old or old[1] ~= r or old[2] ~= g or old[3] ~= b }
  end
  table.sort(states, function(a, b) return a.id < b.id end)
  local any = false; for _, state in ipairs(states) do if state.dirty then any = true; break end end
  if not any then return end

  -- Same encoder strategy as the native driver: equal-colour blocks become
  -- SET_RANGE, consecutive varying runs become SET_CONSECUTIVE, and only
  -- changed blocks are sent. A breathing frame is therefore two reports
  -- (one range + commit), not one report per four LEDs.
  local blocks = {}
  for _, state in ipairs(states) do
    local block = blocks[#blocks]
    if block and block.r == state.r and block.g == state.g and block.b == state.b then
      block.last, block.len = state.id, block.len + 1
      block.dirty = block.dirty or state.dirty
    else
      blocks[#blocks + 1] = { first = state.id, last = state.id, len = 1,
        r = state.r, g = state.g, b = state.b, dirty = state.dirty }
    end
  end

  local ranges, packets, i = {}, {}, 1
  while i <= #blocks do
    local block = blocks[i]
    if not block.dirty then
      i = i + 1
    elseif block.len > 1 then
      ranges[#ranges + 1] = { block.first, block.last, block.r, block.g, block.b }
      i = i + 1
    else
      local last = i
      while last + 1 <= #blocks and blocks[last + 1].dirty and blocks[last + 1].len == 1
          and blocks[last + 1].first == blocks[last].first + 1 do last = last + 1 end
      if last - i + 1 >= 3 then
        local start = i
        while start <= last do
          local payload, finish = { blocks[start].first }, math.min(start + 4, last)
          for n = start, finish do
            local entry = blocks[n]
            payload[#payload + 1] = entry.r
            payload[#payload + 1] = entry.g
            payload[#payload + 1] = entry.b
          end
          packets[#packets + 1] = packet(dev.hidpp.devnum,
            dev.hidpp.features[PER_KEY_LIGHTING_V2], 0x20 | SW_ID,
            bytes(table.unpack(payload)), true)
          start = finish + 1
        end
      else
        for n = i, last do
          local entry = blocks[n]
          ranges[#ranges + 1] = { entry.first, entry.first, entry.r, entry.g, entry.b }
        end
      end
      i = last + 1
    end
  end
  for start = 1, #ranges, 3 do
    local payload = {}
    for n = start, math.min(start + 2, #ranges) do
      for _, value in ipairs(ranges[n]) do payload[#payload + 1] = value end
    end
    packets[#packets + 1] = packet(dev.hidpp.devnum,
      dev.hidpp.features[PER_KEY_LIGHTING_V2], 0x50 | SW_ID,
      bytes(table.unpack(payload)), true)
  end
  packets[#packets + 1] = packet(dev.hidpp.devnum,
    dev.hidpp.features[PER_KEY_LIGHTING_V2], 0x70 | SW_ID, bytes(0), true)
  send_feature_packets(dev, packets)
  for _, state in ipairs(states) do cache[state.id] = { state.r, state.g, state.b } end
end

-- Paint mode supplies a sparse map keyed by firmware LED id. Preserve that
-- addressing and use the protocol's explicit setIndividual operation; a
-- streaming frame is positional and cannot represent a one-key sparse edit.
local function write_per_key_pairs(dev, zones)
  local supported, entries = {}, {}
  for _, id in ipairs(dev.rgb.led_ids or {}) do supported[id] = true end
  for _, led_colors in pairs(zones or {}) do
    for led_id, color in pairs(led_colors) do
      local id = tonumber(led_id)
      if id and supported[id] then
        entries[#entries + 1] = {
          id = id, r = color.r or 0, g = color.g or 0, b = color.b or 0,
        }
      end
    end
  end
  if #entries == 0 then return end
  table.sort(entries, function(a, b) return a.id < b.id end)

  local packets = {}
  for start = 1, #entries, 4 do
    local finish = math.min(start + 3, #entries)
    local last, payload = entries[finish], {}
    for offset = 0, 3 do
      local entry = entries[math.min(start + offset, finish)] or last
      payload[#payload + 1] = entry.id
      payload[#payload + 1] = entry.r
      payload[#payload + 1] = entry.g
      payload[#payload + 1] = entry.b
    end
    packets[#packets + 1] = packet(dev.hidpp.devnum,
      dev.hidpp.features[PER_KEY_LIGHTING_V2], 0x10 | SW_ID,
      bytes(table.unpack(payload)), true)
  end
  packets[#packets + 1] = packet(dev.hidpp.devnum,
    dev.hidpp.features[PER_KEY_LIGHTING_V2], 0x70 | SW_ID, bytes(0), true)
  send_feature_packets(dev, packets)

  local cache = dev.rgb.frame_cache or {}
  dev.rgb.frame_cache = cache
  for _, entry in ipairs(entries) do cache[entry.id] = { entry.r, entry.g, entry.b } end
end

local function write_rgb_zone(dev, zone_id, colors)
  if not dev.rgb then return end
  if dev.rgb.wire == "per_key" then write_per_key_frame(dev, colors); return end
  local zone = tonumber(zone_id:match("^zone_(%d+)$")) or 0
  local color = colors[1] or { r = 0, g = 0, b = 0 }
  local slot = dev.rgb.static_slots[zone + 1] or 0
  if dev.rgb.wire == "color_led" then
    feature(dev, COLOR_LED_EFFECTS, 0x30,
      bytes(zone, slot, color.r or 0, color.g or 0, color.b or 0, 0, 0, 0, 0, 0, 0, 0))
  else
    feature(dev, RGB_EFFECTS, 0x10,
      bytes(zone, slot, color.r or 0, color.g or 0, color.b or 0,
        0x64, 0x0b, 0xb8, 0x64, 0, 0, 0, 1, 0, 0))
  end
end

local function restore_rgb_control(dev)
  if not dev.rgb then return end
  if dev.rgb.wire == "rgb_effects" or dev.hidpp.features[RGB_EFFECTS] then
    feature(dev, RGB_EFFECTS, 0x50, bytes(1, 1))
  elseif dev.rgb.wire == "color_led" then
    feature(dev, COLOR_LED_EFFECTS, 0x80, bytes(1))
  end
end

local function onboard_mode(dev)
  if not dev.onboard then return 2 end
  local mode = feature(dev, ONBOARD_PROFILES, 0x20):byte(1) or dev.onboard.mode
  dev.onboard.mode = mode
  return mode
end

local function set_onboard_mode(dev, host)
  feature(dev, ONBOARD_PROFILES, 0x10, bytes(host and 2 or 1))
  dev.onboard.mode = host and 2 or 1
  if host then restore_rgb_control(dev) end
end

local function crc16(data)
  local crc = 0xffff
  for i = 1, #data do
    crc = crc ~ (data:byte(i) << 8)
    for _ = 1, 8 do
      crc = ((crc & 0x8000) ~= 0) and (((crc << 1) ~ 0x1021) & 0xffff)
        or ((crc << 1) & 0xffff)
    end
  end
  return crc
end

local function with_sector_crc(data, size)
  if size < 2 or #data < size then error("profile sector is too short") end
  local body = data:sub(1, size - 2)
  local crc = crc16(body)
  return body .. bytes((crc >> 8) & 0xff, crc & 0xff)
end

local function read_sector(dev, sector, size)
  if size < 16 then error("invalid onboard profile sector size") end
  local chunks, offset = {}, 0
  while offset + 15 < size do
    local reply
    for _ = 1, 3 do
      local ok, value = pcall(feature, dev, ONBOARD_PROFILES, 0x50,
        bytes((sector >> 8) & 0xff, sector & 0xff, (offset >> 8) & 0xff, offset & 0xff))
      if ok then reply = value; break end
    end
    if not reply then error(string.format("failed to read profile sector 0x%04X", sector)) end
    chunks[#chunks + 1] = reply:sub(1, math.min(16, size - offset))
    offset = offset + 16
  end
  local data = table.concat(chunks)
  if #data < size then
    local tail = size - 16
    local reply = feature(dev, ONBOARD_PROFILES, 0x50,
      bytes((sector >> 8) & 0xff, sector & 0xff, (tail >> 8) & 0xff, tail & 0xff))
    local missing = size - #data
    data = data .. reply:sub(17 - missing, 16)
  end
  return data:sub(1, size)
end

local function write_sector(dev, sector, data)
  local size = #data
  feature(dev, ONBOARD_PROFILES, 0x60,
    bytes((sector >> 8) & 0xff, sector & 0xff, 0, 0, (size >> 8) & 0xff, size & 0xff))
  for offset = 1, size, 16 do
    local chunk = data:sub(offset, offset + 15)
    if #chunk < 16 then chunk = chunk .. string.rep("\0", 16 - #chunk) end
    feature(dev, ONBOARD_PROFILES, 0x70, chunk)
  end
  feature(dev, ONBOARD_PROFILES, 0x80)
end

local function parse_directory(data)
  local out = {}
  for offset = 1, #data - 2, 4 do
    local sector = ((data:byte(offset) or 0) << 8) | (data:byte(offset + 1) or 0)
    if sector == 0 or sector == 0xffff then break end
    out[#out + 1] = { sector = sector, enabled = (data:byte(offset + 2) or 0) ~= 0,
      offset = offset }
  end
  return out
end

local function sector_dpi_steps(data)
  local out = {}
  if #data < 13 then return out end
  for i = 0, 4 do
    local offset = 4 + i * 2
    local value = (data:byte(offset) or 0) | ((data:byte(offset + 1) or 0) << 8)
    if value ~= 0 and value ~= 0xffff then out[#out + 1] = value end
  end
  return out
end

local function patch_sector_dpi(data, size, steps)
  if #steps == 0 then error("DPI steps list cannot be empty") end
  if #steps > 5 then error("onboard profiles support at most five DPI steps") end
  local values = { data:byte(1, size) }
  for i = 0, 4 do
    local value = steps[i + 1] or 0
    values[4 + i * 2], values[5 + i * 2] = value & 0xff, (value >> 8) & 0xff
  end
  if (values[2] or 0) >= #steps then values[2] = #steps - 1 end
  if (values[3] or 0) >= #steps then values[3] = 0 end
  return with_sector_crc(bytes(table.unpack(values)), size)
end

local function refresh_onboard(dev)
  local info = feature(dev, ONBOARD_PROFILES, 0x00)
  local size = ((info:byte(8) or 0) << 8) | (info:byte(9) or 0)
  if size < 16 then error("invalid onboard profile sector size") end
  local mode = feature(dev, ONBOARD_PROFILES, 0x20):byte(1) or 1
  local directory_data = read_sector(dev, 0, size)
  local directory = parse_directory(directory_data)
  local active_reply = feature(dev, ONBOARD_PROFILES, 0x40)
  local active = ((active_reply:byte(1) or 0) << 8) | (active_reply:byte(2) or 0)
  if active == 0 or active == 0xffff then
    active = 0
    for _, entry in ipairs(directory) do if entry.enabled then active = entry.sector; break end end
  end
  dev.onboard = { mode = mode, rom_count = info:byte(5) or 0, sector_size = size,
    directory = directory, directory_data = directory_data, active_sector = active }
  if active ~= 0 then
    dev.onboard.profile_data = read_sector(dev, active, size)
    dev.onboard.profile_steps = sector_dpi_steps(dev.onboard.profile_data)
  else
    dev.onboard.profile_steps = {}
  end
  return dev.onboard
end

local function onboard_status(dev)
  local state = refresh_onboard(dev)
  local active_slot = state.mode == 2 and 0 or (state.active_sector & 0xff)
  local slots = {}
  for _, entry in ipairs(state.directory) do
    local slot = entry.sector & 0xff
    slots[#slots + 1] = { index = slot, enabled = entry.enabled,
      active = active_slot ~= 0 and active_slot == slot,
      has_rom_default = slot > 0 and slot <= state.rom_count }
  end
  return { active_slot = active_slot, slots = slots }
end

local function restore_profile(dev, slot, allow_seed)
  local state = dev.onboard or refresh_onboard(dev)
  if slot == 0 then error("profile slot must be 1-based") end
  if not allow_seed and slot > state.rom_count then error("profile has no factory default") end
  local source = slot <= state.rom_count and (0x0100 | slot) or 0x0101
  local data = with_sector_crc(read_sector(dev, source, state.sector_size), state.sector_size)
  write_sector(dev, slot, data)
end

local function action_is_native(action)
  return not action or action.type == nil or action.type == "native"
end

local function mapping_is_native(mapping)
  return action_is_native(mapping.base) and action_is_native(mapping.shifted)
end

local function remap_buttons(dev)
  local state = dev.hidpp
  local features, devnum = state.features, state.devnum
  local buttons, backend = {}, nil
  local reprog = features[REPROG_CONTROLS_V4]
  if reprog then
    backend = "reprog"
    local count = request(dev, devnum, reprog, 0x00):byte(1) or 0
    for i = 0, count - 1 do
      local info = request(dev, devnum, reprog, 0x10, bytes(i))
      local hi, lo, task_hi, task_lo, flags, _, group = info:byte(1, 7)
      if hi and lo and flags and (flags & 0x08) ~= 0 then
        local cid = (hi << 8) | lo
        local task = ((task_hi or 0) << 8) | (task_lo or 0)
        local labels = { [0x0038] = "Left Button", [0x0039] = "Right Button", [0x003a] = "Middle Button",
          [0x003b] = "Back", [0x003c] = "Forward", [0x00c7] = "DPI Down", [0x00c8] = "DPI Up",
          [0x00c9] = "DPI Cycle", [0x00d0] = "DPI Shift", [0x00d7] = "Smart Shift",
          [0x0050] = "Volume Mute", [0x0051] = "Volume Down", [0x0052] = "Volume Up" }
        local label = labels[task] or (cid == 0x0056 and "Left Scroll")
          or (cid == 0x005d and "Right Scroll") or string.format("Button 0x%04X", cid)
        buttons[#buttons + 1] = { cid = cid, label = label, divertable = true, group = group or 0 }
      end
    end
  elseif features[GKEY] then
    backend = "gkey"
    local count = request(dev, devnum, features[GKEY], 0x00):byte(1) or 0
    for i = 1, count do buttons[#buttons + 1] = { cid = i, label = "G" .. i, divertable = true, group = 0 } end
  elseif features[MOUSE_BUTTON_SPY] then
    backend = "spy"
    local labels = device_profile(dev).buttons
    for i = 1, 16 do
      if not labels or labels[i] then
        buttons[#buttons + 1] = { cid = i, label = labels and labels[i] or ("Button " .. i), divertable = true, group = 0 }
      end
    end
  end
  dev.remap = { backend = backend, active = {}, previous = {} }
  return buttons
end

local function set_remap_active(dev, cid, enabled)
  local remap = assert(dev.remap, "remap unavailable")
  remap.active[cid] = enabled or nil
  local any = next(remap.active) ~= nil
  if remap.backend == "reprog" then
    local payload = { (cid >> 8) & 0xff, cid & 0xff, enabled and 1 or 0 }
    for _ = 1, 13 do payload[#payload + 1] = 0 end
    feature(dev, REPROG_CONTROLS_V4, 0x30, bytes(table.unpack(payload)))
  elseif remap.backend == "gkey" then
    feature(dev, GKEY, 0x20, bytes(any and 1 or 0))
  elseif remap.backend == "spy" then
    feature(dev, MOUSE_BUTTON_SPY, 0x10, bytes(any and 1 or 0))
  end
end

local function button_events(dev, packet_in)
  local remap = dev.remap
  if not remap or not remap.backend or #packet_in < 4 then return nil end
  local devnum = dev.match.index or DIRECT
  if packet_in:byte(2) ~= devnum then return nil end
  local sub, address = packet_in:byte(3), packet_in:byte(4)
  if address ~= 0 then return nil end
  local expected = remap.backend == "reprog" and dev.hidpp.features[REPROG_CONTROLS_V4]
    or remap.backend == "gkey" and dev.hidpp.features[GKEY]
    or dev.hidpp.features[MOUSE_BUTTON_SPY]
  if sub ~= expected then return nil end
  local current = {}
  if remap.backend == "reprog" then
    for pos = 5, math.min(#packet_in - 1, 12), 2 do
      local hi, lo = packet_in:byte(pos), packet_in:byte(pos + 1)
      local cid = hi and lo and ((hi << 8) | lo) or 0
      if cid ~= 0 then current[#current + 1] = cid end
    end
  else
    local bits = (packet_in:byte(5) or 0) | ((packet_in:byte(6) or 0) << 8)
    for bit = 0, 15 do if (bits & (1 << bit)) ~= 0 then current[#current + 1] = bit + 1 end end
  end
  local previous, pressed, released = remap.previous, {}, {}
  for _, cid in ipairs(current) do if not previous[cid] then pressed[#pressed + 1] = cid end end
  for cid in pairs(previous) do
    local found = false; for _, current_cid in ipairs(current) do if cid == current_cid then found = true; break end end
    if not found then released[#released + 1] = cid end
  end
  remap.previous = {}; for _, cid in ipairs(current) do remap.previous[cid] = true end
  return { pressed = pressed, released = released }
end

return {
  route_event = function(event)
    local report = event.report
    if #report < 4 then return false end
    local sub = report:byte(3)
    -- The low bit of byte 4 is data for HID++ 1.0 pairing-lock (0x4a),
    -- not a HID++ 2.0 software id. Route receiver lifecycle notifications
    -- before applying the reply filter or the lock-open event gets dropped.
    if sub == 0x4a or sub == 0x41 then return 0 end
    -- Replies/ACKs carry our non-zero software-id nibble. They are not input
    -- notifications and must not queue behind animation frames.
    if (report:byte(4) & 0x0f) ~= 0 then return false end
    -- Receiver lifecycle notifications belong to the physical root even when
    -- a 0x41 connection event carries the newly allocated child devnum.
    local devnum = report:byte(2)
    return devnum >= 1 and devnum <= 6 and devnum or 0
  end,
  enumerate_controllers = receiver_children,
  start_pairing = function(dev, timeout_secs)
    if dev.match.pid ~= 0xc547 then error("pairing is receiver-only") end
    v1_write(dev, DIRECT, 0x00b2, bytes(0x01, 0, math.min(255, timeout_secs)))
    dev.pairing_state, dev.pairing_error = "listening", nil
  end,
  stop_pairing = function(dev)
    if dev.match.pid ~= 0xc547 then error("pairing is receiver-only") end
    v1_write(dev, DIRECT, 0x00b2, bytes(0x02, 0, 0))
    dev.pairing_state, dev.pairing_error = "idle", nil
  end,
  unpair = function(dev, slot)
    if dev.match.pid ~= 0xc547 then error("pairing is receiver-only") end
    v1_write(dev, DIRECT, 0x00b2, bytes(0x03, slot))
    dev.pairing_state = "idle"
  end,
  pairing_status = function(dev)
    if dev.match.pid ~= 0xc547 then error("pairing is receiver-only") end
    local children = receiver_children(dev)
    local slots = {}
    for _, child in ipairs(children) do
      slots[#slots + 1] = { slot = child.index, device_id = child.id, name = child.name, connected = true }
    end
    return { state = dev.pairing_state or "idle", error = dev.pairing_error,
      max_slots = 6, slots = slots }
  end,
  initialize = function(dev)
    -- Direct USB devices use 0xff. Receiver children are added through the
    -- controller-discovery path and carry their paired slot in dev.match.index.
    -- A receiver is only the transport root; paired slot children are the
    -- actual devices. Direct devices retain 0xff.
    if dev.match.pid == 0xc547 and not dev.match.key then
      return { ok = true, model = product_name(dev.match.pid), capabilities = { "pairing" } }
    end
    local devnum = tonumber(dev.match.key) or dev.match.index or DIRECT
    local features = enumerate_features(dev, devnum)
    dev.hidpp = { devnum = devnum, features = features }
    local profile = device_profile(dev)
    dev.profile = profile
    local layout = profile.topology == "keyboard" and keyboard_layout(dev) or nil
    local name = read_name(dev, devnum, features) or profile.name

    local result = { ok = true, model = name, capabilities = {},
      controls = { ranges = {}, choices = {}, booleans = {}, actions = {} } }
    local function capability(name) result.capabilities[#result.capabilities + 1] = name end
    if profile.device_type == "keyboard" then
      result.keyboard = gpro_tkl_keyboard(layout)
      capability("keyboard_layout")
    end
    -- Declare only capabilities actually advertised by the feature table.
    -- Their packet implementations are added below as the corresponding
    -- protocol codecs are ported; this keeps unknown devices inert rather than
    -- advertising controls that their firmware cannot service.
    if has(features, ONBOARD_PROFILES) then
      local state = refresh_onboard(dev)
      result.controls.booleans[#result.controls.booleans + 1] = {
        key = "host_mode", label = "Host mode", category = "Onboard Memory"
      }
      result.booleans = result.booleans or {}; result.booleans.host_mode = state.mode == 2
      if #state.directory > 0 then capability("onboard_profiles") end
    end
    if has(features, ADJUSTABLE_DPI) then
      local available = dpi_list(dev, features[ADJUSTABLE_DPI])
      local current = request(dev, devnum, features[ADJUSTABLE_DPI], 0x20)
      local dpi = #current >= 3 and ((current:byte(2) << 8) | current:byte(3))
          or (#current >= 2 and ((current:byte(1) << 8) | current:byte(2))) or 0
      local profile_steps = dev.onboard and dev.onboard.profile_steps or {}
      local steps = #profile_steps > 0 and profile_steps or available
      dev.software_dpi_steps = { table.unpack(steps) }
      dev.available_dpis, dev.current_dpi = available, dpi
      result.dpi = { min = available[1] or dpi or 100,
        max = available[#available] or dpi or 25600, steps = steps,
        available_dpis = available,
        onboard = dev.onboard ~= nil and dev.onboard.mode ~= 2,
        mode_control = dev.onboard and "host_mode" or nil, current = dpi }
      capability("dpi")
    end
    local buttons = remap_buttons(dev)
    if #buttons > 0 then
      result.key_remap = { buttons = buttons, requires_host_mode = false,
        default_mappings = profile.defaults or {} }
      capability("key_remap")
    end
    local rates = report_rates(dev)
    if rates and #rates.options > 0 then
      dev.report_rates = rates
      local selected = 0
      for i, option in ipairs(rates.options) do if option.wire == rates.current then selected = i - 1 end end
      result.controls.choices[#result.controls.choices + 1] = {
        key = "report_rate", label = "Report rate", options = rates.options, default = selected, category = "Performance"
      }
      result.choices = result.choices or {}; result.choices.report_rate = selected
    end
    if has(features, RGB_EFFECTS) then
      local count = request(dev, devnum, features[RGB_EFFECTS], 0x00, bytes(0xff, 0xff, 0)):byte(3) or 0
      if count > 0 then
        local static_slots = rgb_static_slots(dev, features[RGB_EFFECTS], count)
        local led_ids = has(features, PER_KEY_LIGHTING_V2)
          and discover_per_key_ids(dev, features[PER_KEY_LIGHTING_V2], profile.led_order) or {}
        local wire = #led_ids > 0 and "per_key" or "rgb_effects"
        dev.rgb = { wire = wire, zones = count, static_slots = static_slots, led_ids = led_ids }
        result.zones = {}
        if #led_ids > 0 and count == 1 then
          result.zones[1] = { id = "zone_0", name = profile.zone_name or "Lighting",
            topology = profile.topology or "linear", led_count = #led_ids, led_ids = led_ids,
            keyboard_form_factor = profile.topology == "keyboard" and "t_k_l" or nil,
            keyboard_layout = layout }
        else
          for zone = 0, count - 1 do result.zones[#result.zones + 1] = {
            id = "zone_" .. zone, name = "Zone " .. (zone + 1), topology = "linear", led_count = 1 } end
        end
        result.native_effects = select_native_effects(profile)
        feature(dev, RGB_EFFECTS, 0x50, bytes(1, 1))
        capability("rgb")
      end
    elseif has(features, COLOR_LED_EFFECTS) then
      local count = request(dev, devnum, features[COLOR_LED_EFFECTS], 0x00):byte(1) or 0
      if count > 0 then
        local zones, static_slots = color_led_zones(dev, features[COLOR_LED_EFFECTS], count)
        dev.rgb = { wire = "color_led", zones = count, static_slots = static_slots, led_ids = {} }
        result.zones = zones
        feature(dev, COLOR_LED_EFFECTS, 0x80, bytes(1))
        capability("rgb")
      end
    elseif has(features, PER_KEY_LIGHTING_V2) then
      local led_ids = discover_per_key_ids(dev, features[PER_KEY_LIGHTING_V2], profile.led_order)
      if #led_ids > 0 then
        dev.rgb = { wire = "per_key", zones = 1, static_slots = { 0 }, led_ids = led_ids }
        result.zones = {{ id = "zone_0", name = profile.zone_name or "Lighting",
          topology = profile.topology or "linear", led_count = #led_ids, led_ids = led_ids,
          keyboard_form_factor = profile.topology == "keyboard" and "t_k_l" or nil,
          keyboard_layout = layout }}
        result.native_effects = select_native_effects(profile)
        capability("rgb")
      end
    end
    if has(features, SIDETONE) then
      local level = feature(dev, SIDETONE, 0x00):byte(1) or 0
      result.controls.ranges[#result.controls.ranges + 1] = {
        key = "sidetone", label = "Sidetone", min = 0, max = 100, step = 1, default = level, category = "Audio"
      }
      result.ranges = result.ranges or {}; result.ranges.sidetone = level
    end
    if has(features, EQUALIZER) then equalizer_read(dev); capability("equalizer") end
    if has(features, HIRES_WHEEL) then
      local caps = feature(dev, HIRES_WHEEL, 0x00)
      local mode = feature(dev, HIRES_WHEEL, 0x10):byte(1) or 0
      feature(dev, HIRES_WHEEL, 0x30) -- retain native capability probe ordering
      dev.hires = { has_invert = ((caps:byte(2) or 0) & 0x08) ~= 0 }
      if dev.hires.has_invert then result.controls.booleans[#result.controls.booleans + 1] = {
        key = "hires_invert", label = "Scroll Wheel Direction", category = "Scroll Wheel" } end
      result.controls.booleans[#result.controls.booleans + 1] = {
        key = "hires_resolution", label = "Scroll Wheel Resolution", category = "Scroll Wheel" }
      result.controls.booleans[#result.controls.booleans + 1] = {
        key = "hires_diversion", label = "Scroll Wheel Diversion", category = "Scroll Wheel" }
      dev.hires.mode = mode
    end
    if has(features, K375S_FN_INVERSION) then
      local current = feature(dev, K375S_FN_INVERSION, 0x00)
      local fs_version = request(dev, devnum, features[FEATURE_SET], 0x10,
        bytes(features[K375S_FN_INVERSION])):byte(4) or 1
      dev.fn_inversion = { value = ((current:byte(1) or 0) & 1) ~= 0,
        writeable = fs_version >= 2 }
      result.controls.booleans[#result.controls.booleans + 1] = {
        key = "fn_inversion", label = "Swap Fx Function", category = "Keyboard",
        read_only = not dev.fn_inversion.writeable
      }
    end
    if has(features, BRIGHTNESS_CONTROL) then
      local info = feature(dev, BRIGHTNESS_CONTROL, 0x00)
      local max = #info >= 2 and ((info:byte(1) << 8) | info:byte(2)) or 100
      local min = #info >= 6 and ((info:byte(5) << 8) | info:byte(6)) or 0
      local level_reply = feature(dev, BRIGHTNESS_CONTROL, 0x10)
      local level = #level_reply >= 2 and ((level_reply:byte(1) << 8) | level_reply:byte(2)) or max
      local has_on_off = ((info:byte(4) or 0) & 0x04) ~= 0
      dev.brightness = { has_on_off = has_on_off }
      result.controls.ranges[#result.controls.ranges + 1] = {
        key = "brightness", label = "Brightness", min = min, max = max, step = 1, default = level, category = "Lighting"
      }
      result.ranges = result.ranges or {}; result.ranges.brightness = level
      if has_on_off then
        dev.brightness.on = ((feature(dev, BRIGHTNESS_CONTROL, 0x30):byte(1) or 0) & 1) ~= 0
        result.controls.booleans[#result.controls.booleans + 1] = {
          key = "brightness_on", label = "Keyboard Brightness", category = "Keyboard" }
      end
    end
    if has(features, UNIFIED_BATTERY) or has(features, ADC_MEASUREMENT) or has(features, BATTERY_VOLTAGE) then
      capability("battery")
    end
    if dev.match.key or profile.wireless or has(features, WIRELESS_DEVICE_STATUS) then
      capability("connection")
    end
    if #result.controls.ranges > 0 or #result.controls.choices > 0
        or #result.controls.booleans > 0 or #result.controls.actions > 0 then
      capability("controls")
    end
    return result
  end,

  -- Exported callbacks deliberately use the same feature helper, so packet
  -- framing remains protocol-correct as each former native feature is ported.
  get_batteries = function(dev)
    local ok, level, charging = pcall(battery_reading, dev)
    if not ok or not level then return {} end
    return {{ key = "battery", label = "Battery", level = level,
      status = charging and "charging" or "discharging" }}
  end,
  connection_status = function(dev)
    -- A receiver child is necessarily reached through the wireless receiver.
    -- Direct HID++ collections are not claimed as wireless merely because a
    -- product also has a wireless SKU; that is the native transport policy.
    if dev.match.key then return { connection_type = "wireless" } end
    if (dev.profile and dev.profile.wireless)
        or (dev.hidpp and dev.hidpp.features[WIRELESS_DEVICE_STATUS]) then
      return { connection_type = "wired" }
    end
    return nil
  end,
  on_event = function(dev, event)
    if event.transport ~= "hid" then return nil end
    local report_devnum, sub = event.report:byte(2), event.report:byte(3)
    if dev.match.pid == 0xc547 and not dev.match.key then
      if sub == 0x4a then
        local open = ((event.report:byte(4) or 0) & 0x01) ~= 0
        local code = event.report:byte(5) or 0
        if open then
          dev.pairing_state, dev.pairing_error = "listening", nil
          return { state_changed = true }
        elseif code == 0 then
          v1_write(dev, DIRECT, 0x0002, bytes(0x02))
          dev.pairing_state, dev.pairing_error = "paired", nil
          return { state_changed = true, children_changed = true }
        else
          local errors = {
            [1] = "no device found before the pairing window closed",
            [2] = "pairing is not supported by this receiver",
            [3] = "no free pairing slot on the receiver",
            [6] = "the pairing sequence timed out",
          }
          dev.pairing_state = "error"
          dev.pairing_error = errors[code] or string.format("pairing failed (0x%02x)", code)
          return { state_changed = true }
        end
      elseif sub == 0x41 then
        if dev.pairing_state == "listening" then
          dev.pairing_state, dev.pairing_error = "paired", nil
        end
        return { state_changed = true, children_changed = true }
      end
    end
    if dev.onboard and report_devnum == dev.hidpp.devnum
        and sub == dev.hidpp.features[ONBOARD_PROFILES] then
      local ok = pcall(refresh_onboard, dev)
      if ok then return { state_changed = true } end
    end
    local buttons = button_events(dev, event.report)
    if not buttons then return nil end
    return { button_events = buttons }
  end,
  set_dpi = function(dev, dpi)
    local index = dev.hidpp and dev.hidpp.features[ADJUSTABLE_DPI]
    if not index then error("ADJUSTABLE_DPI unavailable") end
    if dev.onboard and onboard_mode(dev) ~= 2 then
      local state = refresh_onboard(dev)
      local sector = state.active_sector >= 0x0100 and (state.active_sector & 0xff)
        or state.active_sector
      if sector == 0 then error("no active onboard profile") end
      local data = read_sector(dev, sector, state.sector_size)
      local steps, selected = sector_dpi_steps(data), nil
      for i, value in ipairs(steps) do if value == dpi then selected = i - 1; break end end
      if selected == nil then
        selected = math.min(data:byte(2) or 0, math.max(0, #steps - 1))
        steps[selected + 1] = dpi
      end
      local patched = patch_sector_dpi(data, state.sector_size, steps)
      local values = { patched:byte(1, state.sector_size) }
      values[2] = selected
      write_sector(dev, sector, with_sector_crc(bytes(table.unpack(values)), state.sector_size))
      refresh_onboard(dev); restore_rgb_control(dev)
      dev.current_dpi = dpi
      return
    end
    request(dev, dev.hidpp.devnum, index, 0x30, bytes(0, (dpi >> 8) & 0xff, dpi & 0xff))
    dev.current_dpi = dpi
  end,
  set_dpi_steps = function(dev, steps)
    if #steps == 0 then error("DPI steps list cannot be empty") end
    if not dev.onboard or onboard_mode(dev) == 2 then
      dev.software_dpi_steps = { table.unpack(steps) }
      return
    end
    local state = refresh_onboard(dev)
    local sector = state.active_sector >= 0x0100 and (state.active_sector & 0xff)
      or state.active_sector
    if sector == 0 then error("no active onboard profile") end
    local data = read_sector(dev, sector, state.sector_size)
    write_sector(dev, sector, patch_sector_dpi(data, state.sector_size, steps))
    refresh_onboard(dev)
    restore_rgb_control(dev)
  end,
  dpi_status = function(dev)
    if not dev.available_dpis then return nil end
    local onboard = dev.onboard and onboard_mode(dev) ~= 2
    local steps = onboard and dev.onboard.profile_steps or dev.software_dpi_steps
    if not steps or #steps == 0 then steps = dev.available_dpis end
    local current = dev.current_dpi
    if onboard and dev.onboard.profile_data then
      current = steps[(dev.onboard.profile_data:byte(2) or 0) + 1] or current
    end
    return { min = dev.available_dpis[1] or current or 100,
      max = dev.available_dpis[#dev.available_dpis] or current or 25600,
      steps = steps, available_dpis = dev.available_dpis, onboard = onboard,
      mode_control = dev.onboard and "host_mode" or nil, current = current }
  end,
  read_status = function(_dev) return {} end,
  key_remap_host_mode = function(dev)
    return true
  end,
  onboard_profiles_status = onboard_status,
  switch_profile = function(dev, slot)
    local state = refresh_onboard(dev)
    if state.mode == 2 then error("device is in host mode; switch to onboard mode first") end
    local enabled = false
    for _, entry in ipairs(state.directory) do
      if (entry.sector & 0xff) == slot then enabled = entry.enabled; break end
    end
    if not enabled then error("profile slot is not enabled") end
    feature(dev, ONBOARD_PROFILES, 0x30, bytes(0, slot, 0))
    refresh_onboard(dev)
  end,
  restore_profile = function(dev, slot)
    local state = refresh_onboard(dev)
    if slot > state.rom_count then error("profile has no factory default") end
    restore_profile(dev, slot, false)
    refresh_onboard(dev); restore_rgb_control(dev)
  end,
  set_profile_enabled = function(dev, slot, enabled)
    local state = refresh_onboard(dev)
    if enabled then restore_profile(dev, slot, true) end
    state = refresh_onboard(dev)
    local values = { state.directory_data:byte(1, state.sector_size) }
    local found = false
    for _, entry in ipairs(state.directory) do
      if (entry.sector & 0xff) == slot then
        values[entry.offset + 2] = enabled and 1 or 0; found = true; break
      end
    end
    if not found then error("profile slot not present in directory") end
    local data = with_sector_crc(bytes(table.unpack(values)), state.sector_size)
    write_sector(dev, 0, data)
    refresh_onboard(dev); restore_rgb_control(dev)
  end,
  set_button_mapping = function(dev, mapping)
    set_remap_active(dev, mapping.cid, not mapping_is_native(mapping))
  end,
  reset_button_mapping = function(dev, cid)
    set_remap_active(dev, cid, false)
  end,
  reset_all_button_mappings = function(dev)
    local remap = dev.remap
    if not remap then return end
    local active = {}; for cid in pairs(remap.active) do active[#active + 1] = cid end
    for _, cid in ipairs(active) do set_remap_active(dev, cid, false) end
  end,
  set_range = function(dev, key, value)
    if key == "sidetone" then
      feature(dev, SIDETONE, 0x10, bytes(math.max(0, math.min(100, value))))
    elseif key == "brightness" then
      local level = math.max(0, math.min(0xffff, value))
      feature(dev, BRIGHTNESS_CONTROL, 0x20, bytes((level >> 8) & 0xff, level & 0xff))
    else
      error("unknown range control: " .. key)
    end
  end,
  set_boolean = function(dev, key, value)
    if key == "host_mode" then
      if not dev.onboard then error("ONBOARD_PROFILES unavailable") end
      set_onboard_mode(dev, value)
    elseif key == "hires_invert" or key == "hires_resolution" or key == "hires_diversion" then
      local current = feature(dev, HIRES_WHEEL, 0x10):byte(1) or 0
      local mask = key == "hires_invert" and 0x04 or key == "hires_resolution" and 0x02 or 0x01
      local mode = value and (current | mask) or (current & (~mask))
      feature(dev, HIRES_WHEEL, 0x20, bytes(mode, 0))
      dev.hires.mode = mode
    elseif key == "fn_inversion" then
      if not dev.fn_inversion or not dev.fn_inversion.writeable then error("Fn inversion is read-only") end
      feature(dev, K375S_FN_INVERSION, 0x10, bytes(value and 1 or 0))
      dev.fn_inversion.value = value
    elseif key == "brightness_on" then
      if not dev.brightness or not dev.brightness.has_on_off then error("brightness on/off unavailable") end
      feature(dev, BRIGHTNESS_CONTROL, 0x40, bytes(value and 1 or 0))
      dev.brightness.on = value
    else
      error("unknown boolean control: " .. key)
    end
  end,
  get_booleans = function(dev)
    local out = {}
    if dev.onboard then out[#out + 1] = { key = "host_mode", value = onboard_mode(dev) == 2 } end
    if dev.hires then
      local current = feature(dev, HIRES_WHEEL, 0x10):byte(1) or dev.hires.mode or 0
      dev.hires.mode = current
      if dev.hires.has_invert then out[#out + 1] = {
        key = "hires_invert", value = (current & 0x04) ~= 0 } end
      out[#out + 1] = { key = "hires_resolution", value = (current & 0x02) ~= 0 }
      out[#out + 1] = { key = "hires_diversion", value = (current & 0x01) ~= 0 }
    end
    if dev.fn_inversion then
      local current = feature(dev, K375S_FN_INVERSION, 0x00):byte(1) or 0
      dev.fn_inversion.value = (current & 1) ~= 0
      out[#out + 1] = { key = "fn_inversion", value = dev.fn_inversion.value }
    end
    if dev.brightness and dev.brightness.has_on_off then
      dev.brightness.on = ((feature(dev, BRIGHTNESS_CONTROL, 0x30):byte(1) or 0) & 1) ~= 0
      out[#out + 1] = { key = "brightness_on", value = dev.brightness.on }
    end
    return out
  end,
  set_choice = function(dev, key, selected)
    if key ~= "report_rate" then error("unknown choice control: " .. key) end
    local rates = assert(dev.report_rates, "REPORT_RATE unavailable")
    local option = assert(rates.options[selected + 1], "report-rate selection out of range")
    local was_host = not dev.onboard or onboard_mode(dev) == 2
    if dev.onboard and not was_host then set_onboard_mode(dev, true) end
    local ok, err = pcall(request, dev, dev.hidpp.devnum, rates.index,
      rates.ext and 0x30 or 0x20, bytes(option.wire))
    if dev.onboard and not was_host then set_onboard_mode(dev, false); restore_rgb_control(dev) end
    if not ok then error(err) end
    rates.current = option.wire
  end,
  get_equalizer = function(dev)
    return (dev.equalizer and dev.equalizer.result) or equalizer_read(dev) or error("EQUALIZER unavailable")
  end,
  set_eq_preset = function(dev, preset)
    if preset ~= 0 then error("Logitech EQUALIZER has only the custom preset") end
  end,
  set_eq_bands = function(dev, values)
    local eq = dev.equalizer or equalizer_read(dev)
    if not eq then error("EQUALIZER unavailable") end
    if #values ~= eq.count then error("expected " .. eq.count .. " EQ band values") end
    local out = { 0x02 }
    for i = 1, eq.count do
      local v = math.max(eq.min, math.min(eq.max, math.floor(values[i] + 0.5)))
      out[#out + 1] = v & 0xff
      eq.result.bands[i].value = v
    end
    feature(dev, EQUALIZER, 0x30, bytes(table.unpack(out)))
  end,
  apply = function(dev, state)
    if state.mode == "native_effect" then
      if dev.rgb and dev.hidpp.features[RGB_EFFECTS] then
        -- Match the native driver: every explicit state apply reclaims LED
        -- control. Onboard mode, reconnects, and prior effects can make the
        -- firmware silently ignore otherwise-valid per-key packets.
        pcall(restore_rgb_control, dev)
        local allowed = false
        for _, id in ipairs((dev.profile and dev.profile.native_effects) or {}) do
          if id == state.id then allowed = true; break end
        end
        if not allowed then error("native effect is not supported by this device") end
        apply_native_effect(dev, state.id, state.params or {})
      end
      return
    end
    if not dev.rgb then return end
    pcall(restore_rgb_control, dev)
    if state.mode == "per_led" then
      if dev.rgb.wire == "per_key" then
        write_per_key_pairs(dev, state.zones)
      else
        for zone_id, led_colors in pairs(state.zones or {}) do
          local _, color = next(led_colors)
          if color then write_rgb_zone(dev, zone_id, { color }) end
        end
      end
      return
    end
    if state.mode ~= "static" then return end
    local color = state.color or { r = 0, g = 0, b = 0 }
    if dev.rgb.wire == "per_key" then
      local colors = {}; for _ = 1, #dev.rgb.led_ids do colors[#colors + 1] = color end
      write_per_key_frame(dev, colors)
    else
      for zone = 0, dev.rgb.zones - 1 do write_rgb_zone(dev, "zone_" .. zone, { color }) end
    end
  end,
  write_frame = function(dev, zone_id, colors)
    write_rgb_zone(dev, zone_id, colors)
  end,
  write_frame_batch = function(dev, frames)
    for _, frame in ipairs(frames) do write_rgb_zone(dev, frame.zone_id, frame.colors) end
  end,
  close = function(_dev) end,
}
