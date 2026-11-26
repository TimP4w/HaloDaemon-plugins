-- SPDX-License-Identifier: GPL-2.0-or-later
-- HID++2 PROFILE_MANAGEMENT (0x8101): a flash file system with one directory
-- per partition, CRC-32 checked files and tag-described profiles. docs/hidpp2.md.

return function(api)
local bytes, feature = api.bytes, api.feature
local PROFILE_MANAGEMENT = api.feature_id

local M = {}
M.USER, M.FACTORY = 0x0000, 0x0100
M.PROFILE_TYPE, M.FKC_TYPE = 0x8101, 0x1b05
M.SECTOR = 128
M.HOST_MODE, M.ONBOARD_MODE = 0x05, 0x03

local crc_table
local function crc32(data)
  if not crc_table then
    crc_table = {}
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do c = (c & 1) ~= 0 and (0xedb88320 ~ (c >> 1)) or (c >> 1) end
      crc_table[i] = c
    end
  end
  local crc = 0xffffffff
  for i = 1, #data do crc = crc_table[(crc ~ data:byte(i)) & 0xff] ~ (crc >> 8) end
  return (~crc) & 0xffffffff
end
M.crc32 = crc32

local function be16(v) return (v >> 8) & 0xff, v & 0xff end
local function be32(v) return (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff end
local function u16(s, i) return ((s:byte(i) or 0) << 8) | (s:byte(i + 1) or 0) end
local function u32(s, i) return (u16(s, i) << 16) | u16(s, i + 2) end

local function hidpp_error(err, code)
  return tostring(err):find(string.format("HID++ error 0x%02x", code), 1, true) ~= nil
end

function M.capabilities(dev)
  local info = feature(dev, PROFILE_MANAGEMENT, 0x00)
  return { buffer_size = u16(info, 3), profile_count = info:byte(15) or 0 }
end

-- Byte 0 bit 0: onboard profile active; bit 1: firmware power management.
function M.mode(dev)
  local reply = feature(dev, PROFILE_MANAGEMENT, 0x60, bytes(0))
  local flags = reply:byte(1) or 0
  return { onboard = (flags & 0x01) ~= 0, host = (flags & 0x01) == 0, active = u16(reply, 2) }
end

function M.set_mode(dev, flags)
  feature(dev, PROFILE_MANAGEMENT, 0x60, bytes(flags))
end

-- Tags are single bytes; a tag at or above 0xe0 refers to another feature's
-- file and carries that feature id. 0xff ends the list.
function M.read_tags(dev)
  local tags, offset = {}, 0
  while offset < 64 do
    local reply = feature(dev, PROFILE_MANAGEMENT, 0x10, bytes(0, offset))
    local i, consumed = 1, 0
    while i <= #reply do
      local tag = reply:byte(i)
      if tag == 0xff then return tags end
      if tag >= 0xe0 then
        if i + 2 > #reply then break end
        tags[#tags + 1] = { tag = tag, feature = u16(reply, i + 1) }
        i, consumed = i + 3, consumed + 3
      else
        tags[#tags + 1] = { tag = tag }
        i, consumed = i + 1, consumed + 1
      end
    end
    if consumed == 0 then break end
    offset = offset + consumed
  end
  return tags
end

function M.file_refs(tags)
  local refs = {}
  for _, t in ipairs(tags) do if t.feature then refs[#refs + 1] = t end end
  return refs
end

-- Returns nil for a file the device has never written (HID++ error 0x04).
function M.read_file(dev, address, length)
  local hi, lo = be16(address)
  local ok, err = pcall(feature, dev, PROFILE_MANAGEMENT, 0x80, bytes(hi, lo, be16(length)))
  if not ok then
    if hidpp_error(err, 0x04) then return nil end
    error(err)
  end
  local chunks = {}
  for offset = 0, length - 1, 16 do
    chunks[#chunks + 1] = feature(dev, PROFILE_MANAGEMENT, 0xc0, bytes(be16(offset)))
  end
  return table.concat(chunks):sub(1, length)
end

local function read_buffer(dev, length)
  local chunks = {}
  for offset = 0, length - 1, 16 do
    chunks[#chunks + 1] = feature(dev, PROFILE_MANAGEMENT, 0xc0, bytes(be16(offset)))
  end
  return table.concat(chunks):sub(1, length)
end

-- Fills the edit buffer, checks it, commits it to flash and reads it back.
-- A directory (sector 0) is committed under its own header checksum, a file
-- under the checksum of all its bytes; the firmware rejects anything else.
function M.write_file(dev, address, data)
  feature(dev, PROFILE_MANAGEMENT, 0x20, bytes(be16(#data)))
  for offset = 1, #data, 16 do
    local chunk = data:sub(offset, offset + 15)
    feature(dev, PROFILE_MANAGEMENT, 0x30, chunk .. string.rep("\0", 16 - #chunk))
  end
  if read_buffer(dev, #data) ~= data then error("profile buffer verification failed") end
  local hi, lo = be16(address)
  local crc = (address & 0xff) == 0 and u32(data, 1) or crc32(data)
  feature(dev, PROFILE_MANAGEMENT, 0x70, bytes(hi, lo, be16(#data)) .. bytes(be32(crc)))
  if M.read_file(dev, address, #data) ~= data then
    error(string.format("profile file 0x%04X verification failed", address))
  end
end

function M.activate(dev, file_type, id, length, crc)
  local th, tl = be16(file_type)
  local ih, il = be16(id)
  feature(dev, PROFILE_MANAGEMENT, 0x90,
    bytes(th, tl, 0x01, ih, il, be16(length)) .. bytes(be32(crc)))
end

-- Directory: [crc32 over everything after it][count][count x 10-byte entry][0xff].
local ENTRY = 10
function M.parse_directory(data)
  local count = data:byte(5) or 0
  local dir = { crc = u32(data, 1), entries = {} }
  for i = 0, count - 1 do
    local o = 6 + i * ENTRY
    dir.entries[#dir.entries + 1] = {
      id = data:byte(o), type = u16(data, o + 1), flags = data:byte(o + 3),
      length = data:byte(o + 4), crc = u32(data, o + 5), location = data:byte(o + 9),
    }
  end
  return dir
end

function M.serialize_directory(dir)
  local body = { string.char(#dir.entries) }
  for _, e in ipairs(dir.entries) do
    body[#body + 1] = bytes(e.id, be16(e.type)) .. bytes(e.flags, e.length)
      .. bytes(be32(e.crc)) .. bytes(e.location)
  end
  body[#body + 1] = "\xff"
  local payload = table.concat(body)
  return bytes(be32(crc32(payload))) .. payload
end

function M.read_directory(dev, partition)
  local head = M.read_file(dev, partition, 16)
  if not head then return nil end
  local size = 6 + (head:byte(5) or 0) * ENTRY
  local data = size <= 16 and head:sub(1, size) or M.read_file(dev, partition, size)
  return data and M.parse_directory(data) or nil
end

function M.entry(dir, id, file_type)
  for _, e in ipairs(dir and dir.entries or {}) do
    if e.id == id and (file_type == nil or e.type == file_type) then return e end
  end
end

-- Profile layout shared by every known 0x8101 keyboard; the trailing
-- feature-file references follow the device's tag list.
local OFF = { id = 0, version = 1, idle = 2, sleep = 4, name = 6, leds = 30, flags = 74, disabled = 75, refs = 91 }
M.LEDS, M.LED_SIZE, M.NAME_SIZE, M.DISABLED_SIZE = 4, 11, 24, 16
M.FLAGS_SIGNATURE, M.FLAGS_CUSTOM = 0x03, 0x00

function M.parse_profile(data, ref_count)
  if #data < OFF.refs then error("profile file is too short") end
  local b = { data:byte(1, #data) }
  local p = {
    size = #data, bytes = b, id = b[1], version = b[2],
    idle = u16(data, OFF.idle + 1), sleep = u16(data, OFF.sleep + 1),
    name = data:sub(OFF.name + 1, OFF.name + M.NAME_SIZE), leds = {},
    flags = b[OFF.flags + 1],
    disabled = data:sub(OFF.disabled + 1, OFF.disabled + M.DISABLED_SIZE), refs = {},
  }
  for i = 0, M.LEDS - 1 do
    local o = OFF.leds + i * M.LED_SIZE
    local params = {}
    for k = 1, 10 do params[k] = b[o + 1 + k] end
    p.leds[i + 1] = { id = b[o + 1], params = params }
  end
  for i = 1, ref_count or 0 do
    local o = OFF.refs + (i - 1) * 2
    if o + 2 <= #data then
      local ref = u16(data, o + 1)
      p.refs[i] = (ref & 0xff) ~= 0xff and ref or false
    end
  end
  return p
end

function M.serialize_profile(p)
  local b = {}
  for i = 1, p.size do b[i] = p.bytes[i] end
  local function put(offset, ...) for k, v in ipairs({ ... }) do b[offset + k] = v & 0xff end end
  put(OFF.id, p.id, p.version)
  put(OFF.idle, be16(p.idle))
  put(OFF.sleep, be16(p.sleep))
  for i = 1, M.NAME_SIZE do b[OFF.name + i] = p.name:byte(i) or 0xff end
  for i = 0, M.LEDS - 1 do
    local led = p.leds[i + 1]
    put(OFF.leds + i * M.LED_SIZE, led.id, table.unpack(led.params))
  end
  put(OFF.flags, p.flags)
  for i = 1, M.DISABLED_SIZE do b[OFF.disabled + i] = p.disabled:byte(i) or 0 end
  for i, ref in pairs(p.refs) do
    local o = OFF.refs + (i - 1) * 2
    if o + 2 <= p.size then put(o, be16(ref or 0xffff)) end
  end
  return string.char(table.unpack(b, 1, p.size))
end

-- Records 1-2 run while active, 3-4 while power saving; flags 0x03 selects the
-- firmware's signature pair (1 and 3), 0x00 the host-written pair (2 and 4).
M.SIGNATURE_EFFECTS = { [0x18] = 0x19, [0x1a] = 0x1b, [0x0f] = 0x10 }
function M.signature(p)
  local id = p.leds[1].id
  if M.SIGNATURE_EFFECTS[id] then return id, M.SIGNATURE_EFFECTS[id] end
end

local function sectors(length) return (length + M.SECTOR - 1) // M.SECTOR end

-- First free run of sectors in the user partition, never the directory's.
function M.allocate(dir, length)
  local used = {}
  for _, e in ipairs(dir.entries) do
    for s = e.location, e.location + sectors(e.length) - 1 do used[s] = true end
  end
  local need = sectors(length)
  for start = 1, 0x7f - need + 1 do
    local free = true
    for s = start, start + need - 1 do if used[s] then free = false; break end end
    if free then return start end
  end
  error("onboard memory is full")
end

function M.refresh(dev)
  local state = dev.pm or {}
  state.tags = state.tags or M.read_tags(dev)
  state.refs = M.file_refs(state.tags)
  state.mode = M.mode(dev)
  state.user = M.read_directory(dev, M.USER) or { crc = 0, entries = {} }
  state.factory = M.read_directory(dev, M.FACTORY) or { crc = 0, entries = {} }
  state.profiles = {}
  for _, e in ipairs(state.user.entries) do
    if e.type == M.PROFILE_TYPE then
      local data = M.read_file(dev, M.USER | e.location, e.length)
      if data then
        local ok, parsed = pcall(M.parse_profile, data, #state.refs)
        state.profiles[e.id] = { entry = e, data = data, parsed = ok and parsed or nil }
      end
    end
  end
  dev.pm = state
  return state
end

function M.active_profile(state)
  local id = state.mode.active
  if state.profiles[id] then return id end
  for _, e in ipairs(state.user.entries) do
    if e.type == M.PROFILE_TYPE then return e.id end
  end
end

-- Writes a user file and its directory entry; adds the entry when `id` is new.
function M.write_entry(dev, state, id, file_type, data)
  local dir = state.user
  local e = M.entry(dir, id, file_type)
  if e and sectors(data and #data or 0) > sectors(e.length) then
    e.location = M.allocate({ entries = (function()
      local others = {}
      for _, o in ipairs(dir.entries) do if o ~= e then others[#others + 1] = o end end
      return others
    end)() }, #data)
  elseif not e then
    e = { id = id, type = file_type, flags = 0x40, length = #data, crc = 0,
      location = M.allocate(dir, #data) }
    dir.entries[#dir.entries + 1] = e
  end
  e.length, e.crc = #data, crc32(data)
  M.write_file(dev, M.USER | e.location, data)
  M.write_file(dev, M.USER, M.serialize_directory(dir))
  return e
end

function M.write_profile(dev, state, id, data)
  local e = M.write_entry(dev, state, id, M.PROFILE_TYPE, data)
  state.profiles[id] = { entry = e, data = data, parsed = M.parse_profile(data, #state.refs) }
  return e
end

function M.activate_profile(dev, state, id)
  local e = M.entry(state.user, id, M.PROFILE_TYPE) or error("unknown onboard profile")
  M.activate(dev, M.PROFILE_TYPE, id, e.length, e.crc)
end

function M.restore_profile(dev, state, id)
  local source = M.entry(state.factory, id, M.PROFILE_TYPE)
  if not source then error("profile has no factory default") end
  local data = M.read_file(dev, M.FACTORY | source.location, source.length)
  if not data then error("factory profile could not be read") end
  M.write_profile(dev, state, id, data)
end

return M
end
