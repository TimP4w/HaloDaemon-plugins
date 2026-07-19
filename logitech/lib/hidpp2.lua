-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: 2012-2013 Daniel Pavel
-- SPDX-FileCopyrightText: 2014-2024 Solaar Contributors <https://pwr-solaar.github.io/Solaar/>
--
-- Logitech HID++ 2.0.  The framing and feature enumeration below are derived
-- from Solaar's HID++ implementation.  Keep this protocol layer in one place:
-- device feature callbacks must only call `feature()` and never assemble an
-- ad-hoc report.

return function(hidpp1_factory)

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
      elseif rsub == sub and (not check_func or reply:byte(4) == address) then
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
local hidpp1 = hidpp1_factory({
  bytes = bytes, packet = packet, send = send, dispatch = dispatch,
})
local v1_read, v1_write = hidpp1.read, hidpp1.write

local product_name

-- Receiver identity is transport metadata, not a special case of one device
-- PID. Keep the Solaar-compatible HID++ 1.x families here; Bolt and the old
-- EX100 use protocols this plugin does not implement.
local RECEIVERS = {
  [0xc52b] = { name = "Logitech Unifying Receiver", max_slots = 6 },
  [0xc532] = { name = "Logitech Unifying Receiver", max_slots = 6 },
  [0xc518] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc51a] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc51b] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc521] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc525] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc526] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc52e] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc52f] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc531] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc534] = { name = "Logitech Nano Receiver", max_slots = 2 },
  [0xc535] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc537] = { name = "Logitech Nano Receiver", max_slots = 6 },
  [0xc539] = { name = "Logitech LIGHTSPEED Receiver", max_slots = 6 },
  [0xc53a] = { name = "Logitech LIGHTSPEED Receiver", max_slots = 6 },
  [0xc53d] = { name = "Logitech LIGHTSPEED Receiver", max_slots = 6 },
  [0xc53f] = { name = "Logitech LIGHTSPEED Receiver", max_slots = 6 },
  [0xc541] = { name = "Logitech LIGHTSPEED Receiver", max_slots = 6 },
  [0xc545] = { name = "Logitech LIGHTSPEED Receiver", max_slots = 6 },
  [0xc547] = { name = "Logitech LIGHTSPEED Receiver", max_slots = 6 },
  [0xc54d] = { name = "Logitech LIGHTSPEED Receiver", max_slots = 6 },
}

local function paired_device_type(kind, wpid)
  local kinds = {
    [1] = "keyboard", [2] = "mouse", [3] = "keyboard", [0x0d] = "headset",
  }
  if kind then
    local resolved = kinds[kind & 0x0f]
    if resolved then return resolved end
  end
  if wpid == 0x4099 then return "mouse" end
  if wpid == 0x40b0 then return "keyboard" end
  return "other"
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

local function enumerate_features_with_retry(dev, devnum)
  local last_error
  -- A cold direct device can take longer than one transport window to
  -- answer its first ROOT request. Retrying the same request is safe: HID++
  -- replies carry the same devnum, feature index, function, and software id,
  -- so a late response from the prior attempt satisfies this attempt too.
  for _ = 1, 3 do
    local ok, value = pcall(enumerate_features, dev, devnum)
    if ok then return value end
    last_error = value
    if not tostring(value):find("HID++ response did not arrive", 1, true) then
      error(value)
    end
  end
  error(last_error or "HID++ feature discovery failed")
end

local function read_name(dev, devnum, features)
  local index = features[DEVICE_FRIENDLY_NAME] or features[DEVICE_NAME]
  local echoes_offset = features[DEVICE_FRIENDLY_NAME] ~= nil
  if not index then return nil end
  local length = request(dev, devnum, index, 0x00):byte(1) or 0
  if length == 0 then return nil end
  local out, offset = {}, 0
  while offset < length do
    local chunk = request(dev, devnum, index, 0x10, bytes(offset))
    if echoes_offset then chunk = chunk:sub(2) end
    chunk = chunk:sub(1, length - offset)
    if #chunk == 0 then break end
    out[#out + 1], offset = chunk, offset + #chunk
  end
  local name = table.concat(out):gsub("%z.*", "")
  return #name > 0 and name or nil
end

product_name = function(pid, wpid)
  local names = {
    [0xc095] = "Logitech G502 X Plus", [0xc08b] = "Logitech G502 Hero",
    [0xc352] = "Logitech G PRO X TKL",
    [0x0aba] = "Logitech PRO X Wireless Gaming Headset",
    [0x0af7] = "Logitech PRO X 2 LIGHTSPEED",
    [0x0ab5] = "Logitech G733 LIGHTSPEED", [0x0afe] = "Logitech G733 LIGHTSPEED",
    [0x0ac4] = "Logitech G535 LIGHTSPEED", [0x0a87] = "Logitech G935",
    [0x0a66] = "Logitech G533",
  }
  local wireless = { [0x4099] = "Logitech G502 X Plus", [0x40b0] = "Logitech G PRO X TKL" }
  return names[pid] or (RECEIVERS[pid] and RECEIVERS[pid].name)
    or wireless[wpid] or "Logitech HID++ Device"
end

local function receiver_children(dev)
  return hidpp1.receiver_children(dev, product_name, paired_device_type)
end

local profiles = halod.require("lib.hidpp2.profiles")(product_name)
local device_profile = profiles.device_profile
local gpro_tkl_keyboard = profiles.gpro_tkl_keyboard
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
    local terminated = false
    for i = 1, #payload - 1, 2 do
      if payload:byte(i) == 0 and payload:byte(i + 1) == 0 then terminated = true; break end
    end
    if terminated then break end
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

local lighting = halod.require("lib.hidpp2.lighting")({
  bytes = bytes, packet = packet, request = request, feature = feature,
  send_feature_packets = send_feature_packets, sw_id = SW_ID,
  rgb_effects = RGB_EFFECTS, color_led_effects = COLOR_LED_EFFECTS,
  per_key_lighting_v2 = PER_KEY_LIGHTING_V2,
})
local select_native_effects = lighting.select_native_effects
local apply_native_effect = lighting.apply_native_effect
local discover_per_key_ids = lighting.discover_per_key_ids
local rgb_static_slots = lighting.rgb_static_slots
local color_led_zones = lighting.color_led_zones
local write_per_key_frame = lighting.write_per_key_frame
local write_per_key_pairs = lighting.write_per_key_pairs
local write_rgb_zone = lighting.write_rgb_zone
local restore_rgb_control = lighting.restore_rgb_control
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

local onboard = halod.require("lib.hidpp2.onboard")({
  bytes = bytes, feature = feature, feature_id = ONBOARD_PROFILES,
  restore_rgb_control = restore_rgb_control,
})
local onboard_mode = onboard.mode
local set_onboard_mode = onboard.set_mode
local with_sector_crc = onboard.with_sector_crc
local read_sector = onboard.read_sector
local write_sector = onboard.write_sector
local sector_dpi_steps = onboard.sector_dpi_steps
local patch_sector_dpi = onboard.patch_sector_dpi
local refresh_onboard = onboard.refresh
local onboard_status = onboard.status
local restore_profile = onboard.restore_profile
local remap = halod.require("lib.hidpp2.remap")({
  bytes = bytes, request = request, feature = feature, direct = DIRECT,
  device_profile = device_profile,
  reprog_controls_v4 = REPROG_CONTROLS_V4, gkey = GKEY,
  mouse_button_spy = MOUSE_BUTTON_SPY,
})
local mapping_is_native = remap.mapping_is_native
local remap_buttons = remap.buttons
local set_remap_active = remap.set_active
local button_events = remap.events
local callbacks = {
  event_source = function(event)
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
  enumerate_controllers = function(dev)
    local children = receiver_children(dev)
    -- Pairing status is serialized for every GUI state frame. Keep the result
    -- of the explicit discovery/reconciliation pass so serialization does not
    -- re-enumerate the receiver over HID on the shared RGB/event worker.
    dev.pairing_children = children
    return children
  end,
  start_pairing = function(dev, timeout_secs)
    if not dev.receiver then error("pairing is receiver-only") end
    v1_write(dev, DIRECT, 0x00b2, bytes(0x01, 0, math.min(255, timeout_secs)))
    dev.pairing_state, dev.pairing_error = "listening", nil
  end,
  stop_pairing = function(dev)
    if not dev.receiver then error("pairing is receiver-only") end
    v1_write(dev, DIRECT, 0x00b2, bytes(0x02, 0, 0))
    dev.pairing_state, dev.pairing_error = "idle", nil
  end,
  unpair = function(dev, slot)
    if not dev.receiver then error("pairing is receiver-only") end
    v1_write(dev, DIRECT, 0x00b2, bytes(0x03, slot))
    dev.pairing_state = "idle"
    if dev.pairing_children then
      local remaining = {}
      for _, child in ipairs(dev.pairing_children) do
        if child.index ~= slot then remaining[#remaining + 1] = child end
      end
      dev.pairing_children = remaining
    end
  end,
  pairing_status = function(dev)
    if not dev.receiver then error("pairing is receiver-only") end
    local children = dev.pairing_children or {}
    local slots = {}
    for _, child in ipairs(children) do
      slots[#slots + 1] = { slot = child.index, device_id = child.id, name = child.name, connected = true }
    end
    return { state = dev.pairing_state or "idle", error = dev.pairing_error,
      max_slots = dev.receiver.max_slots, slots = slots }
  end,
  initialize = function(dev)
    -- Direct USB devices use 0xff. Receiver children are added through the
    -- controller-discovery path and carry their paired slot in dev.match.index.
    -- A receiver is only the transport root; paired slot children are the
    -- actual devices. Direct devices retain 0xff.
    dev.receiver = not dev.match.key and RECEIVERS[dev.match.pid] or nil
    if dev.receiver then
      return { ok = true, model = product_name(dev.match.pid), capabilities = { "pairing" } }
    end
    local devnum = tonumber(dev.match.key) or dev.match.index or DIRECT
    local features = enumerate_features_with_retry(dev, devnum)
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
      local exposed, defaults = {}, {}
      for _, button in ipairs(buttons) do exposed[button.cid] = true end
      for _, mapping in ipairs(profile.defaults or {}) do
        if exposed[mapping.cid] then defaults[#defaults + 1] = mapping end
      end
      -- Firmware ignores per-control divert while a mouse is in onboard mode;
      -- remap only takes effect in host mode. See docs/hidpp2.md.
      result.key_remap = { buttons = buttons, requires_host_mode = dev.onboard ~= nil,
        default_mappings = defaults }
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
        local wire = #led_ids > 0 and count == 1 and "per_key" or "rgb_effects"
        dev.lighting = { wire = wire, channels = count, static_slots = static_slots, led_ids = led_ids }
        result.channels = {}
        if #led_ids > 0 and count == 1 then
          result.channels[1] = { id = "zone_0", name = profile.zone_name or "Lighting",
            topology = profile.topology or "linear", led_count = #led_ids, led_ids = led_ids,
            keyboard_form_factor = profile.topology == "keyboard" and "t_k_l" or nil,
            keyboard_layout = layout }
        else
          for zone = 0, count - 1 do result.channels[#result.channels + 1] = {
            id = "zone_" .. zone, name = "Zone " .. (zone + 1), topology = "linear", led_count = 1 } end
        end
        result.native_effects = select_native_effects(profile)
        feature(dev, RGB_EFFECTS, 0x50, bytes(1, 1))
        capability("lighting")
      end
    elseif has(features, COLOR_LED_EFFECTS) then
      local count = request(dev, devnum, features[COLOR_LED_EFFECTS], 0x00):byte(1) or 0
      if count > 0 then
        local channels, static_slots = color_led_zones(dev, features[COLOR_LED_EFFECTS], count)
        dev.lighting = { wire = "color_led", channels = count, static_slots = static_slots, led_ids = {} }
        result.channels = channels
        feature(dev, COLOR_LED_EFFECTS, 0x80, bytes(1))
        capability("lighting")
      end
    elseif has(features, PER_KEY_LIGHTING_V2) then
      local led_ids = discover_per_key_ids(dev, features[PER_KEY_LIGHTING_V2], profile.led_order)
      if #led_ids > 0 then
        dev.lighting = { wire = "per_key", channels = 1, static_slots = { 0 }, led_ids = led_ids }
        result.channels = {{ id = "zone_0", name = profile.zone_name or "Lighting",
          topology = profile.topology or "linear", led_count = #led_ids, led_ids = led_ids,
          keyboard_form_factor = profile.topology == "keyboard" and "t_k_l" or nil,
          keyboard_layout = layout }}
        result.native_effects = select_native_effects(profile)
        capability("lighting")
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
  event = function(dev, event)
    if event.transport ~= "hid" then return nil end
    local report_devnum, sub = event.report:byte(2), event.report:byte(3)
    if dev.receiver then
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
    return not dev.onboard or dev.onboard.mode == 2
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
    local found = false
    for _, entry in ipairs(state.directory) do
      if (entry.sector & 0xff) == slot then found = true; break end
    end
    if not found then error("profile slot not present in directory") end
    if enabled then restore_profile(dev, slot, true) end
    state = refresh_onboard(dev)
    local values = { state.directory_data:byte(1, state.sector_size) }
    found = false
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
    local applied = {}
    for i = 1, eq.count do
      local v = math.max(eq.min, math.min(eq.max, math.floor(values[i] + 0.5)))
      out[#out + 1] = v & 0xff
      applied[i] = v
    end
    feature(dev, EQUALIZER, 0x30, bytes(table.unpack(out)))
    for i = 1, eq.count do eq.result.bands[i].value = applied[i] end
  end,
  apply = function(dev, state)
    if state.mode == "native_effect" then
      if dev.lighting and dev.hidpp.features[RGB_EFFECTS] then
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
    if not dev.lighting then return end
    pcall(restore_rgb_control, dev)
    if state.mode == "per_led" then
      if dev.lighting.wire == "per_key" then
        write_per_key_pairs(dev, state.channels)
      else
        for zone_id, led_colors in pairs(state.channels or {}) do
          local _, color = next(led_colors)
          if color then write_rgb_zone(dev, zone_id, { color }) end
        end
      end
      return
    end
    if state.mode ~= "static" then return end
    local color = state.color or { r = 0, g = 0, b = 0 }
    if dev.lighting.wire == "per_key" then
      local colors = {}; for _ = 1, #dev.lighting.led_ids do colors[#colors + 1] = color end
      write_per_key_frame(dev, colors)
    else
      for zone = 0, dev.lighting.channels - 1 do write_rgb_zone(dev, "zone_" .. zone, { color }) end
    end
  end,
  write_frame = function(dev, zone_id, bytes, led_ids)
  local colors = {}
  for i = 1, #bytes, 3 do colors[#colors + 1] = { r = bytes[i] or 0, g = bytes[i + 1] or 0, b = bytes[i + 2] or 0 } end
    write_rgb_zone(dev, zone_id, colors, led_ids)
  end,
  close = function(_dev) end,
}

-- A powered-off device stays enumerated through its dongle. Linux may answer
-- ROOT from cache and fail on a later request; Windows can reject the first
-- write before HID++ receives the packet.
local describe_device = callbacks.initialize
callbacks.initialize = function(dev)
  local ok, result = pcall(describe_device, dev)
  if ok then return result end
  local text = tostring(result)
  local unavailable = text:find("HID++ error response", 1, true)
      or text:find("HID++ response did not arrive", 1, true)
      or (is_long_only(dev.match.pid)
        and text:find("HID write error", 1, true))
  if not unavailable then
    error(result)
  end
  log("logitech: device is not powered on: " .. text, "trace")
  return { ok = false }
end

return callbacks
end
