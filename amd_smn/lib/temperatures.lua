-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: LibreHardwareMonitor contributors
local function tctl(raw)
  local value = (raw >> 21) * 0.125
  if (raw & 0x00080000) ~= 0 or (raw & 0x00030000) == 0x00030000 then value = value - 49 end
  return value
end

local function ccd(raw)
  if raw == nil then return nil end
  raw = raw & 0xfff
  if raw == 0 then return nil end
  local value = raw * 0.125 - 305
  return value >= -55 and value < 125 and value or nil
end

local function layout(family,model)
  if family==0x1a and model<=0x2f then return 0x599f0,16,true end
  if model==0x61 or model==0x44 then return 0x59b08,8,false end
  if model==0x31 or model==0x71 or model==0x21 then return 0x59954,8,false end
end
return {tctl=tctl,ccd=ccd,layout=layout}
