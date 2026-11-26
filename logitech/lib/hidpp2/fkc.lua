-- SPDX-License-Identifier: GPL-2.0-or-later
-- HID++2 FULL_KEY_CUSTOMIZATION (0x1b05): a keyboard runs key assignments
-- from a preset file in PROFILE_MANAGEMENT flash and reports the keys it
-- took over. docs/hidpp2.md.

return function(api)
local bytes, feature, request = api.bytes, api.feature, api.request
local FKC, CONTROL_LIST = api.feature_id, api.control_list

local M = {}

M.OP_DISABLE, M.OP_MOUSE, M.OP_KEY, M.OP_CONSUMER, M.OP_GSHIFT = 0x8000, 0x8001, 0x8002, 0x8003, 0x8004
M.MODIFIER_ONLY = 0x4000
M.ROW_SIZE = 9

local function u16(s, i) return ((s:byte(i) or 0) << 8) | (s:byte(i + 1) or 0) end

function M.capabilities(dev)
  local caps = feature(dev, FKC, 0x00)
  return {
    config_version = caps:byte(1) or 0, macro_version = caps:byte(2) or 0,
    config_max_size = u16(caps, 3), macro_max_size = u16(caps, 5),
    max_triggers = caps:byte(7) or 0, sw_capabilities = caps:byte(8) or 0,
  }
end

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

local function le16(v) return v & 0xff, (v >> 8) & 0xff end

-- Preset file: [0x00][group count] then per group [cidx][row count] rows.
-- Row: [index][modifiers][0][action bits lo hi][opcode lo hi][params lo hi].
function M.encode_preset(groups)
  local out, index = { bytes(0, #groups) }, 0
  for _, group in ipairs(groups) do
    out[#out + 1] = bytes(group.cidx, #group.rows)
    for _, row in ipairs(group.rows) do
      out[#out + 1] = bytes(index, row.modifiers or 0, 0)
        .. bytes(le16(row.action or 0)) .. bytes(le16(row.opcode)) .. bytes(le16(row.params or 0))
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
        index = r:byte(1), modifiers = r:byte(2),
        action = r:byte(4) | (r:byte(5) << 8), opcode = r:byte(6) | (r:byte(7) << 8),
        params = r:byte(8) | (r:byte(9) << 8),
      }
      pos = pos + M.ROW_SIZE
    end
    groups[#groups + 1] = { cidx = cidx, rows = rows }
  end
  return groups
end

-- One disabled row per taken-over key: the firmware swallows the key and
-- reports it as a trigger instead.
function M.disable_preset(cidxs)
  table.sort(cidxs)
  local groups = {}
  for _, cidx in ipairs(cidxs) do
    groups[#groups + 1] = { cidx = cidx, rows = { { opcode = M.OP_DISABLE } } }
  end
  return M.encode_preset(groups)
end

-- Trigger events name the layer in the function nibble: list or bitmap of
-- control-list indexes for base (0/1), Fn (2/3) and G-shift (4/5); 6 reports
-- the enabled state. Returns the set of pressed indexes, or nil.
function M.trigger_event(dev, report)
  local features = dev.hidpp and dev.hidpp.features
  if not features or report:byte(3) ~= features[FKC] or (report:byte(4) & 0x0f) ~= 0 then return nil end
  local fn = report:byte(4) >> 4
  if fn > 5 then return nil end
  local pressed = {}
  if fn % 2 == 0 then
    for i = 5, #report do
      local cidx = report:byte(i)
      if cidx == 0xff then break end
      if i > 5 and cidx == 0 then break end
      pressed[cidx] = true
    end
  else
    for i = 5, math.min(#report, 20) do
      local byte = report:byte(i)
      for bit = 0, 7 do
        if (byte & (1 << bit)) ~= 0 then pressed[(i - 5) * 8 + bit] = true end
      end
    end
  end
  return pressed, fn // 2
end

return M
end
