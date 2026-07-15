-- SPDX-License-Identifier: GPL-2.0-or-later
-- HID++2 lighting discovery, encoding, effects, and software-control ownership.

return function(api)
local bytes, packet = api.bytes, api.packet
local request, feature = api.request, api.feature
local send_feature_packets = api.send_feature_packets
local SW_ID = api.sw_id
local RGB_EFFECTS = api.rgb_effects
local COLOR_LED_EFFECTS = api.color_led_effects
local PER_KEY_LIGHTING_V2 = api.per_key_lighting_v2

local NATIVE_EFFECTS
local function select_native_effects(profile)
  local out = {}
  for _, id in ipairs(profile.native_effects or {}) do
    for _, effect in ipairs(NATIVE_EFFECTS or {}) do
      if effect.id == id then out[#out + 1] = effect end
    end
  end
  return out
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

local function write_per_key_frame(dev, colors, led_ids)
  -- Streaming colours are ordered like the host descriptor, which for
  -- keyboards is physical key order rather than numeric firmware-ID order.
  local ids = led_ids or dev.rgb.led_ids or {}
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

  -- The G502's short mouse strip is most reliable with explicit LED writes.
  -- Eight LEDs still fit in two reports, so SET_CONSECUTIVE saves nothing over
  -- two SET_INDIVIDUAL packets and has been observed leaving one strip LED at
  -- its previous colour during pixmap streaming.
  if dev.profile and dev.profile.device_type == "mouse" then
    local dirty, packets = {}, {}
    for _, state in ipairs(states) do if state.dirty then dirty[#dirty + 1] = state end end
    for start = 1, #dirty, 4 do
      local finish = math.min(start + 3, #dirty)
      local last, payload = dirty[finish], {}
      for offset = 0, 3 do
        local entry = dirty[math.min(start + offset, finish)] or last
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

local function write_rgb_zone(dev, zone_id, colors, led_ids)
  if not dev.rgb then return end
  if dev.rgb.wire == "per_key" then write_per_key_frame(dev, colors, led_ids); return end
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

return {
  select_native_effects = select_native_effects,
  apply_native_effect = apply_native_effect,
  discover_per_key_ids = discover_per_key_ids,
  rgb_static_slots = rgb_static_slots,
  color_led_zones = color_led_zones,
  write_per_key_frame = write_per_key_frame,
  write_per_key_pairs = write_per_key_pairs,
  write_rgb_zone = write_rgb_zone,
  restore_rgb_control = restore_rgb_control,
}
end
