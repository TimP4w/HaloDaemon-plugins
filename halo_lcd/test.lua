-- SPDX-License-Identifier: GPL-3.0-or-later

local date = halod.require("lib.date")

return function(h)
  local live=halod.require("lib.live_data")
  h:assert_eq(live.value({status="fresh",value=42}),42,"fresh input is rendered")
  h:assert_eq(live.value({status="stale",value=42}),nil,"retained stale input is not presented as current")
  h:assert_eq(live.value({status="unavailable"}),nil,"missing input is unavailable")

  local levels=halod.require("lib.levels")
  h:assert_eq(levels.gauge(nil,false),nil,"live missing gauge has no synthetic reading")
  h:assert_eq(levels.spectrum(nil,2,false),0,"live missing spectrum is empty")
  h:assert(levels.gauge(nil,true)>0,"preview retains sample gauge")
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
