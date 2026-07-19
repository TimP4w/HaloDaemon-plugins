-- SPDX-License-Identifier: GPL-3.0-or-later

local date = halod.require("lib.date")

return function(h)
  local now = { weekday = "Thu", day = 19, month = 3 }

  h:assert_eq(
    date.format(now, function(_, fallback) return fallback end),
    "Thu, 19 Mar",
    "date uses English fallback tokens"
  )

  local italian = {
    ["date.weekday.Thu"] = "Gio",
    ["date.month.Mar"] = "Mar",
  }
  h:assert_eq(
    date.format(now, function(key, fallback) return italian[key] or fallback end),
    "Gio, 19 Mar",
    "date resolves Italian weekday and month tokens"
  )
end
