-- SPDX-License-Identifier: GPL-3.0-or-later
local M = {}
function M.gauge(value, preview)
  if value == nil then return preview and 0.62 or nil end
  return math.max(0, math.min(1, value))
end
function M.spectrum(value, index, preview)
  if value ~= nil then return value end
  return preview and (0.22 + 0.58 * math.abs(math.sin(index * 0.71))) or 0
end
return M
