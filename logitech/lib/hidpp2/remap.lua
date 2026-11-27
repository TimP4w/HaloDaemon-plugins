-- SPDX-License-Identifier: GPL-2.0-or-later
-- SPDX-FileCopyrightText: 2012-2013 Daniel Pavel
-- SPDX-FileCopyrightText: 2014-2024 Solaar Contributors <https://pwr-solaar.github.io/Solaar/>
-- HID++2 programmable-control discovery, diversion, and button events.

return function(api)
local bytes, request, feature = api.bytes, api.request, api.feature
local DIRECT, device_profile = api.direct, api.device_profile
local REPROG_CONTROLS_V4 = api.reprog_controls_v4
local GKEY, MOUSE_BUTTON_SPY = api.gkey, api.mouse_button_spy
local FKC, CONTROL_LIST = api.full_key_customization, api.control_list
local fkc, write_fkc_presets = api.fkc, api.write_fkc_presets
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
  elseif features[FKC] and features[CONTROL_LIST] then
    backend = "fkc"
    local index = {}
    for i, cid in ipairs(fkc.control_list(dev)) do
      if cid ~= 0 and not index[cid] then
        index[cid] = i - 1
        buttons[#buttons + 1] = { cid = cid, label = CONTROLS[cid] or string.format("Key 0x%04X", cid),
          divertable = true, group = 0 }
      end
    end
    dev.fkc = { index = index, cids = {} }
    for cid, cidx in pairs(index) do dev.fkc.cids[cidx] = cid end
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

local layer_rows

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

-- The firmware keeps one preset per layer, so the base and shifted actions
-- go to separate files and the layer is switched on the device. Returns the
-- rows of each layer by control-list index, nil for a layer without any.
layer_rows = function(dev)
  local remap, out = dev.remap, {}
  for layer, actions in pairs({ [fkc.LAYER_BASE] = remap.base, [fkc.LAYER_GSHIFT] = remap.shifted }) do
    for cid, action in pairs(actions) do
      local cidx, row = dev.fkc.index[cid], fkc.layer_row(action)
      if cidx and row then
        out[layer] = out[layer] or {}
        out[layer][cidx] = row
      end
    end
  end
  return out
end

-- The key whose base action shifts layers, if one is mapped.
local function layer_shift_cid(remap)
  for cid, action in pairs(remap.base) do
    if type(action) == "table" and action.type == "layer_shift" then return cid end
  end
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
  elseif remap.backend == "fkc" then
    write_fkc_presets(dev, layer_rows(dev))
  end
end

-- What a mapping stores: the action itself where the backend writes rows for
-- it, otherwise just that the key is mapped. A native action stores nothing.
local function stored(remap, action)
  if action_is_native(action) then return nil end
  return remap.backend == "fkc" and action or true
end

local function same_row(a, b)
  local ra, rb = fkc.layer_row(a), fkc.layer_row(b)
  if ra == nil or rb == nil then return ra == rb end
  return ra.opcode == rb.opcode and (ra.params or 0) == (rb.params or 0)
    and (ra.flags or 0) == (rb.flags or 0) and (ra.action or 0) == (rb.action or 0)
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
  base, shifted = stored(remap, base), stored(remap, shifted)
  if remap.backend == "fkc" then
    if same_row(remap.base[cid], base) and same_row(remap.shifted[cid], shifted) then return end
  elseif (remap.base[cid] or false) == (base or false) and (remap.shifted[cid] or false) == (shifted or false) then
    return
  end
  local saved = { base = copy(remap.base), shifted = copy(remap.shifted), layer = remap.layer }
  local before = snapshot(remap, { [cid] = true })
  remap.base[cid], remap.shifted[cid] = base, shifted
  local ok, err = pcall(sync, dev, before)
  if not ok then restore(remap, saved); error(err) end
end

local function set_layer(dev, active)
  local remap = dev.remap
  if not remap or remap.layer == active then return end
  -- A keyboard with layer presets switches layers in firmware.
  if remap.backend == "fkc" then remap.layer = active; return end
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
  local devnum = dev.hidpp and dev.hidpp.devnum or dev.match.index or DIRECT
  if packet_in:byte(2) ~= devnum then return nil end
  local sub, address = packet_in:byte(3), packet_in:byte(4)
  local current = {}
  if remap.backend == "fkc" then
    if sub == dev.hidpp.features[FKC] then
      log(string.format("logitech: key customization event %s",
        (packet_in:sub(4):gsub(".", function(c) return string.format("%02x ", c:byte()) end))), "debug")
    end
    local pressed, layer = fkc.trigger_event(dev, packet_in)
    if not pressed then return nil end
    remap.held = remap.held or {}
    local held = {}
    for cidx in pairs(pressed) do
      local cid = dev.fkc.cids[cidx]
      local action = layer == fkc.LAYER_GSHIFT and remap.shifted[cid] or remap.base[cid]
      -- A key whose action the firmware performs itself is not the host's to
      -- act on again; disabled keys and the layer key are reported.
      if cid and not fkc.firmware_action(action) then held[cid] = true end
    end
    remap.held[layer] = held
    -- The host resolves a G-shift key through its own layer state, so the
    -- layer key is reported held while anything on that layer is.
    local seen, shift = {}, layer_shift_cid(remap)
    if shift and next(remap.held[fkc.LAYER_GSHIFT] or {}) then
      current[#current + 1] = shift; seen[shift] = true
    end
    for _, set in pairs(remap.held) do
      for cid in pairs(set) do
        if not seen[cid] then current[#current + 1] = cid; seen[cid] = true end
      end
    end
  else
    if address ~= 0 then return nil end
    local expected = remap.backend == "reprog" and dev.hidpp.features[REPROG_CONTROLS_V4]
      or remap.backend == "gkey" and dev.hidpp.features[GKEY]
      or dev.hidpp.features[MOUSE_BUTTON_SPY]
    if sub ~= expected then return nil end
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
