-- SPDX-License-Identifier: GPL-3.0-or-later

local M = {}

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

function M.format(now, translate)
  local month = MONTHS[now.month]
  local weekday = translate("date.weekday." .. now.weekday, now.weekday)
  month = translate("date.month." .. month, month)
  return string.format("%s, %d %s", weekday, now.day, month)
end

return M
