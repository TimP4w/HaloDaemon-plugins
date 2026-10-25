-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: LibreHardwareMonitor contributors
-- AMD Zen temperature decoding, derived from LibreHardwareMonitor Amd17Cpu.cs.

local TCTL = 0x00059800

-- A failed SMN register read is a missing sample, not a failed device.  The
-- native driver keeps the sensor online through transient reads and refreshes
-- it on the next poll; preserve that behaviour in the worker callback.
local function smn_read(dev, offset)
  local ok, value = pcall(function() return dev.transport:amd_smn_read(offset) end)
  return ok and value or nil
end

local function arch_label(family)
  if family == 0x17 then return "Zen / Zen+ / Zen 2" end
  if family == 0x19 then return "Zen 3 / Zen 4" end
  if family == 0x1a then return "Zen 5" end
  return "Zen"
end

local temperatures=halod.require("lib.temperatures")

return {
  initialize = function(dev)
    -- Opening the AMD SMN transport already proved this is a supported Zen
    -- package.  A temporary thermal-register read failure must not hide it.
    dev.model = "AMD Ryzen (" .. arch_label(dev.match.family) .. ")"
    return { ok = true, model = dev.model }
  end,
  get_sensors = function(dev)
    -- SMN temperature registers are noisy when sampled at UI/render cadence.
    -- Match the former native driver's one-second cache rather than issuing a
    -- fresh broker request for every consumer read.
    local now = halod.monotonic_ms()
    if dev.sensor_cache and now < (dev.sensor_cache_until or 0) then return dev.sensor_cache end
    local out, raw = {}, smn_read(dev, TCTL)
    if raw then
      local value = temperatures.tctl(raw)
      if value >= -55 and value <= 155 then
        out[#out + 1] = { id = "amd_ryzen_cpu_tctl_tdie", name = "Core (Tctl)", value = value, unit = "celsius", sensor_type = "temperature" }
      end
    end
    local model = dev.match.model or 0
    local base,count,turin=temperatures.layout(dev.match.family,model)
    if base then
      local values={}
      for i = 0,count-1 do
        local raw_ccd=smn_read(dev,base+i*4)
        local value = (not turin or (raw_ccd and (raw_ccd & 0x800)~=0)) and temperatures.ccd(raw_ccd) or nil
        if value then
          values[#values + 1] = value
          out[#out + 1] = { id = "amd_ryzen_cpu_ccd" .. (i + 1), name = "CCD" .. (i + 1) .. " (Tdie)", value = value, unit = "celsius", sensor_type = "temperature" }
        end
      end
      if #values > 1 then
        local max, sum = values[1], 0
        for _, value in ipairs(values) do max, sum = math.max(max, value), sum + value end
        out[#out + 1] = { id = "amd_ryzen_cpu_ccds_max", name = "CCDs Max (Tdie)", value = max, unit = "celsius", sensor_type = "temperature" }
        out[#out + 1] = { id = "amd_ryzen_cpu_ccds_avg", name = "CCDs Average (Tdie)", value = sum / #values, unit = "celsius", sensor_type = "temperature" }
      end
    end
    dev.sensor_cache, dev.sensor_cache_until = out, now + 1000
    return out
  end,
}
