-- SPDX-License-Identifier: GPL-2.0-or-later
-- HID++2 onboard-profile flash-sector codec and cached profile state.

return function(api)
local bytes, feature = api.bytes, api.feature
local ONBOARD_PROFILES = api.feature_id
local restore_rgb_control = api.restore_rgb_control

local function onboard_mode(dev)
  if not dev.onboard then return 2 end
  local mode = feature(dev, ONBOARD_PROFILES, 0x20):byte(1) or dev.onboard.mode
  dev.onboard.mode = mode
  return mode
end

local function set_onboard_mode(dev, host)
  feature(dev, ONBOARD_PROFILES, 0x10, bytes(host and 2 or 1))
  dev.onboard.mode = host and 2 or 1
  if host then restore_rgb_control(dev) end
end

local function crc16(data)
  local crc = 0xffff
  for i = 1, #data do
    crc = crc ~ (data:byte(i) << 8)
    for _ = 1, 8 do
      crc = ((crc & 0x8000) ~= 0) and (((crc << 1) ~ 0x1021) & 0xffff)
        or ((crc << 1) & 0xffff)
    end
  end
  return crc
end

local function with_sector_crc(data, size)
  if size < 2 or #data < size then error("profile sector is too short") end
  local body = data:sub(1, size - 2)
  local crc = crc16(body)
  return body .. bytes((crc >> 8) & 0xff, crc & 0xff)
end

local function read_sector(dev, sector, size)
  if size < 16 then error("invalid onboard profile sector size") end
  local chunks, offset = {}, 0
  while offset + 15 < size do
    local reply
    for _ = 1, 3 do
      local ok, value = pcall(feature, dev, ONBOARD_PROFILES, 0x50,
        bytes((sector >> 8) & 0xff, sector & 0xff, (offset >> 8) & 0xff, offset & 0xff))
      if ok then reply = value; break end
    end
    if not reply then error(string.format("failed to read profile sector 0x%04X", sector)) end
    chunks[#chunks + 1] = reply:sub(1, math.min(16, size - offset))
    offset = offset + 16
  end
  local data = table.concat(chunks)
  if #data < size then
    local tail = size - 16
    local reply = feature(dev, ONBOARD_PROFILES, 0x50,
      bytes((sector >> 8) & 0xff, sector & 0xff, (tail >> 8) & 0xff, tail & 0xff))
    local missing = size - #data
    data = data .. reply:sub(17 - missing, 16)
  end
  return data:sub(1, size)
end

local function write_sector(dev, sector, data)
  local size = #data
  feature(dev, ONBOARD_PROFILES, 0x60,
    bytes((sector >> 8) & 0xff, sector & 0xff, 0, 0, (size >> 8) & 0xff, size & 0xff))
  for offset = 1, size, 16 do
    local chunk = data:sub(offset, offset + 15)
    if #chunk < 16 then chunk = chunk .. string.rep("\0", 16 - #chunk) end
    feature(dev, ONBOARD_PROFILES, 0x70, chunk)
  end
  feature(dev, ONBOARD_PROFILES, 0x80)
end

local function parse_directory(data)
  local out = {}
  for offset = 1, #data - 2, 4 do
    local sector = ((data:byte(offset) or 0) << 8) | (data:byte(offset + 1) or 0)
    if sector == 0 or sector == 0xffff then break end
    out[#out + 1] = { sector = sector, enabled = (data:byte(offset + 2) or 0) ~= 0,
      offset = offset }
  end
  return out
end

local function sector_dpi_steps(data)
  local out = {}
  if #data < 13 then return out end
  for i = 0, 4 do
    local offset = 4 + i * 2
    local value = (data:byte(offset) or 0) | ((data:byte(offset + 1) or 0) << 8)
    if value ~= 0 and value ~= 0xffff then out[#out + 1] = value end
  end
  return out
end

local function patch_sector_dpi(data, size, steps)
  if #steps == 0 then error("DPI steps list cannot be empty") end
  if #steps > 5 then error("onboard profiles support at most five DPI steps") end
  local values = { data:byte(1, size) }
  for i = 0, 4 do
    local value = steps[i + 1] or 0
    values[4 + i * 2], values[5 + i * 2] = value & 0xff, (value >> 8) & 0xff
  end
  if (values[2] or 0) >= #steps then values[2] = #steps - 1 end
  if (values[3] or 0) >= #steps then values[3] = 0 end
  return with_sector_crc(bytes(table.unpack(values)), size)
end

local function refresh_onboard(dev)
  local info = feature(dev, ONBOARD_PROFILES, 0x00)
  local size = ((info:byte(8) or 0) << 8) | (info:byte(9) or 0)
  if size < 16 then error("invalid onboard profile sector size") end
  local mode = feature(dev, ONBOARD_PROFILES, 0x20):byte(1) or 1
  local directory_data = read_sector(dev, 0, size)
  local directory = parse_directory(directory_data)
  local active_reply = feature(dev, ONBOARD_PROFILES, 0x40)
  local active = ((active_reply:byte(1) or 0) << 8) | (active_reply:byte(2) or 0)
  if active == 0 or active == 0xffff then
    active = 0
    for _, entry in ipairs(directory) do if entry.enabled then active = entry.sector; break end end
  end
  dev.onboard = { mode = mode, rom_count = info:byte(5) or 0, sector_size = size,
    directory = directory, directory_data = directory_data, active_sector = active }
  if active ~= 0 then
    dev.onboard.profile_data = read_sector(dev, active, size)
    dev.onboard.profile_steps = sector_dpi_steps(dev.onboard.profile_data)
  else
    dev.onboard.profile_steps = {}
  end
  return dev.onboard
end

local function onboard_status(dev)
  -- Full daemon snapshots run four times per second.  The onboard directory
  -- and active profile are whole flash sectors, so re-reading them here turns
  -- otherwise-idle serialization into a continuous HID++ write stream.  The
  -- cache is populated during initialize and explicitly refreshed after every
  -- profile mutation and relevant feature notification.
  local state = dev.onboard or refresh_onboard(dev)
  local active_slot = state.mode == 2 and 0 or (state.active_sector & 0xff)
  local slots = {}
  for _, entry in ipairs(state.directory) do
    local slot = entry.sector & 0xff
    slots[#slots + 1] = { index = slot, enabled = entry.enabled,
      active = active_slot ~= 0 and active_slot == slot,
      has_rom_default = slot > 0 and slot <= state.rom_count }
  end
  return { active_slot = active_slot, slots = slots }
end

local function restore_profile(dev, slot, allow_seed)
  local state = dev.onboard or refresh_onboard(dev)
  if slot == 0 then error("profile slot must be 1-based") end
  if not allow_seed and slot > state.rom_count then error("profile has no factory default") end
  local source = slot <= state.rom_count and (0x0100 | slot) or 0x0101
  local data = with_sector_crc(read_sector(dev, source, state.sector_size), state.sector_size)
  write_sector(dev, slot, data)
end

return {
  mode = onboard_mode,
  set_mode = set_onboard_mode,
  with_sector_crc = with_sector_crc,
  read_sector = read_sector,
  write_sector = write_sector,
  sector_dpi_steps = sector_dpi_steps,
  patch_sector_dpi = patch_sector_dpi,
  refresh = refresh_onboard,
  status = onboard_status,
  restore_profile = restore_profile,
}
end
