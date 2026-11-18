-- SPDX-License-Identifier: MPL-2.0
-- SPDX-FileCopyrightText: LibreHardwareMonitor contributors
local M = {}
function M.rpm(raw_rpm, high, low)
  if raw_rpm then
    local rpm = (high << 8) | low
    return rpm < 0xffff and rpm or 0
  end
  local count = (high << 5) | (low & 0x1f)
  return count > 0x14 and count < 0x1fff and math.floor(1350000 / count) or 0
end
local NUVOTON_VENDOR_ID = 0x5ca3

-- False while the window is unprepared, locked by firmware or answering for a
-- different chip; the caller then re-runs the config-space sequence.
function M.hwm_ready(io, base, vendor_reg)
  local ok, id = pcall(function()
    return (io:lpcio_hwm_read(base, 0x8000 | vendor_reg) << 8) | io:lpcio_hwm_read(base, vendor_reg)
  end)
  return ok and id == NUVOTON_VENDOR_ID
end

function M.ec_read(io, base, register)
  local deadline = halod.monotonic_ms() + 500
  while io:lpcio_read_port(base + 4) ~= 0xff do
    if halod.monotonic_ms() >= deadline then error("Nuvoton EC window is busy") end
    halod.sleep_ms(1)
  end
  local ok, value = pcall(function()
    io:lpcio_write_port(base + 4, register >> 8)
    io:lpcio_write_port(base + 5, register & 0xff)
    return io:lpcio_read_port(base + 6)
  end)
  local released, release_error = pcall(function() io:lpcio_write_port(base + 4, 0xff) end)
  if not ok then error(value) end
  if not released then error(release_error) end
  return value
end
return M
