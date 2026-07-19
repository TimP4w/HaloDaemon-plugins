-- SPDX-License-Identifier: GPL-2.0-or-later
-- HID++2 programmable-control discovery, diversion, and button events.

return function(api)
local bytes, request, feature = api.bytes, api.request, api.feature
local DIRECT, device_profile = api.direct, api.device_profile
local REPROG_CONTROLS_V4 = api.reprog_controls_v4
local GKEY, MOUSE_BUTTON_SPY = api.gkey, api.mouse_button_spy

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
  dev.remap = { backend = backend, active = {}, previous = {} }
  return buttons
end

local function set_remap_active(dev, cid, enabled)
  local remap = assert(dev.remap, "remap unavailable")
  local was_enabled = remap.active[cid] ~= nil
  if was_enabled == enabled then return end
  local had_any = next(remap.active) ~= nil
  remap.active[cid] = enabled or nil
  local any = next(remap.active) ~= nil
  local ok, value = true, nil
  if remap.backend == "reprog" then
    local payload = { (cid >> 8) & 0xff, cid & 0xff, enabled and 1 or 0 }
    for _ = 1, 13 do payload[#payload + 1] = 0 end
    ok, value = pcall(feature, dev, REPROG_CONTROLS_V4, 0x30, bytes(table.unpack(payload)))
  elseif remap.backend == "gkey" and had_any ~= any then
    ok, value = pcall(feature, dev, GKEY, 0x20, bytes(any and 1 or 0))
  elseif remap.backend == "spy" and had_any ~= any then
    ok, value = pcall(feature, dev, MOUSE_BUTTON_SPY, 0x10, bytes(any and 1 or 0))
  end
  if not ok then
    remap.active[cid] = was_enabled and true or nil
    error(value)
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
  mapping_is_native = mapping_is_native,
  buttons = remap_buttons,
  set_active = set_remap_active,
  events = button_events,
}
end
