-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: HaloDaemon
--
-- Drives Hue discovery against the recording HTTPS transport and verifies that
-- CLIP color-light resources become stable Halo child devices.

return function(h)
 local gamut=halod.require("lib.gamut")
 local triangle={red={x=0,y=0},green={x=1,y=0},blue={x=0,y=1}}
 local x,y=gamut.clip(0.2,0.3,triangle)
 h:assert(math.abs(x-0.2)<1e-6 and math.abs(y-0.3)<1e-6,"in-gamut chromaticity stays unchanged")
 x,y=gamut.clip(0.8,0.8,triangle)
 h:assert(math.abs(x-0.5)<1e-6 and math.abs(y-0.5)<1e-6,"out-of-gamut chromaticity projects onto nearest edge")
  local dev = h:open_integration()
  local lights = [[{"data":[
    {"id":"light-a","metadata":{"name":"Desk lamp"},"color":{"xy":{"x":0.3,"y":0.3}}},
    {"id":"light-b","metadata":{"name":"Monitor strip"},"color":{"xy":{"x":0.2,"y":0.2}}},
    {"id":"dimmer-only","metadata":{"name":"White lamp"},"dimming":{"brightness":50}}
  ]}]]
  -- open_controller resolves its route through a fresh enumeration.
  dev:queue_http_response({ status = 200, body = lights })
  dev:queue_http_response({ status = 200, body = lights })

  h:assert(dev:initialize(), "initialize succeeds")

  local controllers = dev:enumerate_controllers()
  h:assert_eq(#controllers, 2, "color lights enumerate as devices")
  h:assert_eq(controllers[1].id, "hue_light_light-a", "light has a stable device id")
  h:assert_eq(controllers[1].key, "light-a", "CLIP resource id is preserved as the route")
  h:assert_eq(controllers[1].name, "Desk lamp", "Hue metadata supplies the device name")
  h:assert_eq(controllers[1].channels[1].led_count, 1, "each light exposes one RGB endpoint")
  h:assert_eq(controllers[2].name, "Monitor strip", "second color light enumerates")

  local child_ok, child_zones = dev:open_controller(controllers[1].index):initialize()
  h:assert(child_ok, "Hue light child initializes")
  h:assert_eq(#child_zones, 1, "Hue light child exposes its lighting zone")
  h:assert_eq(child_zones[1].id, "light", "Hue light zone retains its route")

  local reqs = dev:http_requests()
  h:assert_eq(#reqs, 2, "enumeration requests the CLIP light list")
  h:assert_eq(reqs[1].method, "GET", "light list is a GET")
  h:assert_eq(reqs[1].origin, "https://192.168.1.60", "origin resolves from the bridge host over https")
  h:assert(reqs[1].path:find("/clip/v2/resource/light", 1, true) ~= nil, "path targets the CLIP light resource")

 do
 local dev = h:open_integration()
 local lights = '{"data":[{"id":"light-a","metadata":{"name":"Desk lamp"},"color":{"xy":{"x":0.3,"y":0.3}}}]}'
 dev:queue_http_response({status=200,body=lights})
 h:assert(dev:initialize(), "initialization succeeds")
 local child = dev:open_controller(0)
 h:assert(child:initialize(), "light initializes")
 dev:queue_http_response({status=200,body='{"errors":[{"description":"device unreachable"}],"data":[]}'})
 local ok = pcall(function() child:apply({mode="static",color={r=255,g=0,b=0}}) end)
 h:assert(not ok, "application-level bridge errors must not be accepted as successful writes")

 end
end
