-- SPDX-License-Identifier: GPL-2.0-or-later
-- HID++2 lighting discovery, encoding, effects, and software-control ownership.

return function(api)
local bytes, packet = api.bytes, api.packet
local request, feature = api.request, api.feature
local send_feature_packets, retry, pm = api.send_feature_packets, api.retry, api.pm
local SW_ID = api.sw_id
local RGB_EFFECTS = api.rgb_effects
local COLOR_LED_EFFECTS = api.color_led_effects
local PER_KEY_LIGHTING_V2 = api.per_key_lighting_v2
local PROFILE_MANAGEMENT = api.profile_management

local function clamp(value, min, max)
  return math.floor(math.max(min, math.min(max, value)) + 0.5)
end

local function range(id, label, min, max, step, default)
  return { id = id, label = label, kind = { kind = "range", min = min, max = max, step = step }, default = default }
end

local RATE = range("rate", "Effect Rate (ms)", 1000, 20000, 100, 10000)
local RIPPLE_RATE = range("rate", "Effect Rate (ms)", 2, 200, 1, 20)
local BRIGHTNESS = range("brightness", "Brightness", 1, 100, 1, 100)
local SATURATION = range("saturation", "Saturation", 0, 100, 1, 100)
local COLOR = { id = "color", label = "Color", kind = { kind = "color" }, default = { r = 0xff, g = 0xff, b = 0xff } }
local BACKGROUND = { id = "background", label = "Background Color", kind = { kind = "color" },
  default = { r = 0x5e, g = 0x5e, b = 0x5e } }
local DIRECTIONS = { "horizontal", "vertical", "center_out", "inward", "outward",
  "reverse_horizontal", "reverse_vertical", "center_in" }
local DIRECTION = { id = "direction", label = "Direction", kind = { kind = "enum", options = DIRECTIONS },
  default = "horizontal" }

local function value(params, param)
  local v = params[param.id]
  if v == nil then v = param.default end
  if param.kind.kind == "range" then return clamp(v, param.kind.min, param.kind.max) end
  return v
end

local function rgb(c) return c.r or 0, c.g or 0, c.b or 0 end

local function sat_byte(params) return clamp(value(params, SATURATION) * 2.55, 0, 255) end

local function direction_byte(params)
  local wanted = value(params, DIRECTION)
  for i, name in ipairs(DIRECTIONS) do if name == wanted then return i end end
  return 1
end

-- Wire variants per effect, preferred first; layouts in docs/hidpp2.md.
local NATIVE_EFFECTS = {
  { id = "off", name = "Off", variants = {
      { wire = 0x00, params = {}, encode = function() return { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } end },
    } },
  { id = "breathing", name = "Breathing", variants = {
      { wire = 0x0a, params = { COLOR, RATE, BRIGHTNESS }, encode = function(p)
          local r, g, b = rgb(value(p, COLOR)); local rate = value(p, RATE)
          return { r, g, b, rate >> 8, rate & 0xff, 0, value(p, BRIGHTNESS), 0, 0, 0 }
        end },
    } },
  { id = "color_cycle", name = "Color Cycle", variants = {
      { wire = 0x15, params = { RATE, BRIGHTNESS, SATURATION }, encode = function(p)
          local rate = value(p, RATE)
          return { 0, sat_byte(p), 0, 0, 0, 0, rate >> 8, rate & 0xff, value(p, BRIGHTNESS), 0 }
        end },
      { wire = 0x03, params = { RATE, BRIGHTNESS }, encode = function(p)
          local rate = value(p, RATE)
          return { 0, 0, 0, 0, 0, rate >> 8, rate & 0xff, value(p, BRIGHTNESS), 0, 0 }
        end },
    } },
  { id = "color_wave", name = "Color Wave", variants = {
      { wire = 0x16, params = { RATE, DIRECTION, BRIGHTNESS, SATURATION }, encode = function(p)
          local rate = value(p, RATE)
          return { 0, sat_byte(p), 0, 0, 0, 0, rate >> 8, rate & 0xff, value(p, BRIGHTNESS), direction_byte(p) }
        end },
      { wire = 0x04, params = { RATE, DIRECTION, BRIGHTNESS }, encode = function(p)
          local rate = value(p, RATE)
          return { 0, 0, 0, 0, 0, 0, rate & 0xff, direction_byte(p), value(p, BRIGHTNESS), rate >> 8 }
        end },
    } },
  { id = "ripple", name = "Ripple", variants = {
      { wire = 0x17, params = { BACKGROUND, RIPPLE_RATE, SATURATION }, encode = function(p)
          local r, g, b = rgb(value(p, BACKGROUND)); local rate = value(p, RIPPLE_RATE)
          return { r, g, b, sat_byte(p), 0, 0, rate >> 8, rate & 0xff, 0, 0 }
        end },
      { wire = 0x0b, params = { BACKGROUND, RIPPLE_RATE }, encode = function(p)
          local r, g, b = rgb(value(p, BACKGROUND)); local rate = value(p, RIPPLE_RATE)
          return { r, g, b, 0, rate >> 8, rate & 0xff, 0, 0, 0, 0 }
        end },
    } },
  { id = "decomposition", name = "Decomposition", variants = {
      { wire = 0x0e, params = { RATE, BRIGHTNESS }, encode = function(p)
          local rate = value(p, RATE)
          return { 0, 0, 0, 0, 0, 0, rate & 0xff, rate >> 8, value(p, BRIGHTNESS), 0 }
        end },
    } },
}

-- zone -> chosen variant for every effect some zone's firmware table reports.
local function resolve_native_effects(effect_slots)
  local resolved, descriptors = {}, {}
  for _, effect in ipairs(NATIVE_EFFECTS) do
    local zones, first = {}, nil
    for zone, slots in pairs(effect_slots or {}) do
      for _, variant in ipairs(effect.variants) do
        if slots[variant.wire] then
          zones[zone] = { variant = variant, slot = slots[variant.wire] }
          first = first or variant
          break
        end
      end
    end
    if first then
      resolved[effect.id] = zones
      descriptors[#descriptors + 1] = { id = effect.id, name = effect.name, params = first.params }
    end
  end
  return resolved, descriptors
end

local function apply_native_effect(dev, id, params)
  local zones = dev.lighting and dev.lighting.native and dev.lighting.native[id]
  if not zones then error("native effect is not supported by this device") end
  local order = {}
  for zone in pairs(zones) do order[#order + 1] = zone end
  table.sort(order)
  for _, zone in ipairs(order) do
    local entry = zones[zone]
    local block = { zone, entry.slot }
    for _, byte in ipairs(entry.variant.encode(params or {})) do block[#block + 1] = byte end
    if dev.lighting.wire == "color_led" then
      block[#block + 1] = 0x00
      feature(dev, COLOR_LED_EFFECTS, 0x30, bytes(table.unpack(block)))
    else
      block[#block + 1] = 0x01 -- apply without storing to NV (0x02 = persistent)
      feature(dev, RGB_EFFECTS, 0x10, bytes(table.unpack(block)))
    end
  end
end

-- The onboard profile stores an effect as its wire id and parameter bytes.
local function native_record(dev, id, params)
  local zones = dev.lighting and dev.lighting.native and dev.lighting.native[id]
  if not zones then error("native effect is not supported by this device") end
  local entry = zones[0] or zones[next(zones)]
  return entry.variant.wire, entry.variant.encode(params or {})
end

local function static_record(color)
  return 0x01, { color.r or 0, color.g or 0, color.b or 0, 0x02, 0, 0, 0, 0, 0, 0 }
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

-- Returns the static slot per zone (1-based) and, per zone id, a map of
-- firmware effect id -> slot.
local function rgb_static_slots(dev, index, count)
  local slots, effect_slots = {}, {}
  for zone = 0, count - 1 do
    local info = request(dev, dev.hidpp.devnum, index, 0x00, bytes(zone, 0xff, 0))
    local effect_count, static = info:byte(5) or 0, 0
    effect_slots[zone] = {}
    for slot = 0, effect_count - 1 do
      local effect = request(dev, dev.hidpp.devnum, index, 0x00, bytes(zone, slot, 0))
      local id = ((effect:byte(3) or 0) << 8) | (effect:byte(4) or 0)
      if id == 0x0001 then static = slot end
      if effect_slots[zone][id] == nil then effect_slots[zone][id] = slot end
    end
    slots[zone + 1] = static
  end
  return slots, effect_slots
end

local COLOR_ZONE_NAMES = {
  [1] = "Primary", [2] = "Logo", [3] = "Left Side", [4] = "Right Side",
  [5] = "Combined", [6] = "Primary 1", [7] = "Primary 2", [8] = "Primary 3",
  [9] = "Primary 4", [10] = "Primary 5", [11] = "Primary 6",
}

-- Returns channels, the static slot per zone (1-based) and, per zone id, a
-- map of firmware effect id -> slot.
local function color_led_zones(dev, index, count, zone_names)
  local channels, slots, effect_slots = {}, {}, {}
  for zone = 0, count - 1 do
    local info = request(dev, dev.hidpp.devnum, index, 0x10, bytes(zone, 0xff, 0))
    local actual = info:byte(1) or zone
    local location = ((info:byte(2) or 0) << 8) | (info:byte(3) or 0)
    local effect_count, static = info:byte(4) or 0, 0
    effect_slots[actual] = {}
    for slot = 0, effect_count - 1 do
      local effect = request(dev, dev.hidpp.devnum, index, 0x20, bytes(actual, slot, 0))
      local id = ((effect:byte(3) or 0) << 8) | (effect:byte(4) or 0)
      if id == 0x0001 then static = slot end
      if effect_slots[actual][id] == nil then effect_slots[actual][id] = slot end
    end
    channels[#channels + 1] = { id = "zone_" .. actual,
      name = (zone_names and zone_names[actual]) or COLOR_ZONE_NAMES[location] or "Unknown",
      topology = "linear", led_count = 1 }
    slots[#slots + 1] = static
  end
  return channels, slots, effect_slots
end

local SET_INDIVIDUAL, SET_CONSECUTIVE, SET_RANGE, COMMIT = 0x10, 0x20, 0x50, 0x70

local function per_key_packet(dev, func, payload)
  return packet(dev.hidpp.devnum, dev.hidpp.features[PER_KEY_LIGHTING_V2], func | SW_ID,
    bytes(table.unpack(payload)), true)
end

-- SET_INDIVIDUAL carries four (id, r, g, b) entries; a short last packet
-- repeats its final entry. The commit follows.
local function individual_packets(dev, entries)
  local packets = {}
  for start = 1, #entries, 4 do
    local finish, payload = math.min(start + 3, #entries), {}
    for offset = 0, 3 do
      local entry = entries[math.min(start + offset, finish)]
      payload[#payload + 1] = entry.id
      payload[#payload + 1] = entry.r
      payload[#payload + 1] = entry.g
      payload[#payload + 1] = entry.b
    end
    packets[#packets + 1] = per_key_packet(dev, SET_INDIVIDUAL, payload)
  end
  packets[#packets + 1] = per_key_packet(dev, COMMIT, { 0 })
  return packets
end

local EXPLICIT_WRITE_MAX_LEDS = 8

local function write_per_key_frame(dev, colors)
  local ids = dev.lighting.led_ids or {}
  local cache, states = dev.lighting.frame_cache or {}, {}
  dev.lighting.frame_cache = cache
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

  -- A short strip is most reliable with explicit LED writes: its LEDs fit in
  -- two SET_INDIVIDUAL packets, so SET_CONSECUTIVE saves nothing and can leave
  -- one LED at its previous colour during pixmap streaming.
  if #ids <= EXPLICIT_WRITE_MAX_LEDS then
    local dirty = {}
    for _, state in ipairs(states) do if state.dirty then dirty[#dirty + 1] = state end end
    send_feature_packets(dev, individual_packets(dev, dirty))
    for _, state in ipairs(states) do cache[state.id] = { state.r, state.g, state.b } end
    return
  end

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
          packets[#packets + 1] = per_key_packet(dev, SET_CONSECUTIVE, payload)
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
    packets[#packets + 1] = per_key_packet(dev, SET_RANGE, payload)
  end
  packets[#packets + 1] = per_key_packet(dev, COMMIT, { 0 })
  send_feature_packets(dev, packets)
  for _, state in ipairs(states) do cache[state.id] = { state.r, state.g, state.b } end
end

-- Paint mode supplies a sparse map keyed by firmware LED id. Preserve that
-- addressing and use the protocol's explicit setIndividual operation; a
-- streaming frame is positional and cannot represent a one-key sparse edit.
local function write_per_key_pairs(dev, channels)
  local supported, entries = {}, {}
  for _, id in ipairs(dev.lighting.led_ids or {}) do supported[id] = true end
  for _, led_colors in pairs(channels or {}) do
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
  send_feature_packets(dev, individual_packets(dev, entries))

  local cache = dev.lighting.frame_cache or {}
  dev.lighting.frame_cache = cache
  for _, entry in ipairs(entries) do cache[entry.id] = { entry.r, entry.g, entry.b } end
end

local function write_rgb_zone(dev, zone_id, colors)
  if not dev.lighting then return end
  if dev.lighting.wire == "per_key" then write_per_key_frame(dev, colors); return end
  local zone = tonumber(zone_id:match("^zone_(%d+)$")) or 0
  local color = colors[1] or { r = 0, g = 0, b = 0 }
  local slot = dev.lighting.static_slots[zone + 1] or 0
  if dev.lighting.wire == "color_led" then
    feature(dev, COLOR_LED_EFFECTS, 0x30,
      bytes(zone, slot, color.r or 0, color.g or 0, color.b or 0, 0x02, 0, 0, 0, 0, 0, 0, 0))
  else
    feature(dev, RGB_EFFECTS, 0x10,
      bytes(zone, slot, color.r or 0, color.g or 0, color.b or 0,
        0x64, 0x0b, 0xb8, 0x64, 0, 0, 0, 1, 0, 0))
  end
end

local CLAIM_SETTLE_MS = 2000
local OWN_CLUSTERS_AND_POWER = 0x03
local NOTIFY_IDLE, NOTIFY_ACTIVITY = 0x04, 0x02
local POWER_FULL, POWER_OFF = 0x01, 0x03

local function profile_managed(dev)
  return dev.hidpp.features[PROFILE_MANAGEMENT] ~= nil and dev.hidpp.features[RGB_EFFECTS] ~= nil
end

local function idle_off_after_sleep_timeout(dev)
  local ok, timers = pcall(feature, dev, RGB_EFFECTS, 0x70, bytes(0))
  if not ok or #timers < 7 then return end
  local idle_hi, idle_lo, sleep_hi, sleep_lo = timers:byte(4, 7)
  local sleep = (sleep_hi << 8) | sleep_lo
  if sleep == 0 or sleep == 0xffff or (idle_hi == sleep_hi and idle_lo == sleep_lo) then return end
  dev.lighting.saved_timers = { idle_hi, idle_lo, sleep_hi, sleep_lo }
  pcall(feature, dev, RGB_EFFECTS, 0x70, bytes(1, 0, 0, sleep_hi, sleep_lo, sleep_hi, sleep_lo))
end

local function restore_power_timers(dev)
  local saved = dev.lighting.saved_timers
  dev.lighting.saved_timers, dev.lighting.power_configured = nil, nil
  if saved then pcall(feature, dev, RGB_EFFECTS, 0x70, bytes(1, 0, 0, table.unpack(saved))) end
end

local function enter_host_mode(dev)
  retry(pm.set_mode, dev, pm.HOST_MODE)
  dev.lighting.host = true
end

local function restore_rgb_control(dev)
  if not dev.lighting then return end
  -- Reclaiming means the firmware owned the LEDs, so the streaming frame cache
  -- no longer describes what is lit and must not suppress the write that follows.
  dev.lighting.frame_cache = nil
  if profile_managed(dev) then
    -- Host mode holds until released or changed by the firmware (reported by
    -- a PROFILE_MANAGEMENT event), so it is only re-sent after that.
    if not dev.lighting.host then enter_host_mode(dev) end
    retry(feature, dev, RGB_EFFECTS, 0x50, bytes(1, OWN_CLUSTERS_AND_POWER, NOTIFY_IDLE))
    dev.lighting.claimed_at = halod.monotonic_ms()
    dev.lighting.host = true
    -- The firmware may have parked the LEDs in power save before the claim.
    dev.lighting.sleeping = false
    retry(feature, dev, RGB_EFFECTS, 0x80, bytes(1, POWER_FULL))
    if not dev.lighting.power_configured then
      dev.lighting.power_configured = true
      idle_off_after_sleep_timeout(dev)
    end
  elseif dev.lighting.wire == "rgb_effects" or dev.hidpp.features[RGB_EFFECTS] then
    retry(feature, dev, RGB_EFFECTS, 0x50, bytes(1, 1))
  elseif dev.lighting.wire == "color_led" then
    retry(feature, dev, COLOR_LED_EFFECTS, 0x80, bytes(1))
  end
end

local function release_rgb_control(dev)
  dev.lighting.frame_cache, dev.lighting.sleeping = nil, false
  dev.lighting.host = false
  restore_power_timers(dev)
  retry(feature, dev, RGB_EFFECTS, 0x50, bytes(1, 0, 0))
  retry(pm.set_mode, dev, pm.ONBOARD_MODE)
end

local function user_activity_report(dev, report)
  if not dev.lighting or not dev.lighting.claimed_at then return nil end
  if report:byte(2) ~= dev.hidpp.devnum or report:byte(3) ~= dev.hidpp.features[RGB_EFFECTS]
      or report:byte(4) ~= 0x10 then
    return nil
  end
  return (report:byte(5) or 0) ~= 0
end

local function sleep_lighting(dev)
  if dev.lighting.sleeping then return end
  if halod.monotonic_ms() - dev.lighting.claimed_at < CLAIM_SETTLE_MS then return end
  dev.lighting.sleeping = true
  feature(dev, RGB_EFFECTS, 0x80, bytes(1, POWER_OFF))
  feature(dev, RGB_EFFECTS, 0x50, bytes(1, OWN_CLUSTERS_AND_POWER, NOTIFY_ACTIVITY))
end

return {
  resolve_native_effects = resolve_native_effects,
  apply_native_effect = apply_native_effect,
  native_record = native_record,
  static_record = static_record,
  discover_per_key_ids = discover_per_key_ids,
  rgb_static_slots = rgb_static_slots,
  color_led_zones = color_led_zones,
  write_per_key_frame = write_per_key_frame,
  write_per_key_pairs = write_per_key_pairs,
  write_rgb_zone = write_rgb_zone,
  restore_rgb_control = restore_rgb_control,
  release_rgb_control = release_rgb_control,
  enter_host_mode = enter_host_mode,
  profile_managed = profile_managed,
  user_activity_report = user_activity_report,
  sleep_lighting = sleep_lighting,
}
end
