-- SPDX-License-Identifier: GPL-3.0-or-later
return function(h)
  local live=halod.require("lib.live_data")
  h:assert_eq(live.value({status="fresh",value=42}),42,"fresh input is rendered")
  h:assert_eq(live.value({status="stale",value=42}),nil,"retained stale input is not presented as current")
  h:assert_eq(live.value({status="unavailable"}),nil,"missing input is unavailable")

  local stops=halod.require("lib.stops")
  local blue,red,green={r=0,g=0,b=255},{r=255,g=0,b=0},{r=0,g=255,b=0}
  local sorted=stops.sorted({{value=90,color=red},{value=20,color=blue},{value=55,color=green}})
  h:assert_eq(sorted[1].value,20,"stops sort by value")
  h:assert_eq(sorted[3].value,90,"highest stop sorts last")
  h:assert_eq(stops.color_at(sorted,-5).b,255,"readings below the first stop take its color")
  h:assert_eq(stops.color_at(sorted,500).r,255,"readings above the last stop take its color")
  h:assert_eq(stops.color_at(sorted,55).g,255.0,"a reading on a stop takes its color")
  local mid=stops.color_at(sorted,37.5)
  h:assert_eq(mid.g,127.5,"readings between stops blend toward the upper stop")
  h:assert_eq(mid.b,127.5,"readings between stops blend away from the lower stop")
  h:assert_eq(stops.color_at({},10).r,0,"an empty stop list is black")
  h:assert_eq(stops.level(sorted,20),0.0,"the first stop is an empty meter")
  h:assert_eq(stops.level(sorted,55),0.5,"the meter is linear across the stop span")
  h:assert_eq(stops.level(sorted,900),1.0,"the meter clamps above the last stop")
  local one={{value=50,color=red}}
  h:assert_eq(stops.level(one,49),0.0,"a single stop is empty below its value")
  h:assert_eq(stops.level(one,50),1.0,"a single stop is full from its value")

end
