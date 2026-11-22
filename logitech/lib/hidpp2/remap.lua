-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: 2012-2013 Daniel Pavel
-- SPDX-FileCopyrightText: 2014-2024 Solaar Contributors <https://pwr-solaar.github.io/Solaar/>
-- HID++2 programmable-control discovery, diversion, and button events.

return function(api)
local bytes, request, feature = api.bytes, api.request, api.feature
local DIRECT, device_profile = api.direct, api.device_profile
local REPROG_CONTROLS_V4 = api.reprog_controls_v4
local GKEY, MOUSE_BUTTON_SPY = api.gkey, api.mouse_button_spy
local CONTROLS = halod.require("lib.hidpp2.controls")

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
      local hi, lo, _, _, flags, _, group = info:byte(1, 7)
      if hi and lo and flags and (flags & 0x20) ~= 0 then
        local cid = (hi << 8) | lo
        local label = CONTROLS[cid] or string.format("Button 0x%04X", cid)
        buttons[#buttons + 1] = { cid = cid, label = label, divertable = true, group = group or 0 }
      end
    end
  elseif features[GKEY] then
    backend = "gkey"
    local count = request(dev, devnum, features[GKEY], 0x00):byte(1) or 0
    for i = 1, math.min(count, 16) do buttons[#buttons + 1] = { cid = i, label = "G" .. i, divertable = true, group = 0 } end
  elseif features[MOUSE_BUTTON_SPY] then
    backend = "spy"
    local labels = device_profile(dev).buttons
    for i = 1, 16 do
      if not labels or labels[i] then
        buttons[#buttons + 1] = { cid = i, label = labels and labels[i] or ("Button " .. i), divertable = true, group = 0 }
      end
    end
  end
  dev.remap = { backend = backend, base = {}, shifted = {}, layer = false, previous = {} }
  if backend == "spy" then
    local ok, reply = pcall(request, dev, devnum, features[MOUSE_BUTTON_SPY], 0x30)
    if ok and #reply >= 16 then
      local table_ = {}
      for i = 1, 16 do table_[i] = reply:byte(i) end
      dev.remap.spy_table = table_
    end
  end
  return buttons
end

-- MOUSE_BUTTON_SPY event bits are big-endian: physical button n is bit n-1 of
-- the u16, while cids here number the bytes little-endian (bit 8 = cid 9).
local function spy_button(cid) return ((cid - 1) ~ 8) + 1 end

-- A button's native output is suppressed while its action on the current
-- layer is non-native: base mappings always, shifted mappings only while the
-- global layer shift is held. Reporting stays on while anything is mapped.
local function suppressed(remap, cid)
  return remap.base[cid] or (remap.layer and remap.shifted[cid]) or false
end

local function any_mapped(remap)
  return next(remap.base) ~= nil or next(remap.shifted) ~= nil
end

-- Remap table entry n-1 is the HID button physical button n reports; 0
-- suppresses the native report while the spy event still fires.
local function write_spy_table(dev)
  local remap = dev.remap
  if not remap.spy_table then return end
  local out = {}
  for i, value in ipairs(remap.spy_table) do out[i] = value end
  for cid in pairs(remap.base) do out[spy_button(cid)] = out[spy_button(cid)] and 0 end
  if remap.layer then
    for cid in pairs(remap.shifted) do out[spy_button(cid)] = out[spy_button(cid)] and 0 end
  end
  feature(dev, MOUSE_BUTTON_SPY, 0x40, bytes(table.unpack(out)))
end

local function write_divert(dev, cid, divert)
  local payload = { (cid >> 8) & 0xff, cid & 0xff, divert and 0x03 or 0x02 }
  for _ = 1, 13 do payload[#payload + 1] = 0 end
  feature(dev, REPROG_CONTROLS_V4, 0x30, bytes(table.unpack(payload)))
end

-- Push the backend state that changed between `before` (a snapshot of
-- suppressed cids and whether anything was mapped) and now.
local function sync(dev, before)
  local remap = dev.remap
  local had_any, any = before.any, any_mapped(remap)
  if remap.backend == "reprog" then
    for cid in pairs(before.cids) do
      local now = suppressed(remap, cid)
      if now ~= before.suppressed[cid] then write_divert(dev, cid, now) end
    end
  elseif remap.backend == "gkey" then
    if had_any ~= any then feature(dev, GKEY, 0x20, bytes(any and 1 or 0)) end
  elseif remap.backend == "spy" then
    if any and not had_any then feature(dev, MOUSE_BUTTON_SPY, 0x10) end
    local changed = had_any ~= any
    for cid in pairs(before.cids) do
      if suppressed(remap, cid) ~= before.suppressed[cid] then changed = true end
    end
    if changed then write_spy_table(dev) end
    if had_any and not any then feature(dev, MOUSE_BUTTON_SPY, 0x20) end
  end
end

local function snapshot(remap, cids)
  local out = { any = any_mapped(remap), cids = cids, suppressed = {} }
  for cid in pairs(cids) do out.suppressed[cid] = suppressed(remap, cid) end
  return out
end

local function restore(remap, saved)
  remap.base, remap.shifted, remap.layer = saved.base, saved.shifted, saved.layer
end

local function copy(t) local out = {}; for k, v in pairs(t) do out[k] = v end; return out end

local function set_mapping(dev, cid, base, shifted)
  local remap = assert(dev.remap, "remap unavailable")
  if (remap.base[cid] or false) == base and (remap.shifted[cid] or false) == shifted then return end
  local saved = { base = copy(remap.base), shifted = copy(remap.shifted), layer = remap.layer }
  local before = snapshot(remap, { [cid] = true })
  remap.base[cid], remap.shifted[cid] = base or nil, shifted or nil
  local ok, err = pcall(sync, dev, before)
  if not ok then restore(remap, saved); error(err) end
end

local function set_layer(dev, active)
  local remap = dev.remap
  if not remap or remap.layer == active then return end
  local before = snapshot(remap, copy(remap.shifted))
  remap.layer = active
  sync(dev, before)
end

local function rearm(dev)
  local remap = dev.remap
  if not remap then return end
  remap.previous = {}
  if not any_mapped(remap) then return end
  local cids = copy(remap.base)
  for cid in pairs(remap.shifted) do cids[cid] = true end
  local before = { any = false, cids = cids, suppressed = {} }
  sync(dev, before)
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
  mapping_is_native = mapping_is_native,
  action_is_native = action_is_native,
  buttons = remap_buttons,
  set_mapping = set_mapping,
  set_layer = set_layer,
  rearm = rearm,
  events = button_events,
}
end
