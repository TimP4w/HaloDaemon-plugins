-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: LibreHardwareMonitor contributors
-- NCT67xx register helpers derived from LibreHardwareMonitor's Nct677X.cs.

local function read_hwm(dev, reg)
  return dev.transport:lpcio_hwm_read(dev.match.hwm_base, reg)
end

local function write_hwm(dev, reg, value)
  dev.transport:lpcio_hwm_write(dev.match.hwm_base, reg, value)
end

-- Matches the former Nct677xVariant::from_id table.  Several parts share a
-- chip id, therefore `revision` must remain part of the transport match.
local function variant_name(id, rev)
  if id == nil or rev == nil then return nil end
  local hi = rev & 0xf0
  if id == 0xb4 and hi == 0x70 then return "NCT6771F" end
  if id == 0xc3 and hi == 0x30 then return "NCT6776F" end
  if id == 0xc4 and hi == 0x50 then return "NCT610XD" end
  if id == 0xc5 and hi == 0x60 then return "NCT6779D" end
  if id == 0xc7 and rev == 0x32 then return "NCT6683D" end
  if id == 0xc8 and rev == 0x03 then return "NCT6791D" end
  if id == 0xc9 and rev == 0x11 then return "NCT6792D" end
  if id == 0xc9 and rev == 0x13 then return "NCT6792DA" end
  if id == 0xd1 and rev == 0x21 then return "NCT6793D" end
  if id == 0xd3 and rev == 0x52 then return "NCT6795D" end
  if id == 0xd4 and rev == 0x23 then return "NCT6796D" end
  if id == 0xd4 and rev == 0x2a then return "NCT6796DR" end
  if id == 0xd4 and rev == 0x51 then return "NCT6797D" end
  if id == 0xd4 and rev == 0x2b then return "NCT6798D" end
  if id == 0xd4 and (rev == 0x40 or rev == 0x41) then return "NCT6686D" end
  if id == 0xd5 and rev == 0x92 then return "NCT6687D" end
  if id == 0xd8 and rev == 0x02 then return "NCT6799D" end
  if id == 0xd8 and rev == 0x06 then return "NCT6701D" end
  return nil
end

local function variant_info(name)
  if name == "NCT6771F" then return { fans = 4, tach = {0x656,0x658,0x65a,0x65c}, pwm = {0x001,0x003,0x011,0x013}, cmd = {0x109,0x209,0x309,0x809}, mode = {0x102,0x202,0x302,0x802}, count16 = true } end
  if name == "NCT6776F" then return { fans = 5, tach = {0x656,0x658,0x65a,0x65c,0x65e}, pwm = {0x001,0x003,0x011,0x013,0x015}, cmd = {0x109,0x209,0x309,0x809,0x909}, mode = {0x102,0x202,0x302,0x802,0x902} } end
  if name == "NCT610XD" then return { fans = 3, tach = {0x030,0x032,0x034}, pwm = {0x04a,0x04b,0x04c}, cmd = {0x119,0x129,0x139}, mode = {0x113,0x123,0x133} } end
  if name == "NCT6779D" then return { fans = 5, tach = {0x4b0,0x4b2,0x4b4,0x4b6,0x4b8}, pwm = {0x001,0x003,0x011,0x013,0x015}, cmd = {0x109,0x209,0x309,0x809,0x909}, mode = {0x102,0x202,0x302,0x802,0x902} } end
  if name == "NCT6796D" or name == "NCT6796DR" or name == "NCT6797D" or name == "NCT6798D" or name == "NCT6799D" or name == "NCT5585D" then return { fans = 7, tach = {0x4b0,0x4b2,0x4b4,0x4b6,0x4b8,0x4ba,0x4cc}, pwm = {0x001,0x003,0x011,0x013,0x015,0xa09,0xb09}, cmd = {0x109,0x209,0x309,0x809,0x909,0xa09,0xb09}, mode = {0x102,0x202,0x302,0x802,0x902,0xa02,0xb02} } end
  if name == "NCT6683D" or name == "NCT6686D" or name == "NCT6687D" or name == "NCT6687DR" then return { fans = 8, tach = {0x140,0x142,0x144,0x146,0x148,0x14a,0x14c,0x14e}, pwm = {0x160,0x161,0x162,0x163,0x164,0x165,0x166,0x167}, ec = true } end
  return { fans = 6, tach = {0x4b0,0x4b2,0x4b4,0x4b6,0x4b8,0x4ba,0x4cc}, pwm = {0x001,0x003,0x011,0x013,0x015,0x017,0x029}, cmd = {0x109,0x209,0x309,0x809,0x909,0xa09,0xb09}, mode = {0x102,0x202,0x302,0x802,0x902,0xa02,0xb02} }
end

local function channel(dev) return tonumber(dev.match.key) or 0 end

local function needs_io_unlock(name)
  return name == "NCT6791D" or name == "NCT6792D" or name == "NCT6792DA"
      or name == "NCT6793D" or name == "NCT6795D" or name == "NCT6796D"
      or name == "NCT6796DR" or name == "NCT6797D" or name == "NCT6798D"
      or name == "NCT6799D" or name == "NCT6701D" or name == "NCT5585D"
end

-- The BIOS may reassert CR 0x28 bit 4 after initial discovery. Validate the
-- HWM vendor id first and only re-enter extended-function mode when needed.
local function keep_io_unlocked(dev)
  local now = halod.monotonic_ms()
  if now < (dev.lpcio_retry_after or 0) then return false end
  -- The broker executes the config-space sequence and registers this worker's
  -- HWM BAR atomically. Lua only receives access to that registered HWM window.
  local ok = pcall(function()
    dev.transport:lpcio_prepare_hwm(dev.match.slot or 0, needs_io_unlock(dev.variant))
  end)
  if not ok then
    -- A closed broker is external/transient. Preserve the last coherent sample
    -- and avoid every sensor/fan consumer hammering the dead pipe.
    dev.lpcio_retry_after = now + 5000
    return false
  end
  return true
end

-- Matches Nct677xVariant::temp_slots.  `half_bit = nil` means an integer
-- reading; EC-family chips deliberately expose no standard HWM temperatures.
local function temp_slots(name)
  if name == "NCT6771F" or name == "NCT6776F" then
    return { {0x027, 0, nil, 0x621}, {0x073, 0x074, 7, 0x100},
      {0x075, 0x076, 7, 0x200}, {0x077, 0x078, 7, 0x300} }
  end
  if name == "NCT610XD" then
    -- The other NCT610XD temperature slots are fixed-source and the former
    -- driver intentionally skipped them because they cannot be labelled.
    return { {0x06b, 0, nil, 0x621} }
  end
  if name == "NCT6683D" or name == "NCT6686D" or name == "NCT6687D" or name == "NCT6687DR" then
    return {}
  end
  return { {0x073, 0x074, 7, 0x100}, {0x075, 0x076, 7, 0x200},
    {0x077, 0x078, 7, 0x300}, {0x079, 0x07a, 7, 0x800},
    {0x07b, 0x07c, 7, 0x900}, {0x07d, 0x07e, 7, 0xa00},
    {0x4a0, 0x49e, 6, 0xb00} }
end

local function source_label(source)
  local labels = {
    [1] = "Motherboard", [2] = "CPU (CPUTIN)", [3] = "Auxiliary 0",
    [4] = "Auxiliary 1", [5] = "Auxiliary 2", [6] = "Auxiliary 3",
    [7] = "Auxiliary 4", [8] = "SMBus Master 0", [9] = "SMBus Master 1",
    [10] = "T-Sensor", [16] = "CPU Package (PECI Agent 0)",
    [17] = "CPU (PECI Agent 1)", [18] = "PCH Chip CPU Max", [19] = "PCH Chip",
    [20] = "PCH CPU", [21] = "PCH MCH", [22] = "Agent 0 DIMM 0",
    [23] = "Agent 0 DIMM 1", [24] = "Agent 1 DIMM 0", [25] = "Agent 1 DIMM 1",
    [26] = "Byte Temp 0", [27] = "Byte Temp 1", [28] = "PECI Agent 0 Calibrated",
    [29] = "PECI Agent 1 Calibrated", [31] = "Virtual",
  }
  return labels[source] or "Unknown"
end

return {
  initialize = function(dev)
    dev.variant = variant_name(dev.match.chip_id, dev.match.revision)
    dev.info = variant_info(dev.variant)
    local result = {
      ok = dev.variant ~= nil and dev.match.hwm_base ~= nil and dev.match.hwm_base ~= 0,
      model = dev.variant or "Nuvoton Super I/O",
    }
    -- The matched Super-I/O is a sensor controller. Only dynamically-created
    -- `Fan 1…N` children own a PWM channel; assigning one to the root made the
    -- UI present the controller itself as a fan.
    if dev.match.key then
      result.capabilities = { "cooling" }
      result.cooling = { channels = {
        { id = "fan", name = dev.match.name or ("Fan " .. (channel(dev) + 1)), kind = "fan", controllable = not dev.info.ec },
      } }
    end
    return result
  end,
  enumerate_controllers = function(dev)
    if dev.match.key then return {} end
    local name = variant_name(dev.match.chip_id, dev.match.revision)
    if not name then return {} end
    local info = variant_info(name)
    if info.ec then return {} end -- native driver rejects unsafe shared-mode writes
    local out = {}
    for ch = 0, info.fans - 1 do
      out[#out + 1] = { index = ch, key = tostring(ch), id = string.format("superio_%d_fan_%02x_fan%d", dev.match.slot or 0, dev.match.chip_id, ch + 1), name = "Fan " .. (ch + 1), extra = { chip_id = dev.match.chip_id, revision = dev.match.revision, hwm_base = dev.match.hwm_base, slot = dev.match.slot } }
    end
    return out
  end,
  get_sensors = function(dev)
    if not keep_io_unlocked(dev) then return dev.sensor_cache or {} end
    local out, seen = {}, {}
    for _, slot in ipairs(temp_slots(dev.variant)) do
      local source, whole = read_hwm(dev, slot[4]) & 0x1f, read_hwm(dev, slot[1])
      if source ~= 0 and whole and not seen[source] then
        local signed = whole >= 0x80 and whole - 0x100 or whole
        local half = slot[3] and read_hwm(dev, slot[2]) or 0
        local value = signed + (slot[3] and (((half >> slot[3]) & 1) * 0.5) or 0)
        if value >= -55 and value <= 125 then
        seen[source] = true
          out[#out + 1] = { id = "nuvoton_src" .. source, name = source_label(source), value = value, unit = "celsius", sensor_type = "temperature" }
        end
      end
    end
    dev.sensor_cache = out
    return out
  end,
  get_cooling_status = function(dev, channel_id)
    assert(channel_id == "fan", "unknown cooling channel: " .. tostring(channel_id))
    if keep_io_unlocked(dev) then
      local reg = dev.info.pwm[channel(dev) + 1]
      dev.last_duty = reg and math.floor((read_hwm(dev, reg) * 100 + 127) / 255) or 0
      local tach = dev.info.tach[channel(dev) + 1]
      if tach then
        local high, low = read_hwm(dev, tach), read_hwm(dev, tach + 1)
        local count = dev.info.count16 and ((high << 8) | low) or ((high << 5) | (low & 0x1f))
        if dev.info.count16 then
          dev.last_rpm = (count > 0 and count < 0xffff) and math.floor(1350000 / count) or 0
        else
          dev.last_rpm = count > 0x14 and count < 0x1fff and math.floor(1350000 / count) or 0
        end
      end
    end
    return { id = "fan", name = dev.match.name or ("Fan " .. (channel(dev) + 1)), kind = "fan", controllable = not dev.info.ec, duty = dev.last_duty, rpm = dev.last_rpm or 0 }
  end,
  set_cooling_duty = function(dev, channel_id, duty)
    assert(channel_id == "fan", "unknown cooling channel: " .. tostring(channel_id))
    if not keep_io_unlocked(dev) then error("Nuvoton HWM register window is unavailable") end
    if dev.info.ec then error("per-channel manual control is unsafe on NCT668x shared mode") end
    local ch, mode, cmd = channel(dev) + 1, dev.info.mode[channel(dev) + 1], dev.info.cmd[channel(dev) + 1]
    if not mode or not cmd then error("fan channel has no writable PWM registers") end
    if dev.original_ctrl_mode == nil then dev.original_ctrl_mode = read_hwm(dev, mode) end
    write_hwm(dev, mode, 0)
    write_hwm(dev, cmd, math.min(255, math.floor(duty * 255 + 50) // 100))
  end,
  close = function(dev)
    if dev.original_ctrl_mode == nil or not keep_io_unlocked(dev) then return end
    local mode = dev.info.mode[channel(dev) + 1]
    if mode then write_hwm(dev, mode, dev.original_ctrl_mode) end
  end,
}
