-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: linux-arctis-manager contributors <https://github.com/elegos/Linux-Arctis-Manager>
--
-- SteelSeries Arctis Nova Pro Wireless (+ Wireless X) plugin for HaloDaemon.
-- A 64-byte report-ID-prefixed HID command/notification protocol on interface 4,
-- polled at 250 ms with a persist-after-write commit. Exposes battery, mic
-- controls, noise-cancelling, wireless/base-station settings, and a 10-band EQ.
--
-- Protocol reference: steelseries_arctis/docs/protocol.md, ported from the
-- linux-arctis-manager project (GPL-3.0) and sennheiser-gsx-control (MIT).
--
-- ChatMix: the base station streams a game/chat balance on the 0x45 dial. Two
-- virtual audio sinks (Media + Chat) are created via `dev.audio` and looped into
-- the headset's physical sink; the dial then balances their volumes. The host
-- tears the sinks down when the device closes.

local PACKET = 64

-- Report IDs (packet byte 0).
local REPORT_CMD = 0x06 -- host→device command and its reply
local REPORT_NOTIFY = 0x07 -- unsolicited device→host notification

-- Message IDs (packet byte 1).
local MSG_PERSIST = 0x09
local MSG_SETTINGS = 0x20
local MSG_VOLUME = 0x25
local MSG_MIC_GAIN = 0x27
local MSG_EQ_PRESET = 0x2e
local MSG_EQ_BANDS = 0x33
local MSG_MIC_VOLUME = 0x37
local MSG_SIDETONE = 0x39
local MSG_CHATMIX = 0x45
local MSG_CHATMIX_SET = 0x47
local MSG_CHATMIX_DISPLAY = 0x49
local MSG_SCREEN_MODE = 0x89
local MSG_SONAR_EQ = 0x8d
local MSG_STATUS = 0xb0
local MSG_NC_LEVEL = 0xb9
local MSG_NC_MODE = 0xbd
local MSG_MIC_LED = 0xbf
local MSG_AUTO_OFF = 0xc1
local MSG_WIRELESS_MODE = 0xc3

-- Power status (status byte 0x0F).
local POWER_OFFLINE = 0x01
local POWER_CHARGING = 0x02
local POWER_ONLINE = 0x08

local MAX_POLL_READS = 32 -- packets drained per poll pass (see protocol §5)
local POLL_REPLY_DELAY_MS = 50 -- let requested status packets reach the HID queue
local EQ_BASELINE = 20 -- raw 0x14 = 0 dB
local EQ_CUSTOM_BYTE = 0x04 -- the single editable preset

-- The X base stations expose the Bluetooth status block; the plain one doesn't.
local function is_bt_variant(dev)
  local pid = dev.match and dev.match.pid
  return pid == 0x12e5 or pid == 0x225d
end

local EQ_BAND_LABELS = {
  "31 Hz", "62 Hz", "125 Hz", "250 Hz", "500 Hz",
  "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz",
}

-- Preset byte, label, and info-curve bands (empty = no curve; Custom is editable).
-- Bytes are non-contiguous, so the dropdown position is decoupled from the wire
-- value; an uncatalogued byte falls back to the Custom slot.
local EQ_PRESETS = {
  { byte = 0x00, name = "Flat", bands = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
  { byte = 0x01, name = "Bass Boost", bands = { 3.5, 5.5, 4.0, 1.0, -1.5, -1.5, -1.0, -1.0, -1.0, -1.0 } },
  { byte = 0x02, name = "Focus", bands = { -5.0, -3.5, -1.0, -3.5, -2.5, 4.0, 6.0, 3.5, -3.5, 0.0 } },
  { byte = 0x03, name = "Smiley", bands = { 3.0, 3.5, 1.5, -1.5, -4.0, -4.0, -2.5, 1.5, 3.0, 4.0 } },
  { byte = 0x04, name = "Custom", bands = {} },
  { byte = 0x05, name = "Apex Legends", bands = { -10.0, -6.0, 6.0, 0.0, 0.0, 4.0, 0.0, 6.5, 9.5, 4.0 } },
  { byte = 0x07, name = "Call of Duty: MWII", bands = { 0.0, 1.5, 6.0, 2.5, 0.0, 0.0, 2.0, 1.0, 6.0, 4.0 } },
  { byte = 0x08, name = "Call of Duty: Warzone", bands = { -10.0, -3.0, 6.0, 0.0, 2.5, 2.0, 1.5, 1.0, 4.0, 1.5 } },
  { byte = 0x0c, name = "FPS Footsteps", bands = { -10.0, -2.0, 5.0, 4.0, 0.0, -1.5, -1.5, 1.5, 3.0, 1.5 } },
  { byte = 0x0d, name = "GTA V", bands = { 3.0, 7.5, 6.0, -1.5, 0.0, 1.0, 1.5, 2.5, 3.0, 3.0 } },
  { byte = 0x0f, name = "Overwatch 2", bands = { -6.0, -4.0, 1.0, -2.0, -1.0, 0.0, 0.0, 0.0, 3.0, 6.0 } },
  { byte = 0x10, name = "PUBG", bands = { -10.0, -6.0, -1.0, 0.0, 2.0, 5.0, 2.5, -4.0, 3.5, 1.5 } },
}

-- ── helpers ──────────────────────────────────────────────────────────────────

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

-- On Linux hidapi prepends a 0x00 report-id byte to inbound packets; a real
-- Arctis payload always starts with 0x06/0x07, so dropping a leading 0x00 is a
-- safe no-op on platforms that don't add it.
local function strip_report_id(s)
  if #s >= 1 and s:byte(1) == 0x00 then return s:sub(2) end
  return s
end

local function eq_raw_to_db(raw)
  return (raw - EQ_BASELINE) * 0.5
end

local function eq_db_to_raw(db)
  return clamp(math.floor(EQ_BASELINE + db / 0.5 + 0.5), 0, 255)
end

-- Dropdown position (0-based) of a device preset byte; unknown → Custom's slot.
local function eq_preset_index(byte)
  for i, p in ipairs(EQ_PRESETS) do
    if p.byte == byte then return i - 1 end
  end
  for i, p in ipairs(EQ_PRESETS) do
    if p.byte == EQ_CUSTOM_BYTE then return i - 1 end
  end
  return 0
end

local function eq_preset_byte(index0)
  local p = EQ_PRESETS[index0 + 1]
  return p and p.byte or EQ_CUSTOM_BYTE
end

-- ── device state ─────────────────────────────────────────────────────────────
-- Module-level, so it persists across callbacks for this one device's VM (the
-- worker is single-threaded). Poll folds hardware reads in; setters reflect a
-- write immediately so getters don't lag a poll interval.

local state = {
  headset_battery = 0,
  slot_battery = 0,
  power_status = POWER_OFFLINE,
  mic_muted = false,
  nc_mode = 0,
  nc_level = 1,
  wireless_mode = 0,
  auto_off = 0,
  gain = 0,
  sidetone = 0,
  screen_mode = 0,
  sonar_eq = 0,
  mic_led_brightness = 100,
  mic_volume = 10,
  volume = 100,
  chatmix = 0,
  eq_preset = 0,
  eq_bands = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
  bt_connection = 0,
  bt_auto_mute = 0,
}

-- ChatMix virtual sinks (nil until initialize creates them; nil forever if the
-- OS can't provide them, e.g. Windows or no matching physical sink).
local chatmix_media = nil
local chatmix_chat = nil

local function apply_status(s)
  if #s < 0x10 or s:byte(1) ~= REPORT_CMD or s:byte(2) ~= MSG_STATUS then return false end
  state.power_status = s:byte(0x0F + 1) or POWER_OFFLINE
  state.headset_battery = math.floor(math.min(s:byte(0x06 + 1) or 0, 8) * 100 / 8)
  state.slot_battery = math.floor(math.min(s:byte(0x07 + 1) or 0, 8) * 100 / 8)
  state.nc_level = math.min(s:byte(0x08 + 1) or 0, 10)
  state.mic_muted = (s:byte(0x09 + 1) or 0) ~= 0
  state.nc_mode = math.min(s:byte(0x0A + 1) or 0, 2)
  state.mic_led_brightness = math.min(s:byte(0x0B + 1) or 0, 10) * 10
  state.auto_off = math.min(s:byte(0x0C + 1) or 0, 6)
  state.wireless_mode = math.min(s:byte(0x0D + 1) or 0, 1)
  state.bt_auto_mute = s:byte(0x03 + 1) or 0
  state.bt_connection = s:byte(0x05 + 1) or 0
  return true
end

local function apply_settings(s)
  if #s < 0x13 or s:byte(1) ~= REPORT_CMD or s:byte(2) ~= MSG_SETTINGS then return false end
  state.gain = ((s:byte(0x04 + 1) or 0x01) == 0x02) and 1 or 0
  state.eq_preset = s:byte(0x06 + 1) or 0
  state.sidetone = math.min(s:byte(0x12 + 1) or 0, 3)
  for i = 0, 9 do
    state.eq_bands[i + 1] = eq_raw_to_db(s:byte(0x07 + i + 1) or EQ_BASELINE)
  end
  return true
end

local function signed_byte(raw)
  return raw >= 0x80 and raw - 0x100 or raw
end

-- The station reports output volume as attenuation: 0 dB is full volume and
-- -56 dB is the dial floor. The UI uses the conventional 0..100 scale.
local function attenuation_to_percent(raw)
  local db = clamp(signed_byte(raw), -56, 0)
  return math.floor((db + 56) * 100 / 56 + 0.5)
end

local function percent_to_attenuation(percent)
  local db = math.floor(-56 + clamp(percent, 0, 100) * 56 / 100 + 0.5)
  return db & 0xff
end

-- Fold both command replies and unsolicited notifications into the same state.
-- Hardware-originated changes then flow through the normal typed range/choice
-- caches returned by read_status().
local function apply_control_packet(s)
  if #s < 3 or (s:byte(1) ~= REPORT_CMD and s:byte(1) ~= REPORT_NOTIFY) then
    return false
  end
  local msg, value = s:byte(2), s:byte(3)
  if msg == MSG_MIC_GAIN then state.gain = value == 0x02 and 1 or 0
  elseif msg == MSG_MIC_VOLUME then state.mic_volume = clamp(value, 1, 10)
  elseif msg == MSG_SIDETONE then state.sidetone = clamp(value, 0, 3)
  elseif msg == MSG_NC_MODE then state.nc_mode = clamp(value, 0, 2)
  elseif msg == MSG_NC_LEVEL then state.nc_level = clamp(value, 1, 10)
  elseif msg == MSG_MIC_LED then state.mic_led_brightness = clamp(value, 0, 10) * 10
  elseif msg == MSG_AUTO_OFF then state.auto_off = clamp(value, 0, 6)
  elseif msg == MSG_WIRELESS_MODE then state.wireless_mode = clamp(value, 0, 1)
  elseif msg == MSG_SCREEN_MODE then state.screen_mode = clamp(value, 0, 1)
  elseif msg == MSG_SONAR_EQ then state.sonar_eq = clamp(value, 0, 1)
  elseif msg == MSG_EQ_PRESET then state.eq_preset = value
  elseif msg == MSG_VOLUME then state.volume = attenuation_to_percent(value)
  elseif msg == MSG_EQ_BANDS and #s >= 12 then
    for i = 0, 9 do
      state.eq_bands[i + 1] = eq_raw_to_db(s:byte(3 + i) or EQ_BASELINE)
    end
  else return false end
  return true
end

-- Parse a ChatMix dial notification `07 45 <game> <chat>` (each 0–100). Emitted
-- only when the dial actually moves.
local function parse_chatmix(s)
  if #s >= 4 and s:byte(1) == REPORT_NOTIFY and s:byte(2) == MSG_CHATMIX then
    local game, chat = s:byte(3), s:byte(4)
    state.chatmix = clamp(game - chat, -100, 100)
    return game, chat
  end
  return nil
end

-- One poll pass: prompt for status + settings, then drain queued packets (the
-- status reply can be buried behind streamed dial notifications). The first read
-- blocks for a reply, the rest are non-blocking; unrecognised packets are
-- classified as ChatMix dial notifications or ignored.
local function refresh(dev)
  dev.transport:write(string.char(REPORT_CMD, MSG_STATUS))
  dev.transport:write(string.char(REPORT_CMD, MSG_SETTINGS))
  -- Never occupy the shared command worker for the transport's full 1 s read
  -- timeout. Replies are requested above; after their short assembly window,
  -- drain whatever is ready. A late packet remains queued for the next pass.
  halod.sleep_ms(POLL_REPLY_DELAY_MS)
  local cm_game, cm_chat
  for _ = 1, MAX_POLL_READS do
    local ok, pkt = pcall(function()
      return dev.transport:read_nonblocking(PACKET)
    end)
    if not ok or type(pkt) ~= "string" or #pkt == 0 then break end
    local s = strip_report_id(pkt)
    if not apply_status(s) and not apply_settings(s) and not apply_control_packet(s) then
      local g, c = parse_chatmix(s)
      if g then cm_game, cm_chat = g, c end
    end
  end
  -- Balance the two ChatMix sinks from the latest dial value in this pass, so
  -- game/media and chat audio mix per the dial. Only runs when the dial moved.
  if cm_game and chatmix_media then
    chatmix_media:set_volume(cm_game)
    chatmix_chat:set_volume(cm_chat)
  end
end

local function persist(dev)
  pcall(function() dev.transport:write(string.char(REPORT_CMD, MSG_PERSIST)) end)
end

-- ── capability value builders ────────────────────────────────────────────────

local function headset_online()
  return state.power_status == POWER_ONLINE or state.power_status == POWER_CHARGING
end

local function batteries()
  local headset_status = "unknown"
  if state.power_status == POWER_CHARGING then
    headset_status = "charging"
  elseif headset_online() then
    headset_status = "discharging"
  end
  return {
    { key = "headset", label = "Headset",
      level = headset_online() and state.headset_battery or 0, status = headset_status },
    { key = "slot", label = "Charging Slot", level = state.slot_battery,
      status = state.slot_battery > 0 and "charging" or "unknown" },
  }
end

local function booleans(dev)
  local b = { { key = "mic_active", value = not state.mic_muted } }
  if is_bt_variant(dev) then
    b[#b + 1] = { key = "bt_connection", value = state.bt_connection ~= 0 }
    b[#b + 1] = { key = "bt_auto_mute", value = state.bt_auto_mute ~= 0 }
  end
  return b
end

local controls = {
  choices = {
    { key="gain", label="Microphone Gain", category="Microphone", display="inline", options={{id="0",label="Low"},{id="1",label="High"}} },
    { key="sidetone", label="Sidetone", category="Microphone", display="inline", options={{id="0",label="Off"},{id="1",label="Low"},{id="2",label="Medium"},{id="3",label="High"}} },
    { key="nc_mode", label="Mode", category="Noise Cancelling", display="inline", options={{id="0",label="Off"},{id="1",label="Transparent"},{id="2",label="Noise Cancelling"}} },
    { key="wireless_mode", label="Wireless Mode", category="Base Station", display="inline", options={{id="0",label="Maximum Speed"},{id="1",label="Maximum Range"}} },
    { key="auto_off", label="Auto-Off Timeout", category="Base Station", display="list", options={{id="0",label="Off"},{id="1",label="1 min"},{id="2",label="5 min"},{id="3",label="10 min"},{id="4",label="15 min"},{id="5",label="30 min"},{id="6",label="60 min"}} },
    { key="screen_mode", label="Screen Mode", category="Base Station", display="inline", options={{id="0",label="Detailed"},{id="1",label="Simple"}} },
    { key="sonar_eq", label="Sonar EQ", category="Audio", display="toggle", options={{id="0",label="Off"},{id="1",label="On"}} },
  },
  ranges = {
    { key="volume", label="Volume", category="Audio", min=0, max=100, step=1, default=100 },
    { key="chatmix", label="ChatMix", category="Audio", min=-100, max=100, step=1, default=0 },
    { key="mic_volume", label="Microphone Volume", category="Microphone", min=1, max=10, step=1, default=10 },
    { key="mic_led_brightness", label="LED Brightness", category="Microphone", min=0, max=100, step=10, default=100 },
    { key="nc_level", label="Transparency Level", category="Noise Cancelling", min=1, max=10, step=1, default=1,
      visible_when={ key="nc_mode", equals={1} } },
  },
  booleans = {
    { key="mic_active", label="Microphone", category="Microphone", read_only=true },
    { key="bt_connection", label="Bluetooth", category="Bluetooth", read_only=true },
    { key="bt_auto_mute", label="Auto-Mute", category="Bluetooth", read_only=true },
  },
}

local function build_equalizer()
  local presets = {}
  for _, p in ipairs(EQ_PRESETS) do
    presets[#presets + 1] = {
      id = tostring(p.byte),
      label = p.name,
      is_custom = p.byte == EQ_CUSTOM_BYTE,
      is_firmware = p.byte ~= EQ_CUSTOM_BYTE,
      bands = (#p.bands > 0) and p.bands or nil,
    }
  end
  local sel = eq_preset_index(state.eq_preset)
  local selp = presets[sel + 1]
  -- Editable = the Custom curve, or a firmware preset carrying its own info bands.
  local editable = selp ~= nil and (selp.is_custom or selp.bands ~= nil)
  -- Show the selected firmware preset's info curve, else the live custom curve.
  local values = (selp and selp.bands) or state.eq_bands
  local bands = {}
  for i = 1, 10 do
    bands[i] = {
      index = i - 1, label = EQ_BAND_LABELS[i],
      min = -10.0, max = 10.0, step = 0.5, value = values[i] or 0.0,
    }
  end
  return { presets = presets, selected_preset = sel, bands = bands, editable = editable }
end

-- ── manifest ─────────────────────────────────────────────────────────────────

return {
  initialize = function(dev)
    -- Ask the base station to show the ChatMix display, then seed the host caches
    -- with the device's current settings so the UI reflects hardware, not defaults.
    pcall(function() dev.transport:write(string.char(REPORT_CMD, MSG_CHATMIX_DISPLAY, 0x01)) end)
    refresh(dev)
    -- ChatMix: register the Media + Chat virtual sinks looped into the headset's
    -- physical sink. Returns nil when unavailable (Windows / no matching sink),
    -- in which case ChatMix is silently inactive.
    local base = is_bt_variant(dev)
      and "SteelSeries Arctis Nova Pro Wireless X"
      or "SteelSeries Arctis Nova Pro Wireless"
    chatmix_media = dev.audio:register(base .. " Media")
    chatmix_chat = dev.audio:register(base .. " Chat")
    -- Both sinks are needed to balance; drop a lone one so we never half-route.
    if not (chatmix_media and chatmix_chat) then
      if chatmix_media then chatmix_media:remove() end
      if chatmix_chat then chatmix_chat:remove() end
      chatmix_media, chatmix_chat = nil, nil
    end
    log("SteelSeries Arctis initialized (%s, ChatMix %s)",
      is_bt_variant(dev) and "Wireless X" or "Wireless",
      chatmix_media and "on" or "off")
    return {
      ok = true,
      choices = {
        gain = state.gain, sidetone = state.sidetone, nc_mode = state.nc_mode,
        wireless_mode = state.wireless_mode, auto_off = state.auto_off,
        screen_mode = state.screen_mode, sonar_eq = state.sonar_eq,
      },
      ranges = {
        volume = state.volume, chatmix = state.chatmix,
        mic_volume = state.mic_volume, mic_led_brightness = state.mic_led_brightness,
        nc_level = state.nc_level,
      },
      controls = controls,
    }
  end,

  read_status = function(dev)
    refresh(dev)
    return {
      choices = {
        gain = state.gain, sidetone = state.sidetone, nc_mode = state.nc_mode,
        wireless_mode = state.wireless_mode, auto_off = state.auto_off,
        screen_mode = state.screen_mode, sonar_eq = state.sonar_eq,
      },
      ranges = {
        volume = state.volume, chatmix = state.chatmix,
        mic_volume = state.mic_volume, mic_led_brightness = state.mic_led_brightness,
        nc_level = state.nc_level,
      },
    }
  end,

  -- The host also tears down any sinks on close; do it explicitly so a plugin
  -- reload doesn't briefly leave two Media/Chat sinks registered.
  close = function(dev)
    if chatmix_media then chatmix_media:remove() end
    if chatmix_chat then chatmix_chat:remove() end
    chatmix_media, chatmix_chat = nil, nil
  end,

  get_batteries = function(dev)
    return batteries()
  end,

  get_booleans = function(dev)
    return booleans(dev)
  end,

  set_boolean = function(dev, key, value)
    error("'" .. key .. "' is read-only on this device")
  end,

  set_choice = function(dev, key, selected)
    local pkt
    if key == "nc_mode" then
      pkt = string.char(REPORT_CMD, MSG_NC_MODE, math.min(selected, 2))
    elseif key == "sidetone" then
      pkt = string.char(REPORT_CMD, MSG_SIDETONE, math.min(selected, 3))
    elseif key == "wireless_mode" then
      pkt = string.char(REPORT_CMD, MSG_WIRELESS_MODE, math.min(selected, 1))
    elseif key == "gain" then
      pkt = string.char(REPORT_CMD, MSG_MIC_GAIN, selected ~= 0 and 0x02 or 0x01)
    elseif key == "auto_off" then
      pkt = string.char(REPORT_CMD, MSG_AUTO_OFF, math.min(selected, 6))
    elseif key == "sonar_eq" then
      pkt = string.char(REPORT_CMD, MSG_SONAR_EQ, selected ~= 0 and 1 or 0)
    elseif key == "screen_mode" then
      pkt = string.char(REPORT_CMD, MSG_SCREEN_MODE, selected ~= 0 and 1 or 0)
    else
      error("unknown choice key: " .. key)
    end
    dev.transport:write(pkt)
    state[key] = selected
    persist(dev)
  end,

  set_range = function(dev, key, value)
    if key == "volume" then
      local v = clamp(value, 0, 100)
      dev.transport:write(string.char(REPORT_CMD, MSG_VOLUME, percent_to_attenuation(v)))
      state.volume = v
    elseif key == "chatmix" then
      local v = clamp(value, -100, 100)
      local game = v >= 0 and 100 or 100 + v
      local chat = v <= 0 and 100 or 100 - v
      dev.transport:write(string.char(REPORT_CMD, MSG_CHATMIX_SET, game, 0x00, chat))
      state.chatmix = v
    elseif key == "mic_volume" then
      local v = clamp(value, 1, 10)
      dev.transport:write(string.char(REPORT_CMD, MSG_MIC_VOLUME, v))
      state.mic_volume = v
    elseif key == "mic_led_brightness" then
      local v = clamp(value, 0, 100)
      dev.transport:write(string.char(REPORT_CMD, MSG_MIC_LED, math.min(v // 10, 10)))
      state.mic_led_brightness = v
    elseif key == "nc_level" then
      local v = clamp(value, 1, 10)
      dev.transport:write(string.char(REPORT_CMD, MSG_NC_LEVEL, v))
      state.nc_level = v
    else
      error("unknown range key: " .. key)
    end
    persist(dev)
  end,

  get_equalizer = function(dev)
    return build_equalizer()
  end,

  set_eq_preset = function(dev, preset)
    local byte = eq_preset_byte(preset)
    dev.transport:write(string.char(REPORT_CMD, MSG_EQ_PRESET, byte))
    state.eq_preset = byte
    persist(dev)
  end,

  set_eq_bands = function(dev, values)
    if #values ~= 10 then
      error("expected 10 EQ band values, got " .. #values)
    end
    -- Custom band values require selecting the editable preset first.
    dev.transport:write(string.char(REPORT_CMD, MSG_EQ_PRESET, EQ_CUSTOM_BYTE))
    local pkt = { REPORT_CMD, MSG_EQ_BANDS }
    for i = 1, 10 do
      pkt[#pkt + 1] = eq_db_to_raw(clamp(values[i], -10, 10))
    end
    dev.transport:write(string.char(table.unpack(pkt)))
    state.eq_preset = EQ_CUSTOM_BYTE
    for i = 1, 10 do
      state.eq_bands[i] = clamp(values[i], -10, 10)
    end
    persist(dev)
  end,
}
