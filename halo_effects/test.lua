-- SPDX-License-Identifier: GPL-3.0-or-later
return function(h)
  local live=halod.require("lib.live_data")
  h:assert_eq(live.value({status="fresh",value=42}),42,"fresh input is rendered")
  h:assert_eq(live.value({status="stale",value=42}),nil,"retained stale input is not presented as current")
  h:assert_eq(live.value({status="unavailable"}),nil,"missing input is unavailable")

end
