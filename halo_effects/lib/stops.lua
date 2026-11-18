-- SPDX-License-Identifier: GPL-3.0-or-later
local M = {}

function M.sorted(stops)
  local out = {}
  for i, stop in ipairs(stops) do
    out[i] = stop
  end
  table.sort(out, function(a, b) return a.value < b.value end)
  return out
end

function M.color_at(sorted, value)
  local count = #sorted
  if count == 0 then return { r = 0, g = 0, b = 0 } end
  if value <= sorted[1].value then return sorted[1].color end
  if value >= sorted[count].value then return sorted[count].color end
  for i = 2, count do
    local low, high = sorted[i - 1], sorted[i]
    if value <= high.value then
      local t = (value - low.value) / (high.value - low.value)
      return {
        r = low.color.r + (high.color.r - low.color.r) * t,
        g = low.color.g + (high.color.g - low.color.g) * t,
        b = low.color.b + (high.color.b - low.color.b) * t,
      }
    end
  end
  return sorted[count].color
end

function M.span(sorted)
  local count = #sorted
  if count == 0 then return 0.0, 0.0 end
  return sorted[1].value, sorted[count].value
end

function M.level(sorted, value)
  local low, high = M.span(sorted)
  if high - low <= 1e-6 then
    return (#sorted > 0 and value >= low) and 1.0 or 0.0
  end
  return math.max(0.0, math.min(1.0, (value - low) / (high - low)))
end

return M
