-- SPDX-License-Identifier: GPL-2.0-or-later
-- HID++2 FULL_KEY_CUSTOMIZATION (0x1b05): a keyboard runs key assignments
-- from a preset file in PROFILE_MANAGEMENT flash and reports the keys it
-- took over. docs/hidpp2.md.

return function(api)
local bytes, feature, request = api.bytes, api.feature, api.request
local FKC, CONTROL_LIST = api.feature_id, api.control_list

local M = {}

M.OP_DISABLE, M.OP_MOUSE, M.OP_KEY, M.OP_CONSUMER, M.OP_GSHIFT = 0x8000, 0x8001, 0x8002, 0x8003, 0x8004
M.ACTION_DISABLE, M.ACTION_MODIFIER_ONLY = 0x8000, 0x4000
M.ROW_SIZE = 9
-- A profile references one preset file per layer, in this order.
M.LAYER_BASE, M.LAYER_FN, M.LAYER_GSHIFT, M.LAYER_MACROS = 0, 1, 2, 3
M.LIST_PADDING = 0xff

local function u16(s, i) return ((s:byte(i) or 0) << 8) | (s:byte(i + 1) or 0) end

function M.enabled(dev)
  local reply = feature(dev, FKC, 0x30, bytes(0, 0, 0))
  return (reply:byte(1) or 0) ~= 0, (reply:byte(2) or 0) ~= 0
end

function M.set_enabled(dev, on)
  feature(dev, FKC, 0x30, bytes(0x01, on and 1 or 0, 0))
end

-- Control ids in firmware order; a trigger names its key by this index.
function M.control_list(dev)
  local state = dev.hidpp
  local index = state.features[CONTROL_LIST]
  local count = request(dev, state.devnum, index, 0x00):byte(1) or 0
  local cids = {}
  for start = 0, count - 1, 8 do
    local reply = request(dev, state.devnum, index, 0x10, bytes(start))
    for k = 0, math.min(7, count - start - 1) do
      cids[start + k + 1] = u16(reply, 1 + k * 2)
    end
  end
  return cids
end

local function be16(v) return (v >> 8) & 0xff, v & 0xff end

-- Preset file: [0x00][group count] then per group [cidx][row count] rows.
-- Row: [index][flags][0][action bits u16][opcode u16][params u16], big-endian.
-- Action bits: 0x8000 disable, 0x4000 modifiers only, low byte modifier mask.
function M.encode_preset(groups)
  local out, index = { bytes(0, #groups) }, 0
  for _, group in ipairs(groups) do
    out[#out + 1] = bytes(group.cidx, #group.rows)
    for _, row in ipairs(group.rows) do
      out[#out + 1] = bytes(index, row.flags or 0, 0)
        .. bytes(be16(row.action or 0)) .. bytes(be16(row.opcode)) .. bytes(be16(row.params or 0))
      index = index + 1
    end
  end
  return table.concat(out)
end

function M.decode_preset(data)
  local groups, pos = {}, 3
  for _ = 1, data:byte(2) or 0 do
    local cidx, count = data:byte(pos), data:byte(pos + 1) or 0
    if not cidx then break end
    pos = pos + 2
    local rows = {}
    for _ = 1, count do
      local r = data:sub(pos, pos + M.ROW_SIZE - 1)
      if #r < M.ROW_SIZE then break end
      rows[#rows + 1] = {
        index = r:byte(1), flags = r:byte(2),
        action = u16(r, 4), opcode = u16(r, 6), params = u16(r, 8),
      }
      pos = pos + M.ROW_SIZE
    end
    groups[#groups + 1] = { cidx = cidx, rows = rows }
  end
  return groups
end

local DISABLE_ROW = { action = M.ACTION_DISABLE, opcode = M.OP_DISABLE }
-- Holding the key switches the firmware to the G-shift layer.
M.GSHIFT_ROW = { opcode = M.OP_GSHIFT, params = 0x0002 }
-- Rows that run an action match the plain key press.
M.FLAG_SINGLE_KEY = 0x80
local MOUSE_BUTTONS = { left = 1, right = 2, middle = 3, back = 4, forward = 5 }
local CONSUMER_USAGES = { play = 0xcd, next = 0xb5, prev = 0xb6, volume_up = 0xe9, volume_down = 0xea, mute = 0xe2 }

-- The row the firmware runs on its own for an action; nil when the host has
-- to run it (the key then gets a disabled row and is reported as a trigger).
function M.native_row(action)
  local kind = type(action) == "table" and action.type
  if kind == "disable" then return DISABLE_ROW
  elseif kind == "layer_shift" then return M.GSHIFT_ROW
  elseif kind == "mouse_button" and MOUSE_BUTTONS[action.btn] then
    return { flags = M.FLAG_SINGLE_KEY, opcode = M.OP_MOUSE, params = 1 << (MOUSE_BUTTONS[action.btn] - 1) }
  elseif kind == "media_key" and CONSUMER_USAGES[action.key] then
    return { flags = M.FLAG_SINGLE_KEY, opcode = M.OP_CONSUMER, params = CONSUMER_USAGES[action.key] }
  end
end

-- True when the firmware performs the action itself (a mouse button or a
-- consumer key), so a host acting on the trigger would repeat it.
function M.firmware_action(action)
  local row = M.native_row(action)
  return row ~= nil and row.opcode ~= M.OP_DISABLE and row.opcode ~= M.OP_GSHIFT
end

-- The row a layer's action puts in that layer's preset: nil for a native
-- action (the key keeps its plain function), the firmware's own row where it
-- has one, otherwise a disabled row that the host acts on.
function M.layer_row(action)
  if type(action) ~= "table" or action.type == nil or action.type == "native" then return nil end
  return M.native_row(action) or DISABLE_ROW
end

-- One group per taken-over key, in control-list order: `rows` maps a cidx to
-- its row (true = disabled row). Also returns the cidx of each row index,
-- which is how trigger events name a key.
function M.preset(rows)
  local cidxs = {}
  for cidx in pairs(rows) do cidxs[#cidxs + 1] = cidx end
  table.sort(cidxs)
  local groups, by_index = {}, {}
  for i, cidx in ipairs(cidxs) do
    local row = rows[cidx]
    groups[#groups + 1] = { cidx = cidx, rows = { row ~= true and row or DISABLE_ROW } }
    by_index[i - 1] = cidx
  end
  return M.encode_preset(groups), by_index
end

function M.disable_preset(cidxs)
  local rows = {}
  for _, cidx in ipairs(cidxs) do rows[cidx] = DISABLE_ROW end
  return (M.preset(rows))
end

-- Trigger events come in a list/bitmap pair per layer: functions 0/1 base,
-- 2/3 Fn, 4/5 G-shift. A list holds up to 15 row indexes padded with 0xff; a
-- bitmap holds 128 bits, bit 0 of byte 0 = row 0, of the rows currently held.
-- Returns the set of control-list indexes held on that layer and the layer,
-- or nil for any other report.
function M.trigger_event(dev, report)
  local features = dev.hidpp and dev.hidpp.features
  if not features or report:byte(3) ~= features[FKC] then return nil end
  local fn = (report:byte(4) or 0xff) >> 4
  if fn > 5 then return nil end
  local layer = fn >> 1
  local rows, pressed = dev.fkc and dev.fkc.rows and dev.fkc.rows[layer] or {}, {}
  if fn & 1 == 0 then
    for i = 5, math.min(#report, 19) do
      local cidx = report:byte(i) ~= M.LIST_PADDING and rows[report:byte(i)]
      if cidx then pressed[cidx] = true end
    end
  else
    for i = 5, math.min(#report, 20) do
      local byte = report:byte(i)
      for bit = 0, 7 do
        local cidx = (byte & (1 << bit)) ~= 0 and rows[(i - 5) * 8 + bit]
        if cidx then pressed[cidx] = true end
      end
    end
  end
  return pressed, layer
end

return M
end
