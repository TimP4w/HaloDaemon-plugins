-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: HaloDaemon
--
-- Drives the Nanoleaf controller against the recording HTTP/UDP transports:
-- host initialize (info + power-on over HTTP), the per-panel topology a child
-- derives from panelLayout, per-panel frames streamed as v2 external-control
-- UDP datagrams (armed by a one-time HTTP effects write), and the single-LED
-- HTTP /state fallback when no layout is reported.

local LAYOUT = '{"name":"Shapes","firmwareVersion":"7.0.0","panelLayout":{"layout":{'
  .. '"numPanels":3,"sideLength":150,"positionData":['
  .. '{"panelId":100,"x":0,"y":0,"o":0,"shapeType":12},'
  .. '{"panelId":101,"x":100,"y":0,"o":0,"shapeType":12},'
  .. '{"panelId":102,"x":50,"y":100,"o":60,"shapeType":12}]}}}'

return function(h)
  -- Host initialize: controller info GET then the power-on PUT, all on the
  -- origin resolved from the `host` config field (OpenAPI port 16021).
  local host = h:open_integration()
  host:queue_http_response({ status = 200, body = '{"name":"Shapes","firmwareVersion":"7.0.0"}' })
  host:queue_http_response({ status = 204 })
  h:assert(host:initialize(), "host initialize succeeds")
  local host_reqs = host:http_requests()
  h:assert_eq(#host_reqs, 2, "info request followed by state request")
  h:assert_eq(host_reqs[1].method, "GET", "controller info is a GET")
  h:assert_eq(host_reqs[2].method, "PUT", "state change is a PUT")
  h:assert_eq(host_reqs[1].origin, "http://192.168.1.50:16021", "origin is the controller IP on 16021")
  h:assert(host_reqs[2].path:find("/state", 1, true) ~= nil, "state path targets /state")

  -- Child derives one LED per physical panel from panelLayout.
  local dev = h:open_integration()
  dev:queue_http_response({ status = 200, body = LAYOUT })
  local panel = dev:open_controller(0)
  local ok, channels = panel:initialize()
  h:assert(ok, "child initialize succeeds")
  h:assert_eq(#channels, 1, "child reports one lighting channel")
  h:assert_eq(channels[1].id, "panels", "channel spans the panel grid")
  h:assert_eq(channels[1].led_count, 3, "led_count matches panel count")
  h:assert_eq(channels[1].topology, "grid", "panels use grid topology")
  h:assert_eq(#channels[1].leds, 3, "one LED position per panel")
  local leds = channels[1].leds
  h:assert(math.abs(leds[1].x - 0.0) < 1e-6, "min-x panel normalizes to 0")
  h:assert(math.abs(leds[2].x - 1.0) < 1e-6, "max-x panel normalizes to 1")
  h:assert(math.abs(leds[3].y - 0.0) < 1e-6, "top panel is near 0")

  -- Engine frames stream as v2 external-control UDP datagrams. The first frame
  -- arms ext-control with one HTTP effects write, then sends over UDP.
  dev:queue_http_response({ status = 204 })
  panel:write_frame("panels", { 10, 20, 30, 40, 50, 60, 70, 80, 90 })
  local arm = dev:http_requests()[#dev:http_requests()]
  h:assert(arm.path:find("/effects", 1, true) ~= nil, "ext-control is armed via /effects")
  h:assert(arm.body:find("extControl", 1, true) ~= nil, "ext-control uses the extControl write")

  local sent = dev:udp_sent()
  h:assert_eq(#sent, 1, "one UDP datagram streamed")
  local d = sent[1]
  h:assert_eq(#d, 26, "datagram is 2-byte header + 8 bytes per panel")
  h:assert_eq(d:byte(1) * 256 + d:byte(2), 3, "header carries the panel count")
  h:assert_eq(d:byte(3) * 256 + d:byte(4), 100, "first block targets panel 100")
  h:assert_eq(d:byte(5), 10, "panel 100 red")
  h:assert_eq(d:byte(6), 20, "panel 100 green")
  h:assert_eq(d:byte(7), 30, "panel 100 blue")
  h:assert_eq(d:byte(8), 0, "white channel is zero")
  h:assert_eq(d:byte(11) * 256 + d:byte(12), 101, "second block targets panel 101")
  h:assert_eq(d:byte(19) * 256 + d:byte(20), 102, "third block targets panel 102")
  h:assert_eq(d:byte(23), 90, "panel 102 blue")

  -- A one-shot per-LED apply reuses the armed stream (no new HTTP), mapping the
  -- channel color map onto panels by zero-based index.
  panel:apply({ mode = "per_led", channels = { panels = {
    ["0"] = { r = 1, g = 2, b = 3 },
    ["2"] = { r = 7, g = 8, b = 9 },
  } } })
  local after = dev:udp_sent()
  h:assert_eq(#after, 2, "per-LED apply streams a second datagram")
  h:assert_eq(after[2]:byte(5), 1, "per-LED apply sets panel 0 red from the map")
  h:assert_eq(after[2]:byte(13), 0, "unmapped panel 1 defaults to off")
  h:assert_eq(after[2]:byte(21), 7, "per-LED apply sets panel 2 red from the map")

  -- No panelLayout reported: one logical LED driven through global HTTP /state.
  local flat = h:open_integration()
  flat:queue_http_response({ status = 200, body = '{"name":"Aurora"}' })
  local flat_panel = flat:open_controller(0)
  local flat_ok, flat_channels = flat_panel:initialize()
  h:assert(flat_ok, "fallback initialize succeeds")
  h:assert_eq(flat_channels[1].id, "all", "fallback channel is the whole controller")
  h:assert_eq(flat_channels[1].led_count, 1, "fallback declares a single LED")
  flat:queue_http_response({ status = 204 })
  flat_panel:write_frame("all", { 10, 20, 30 })
  local flat_last = flat:http_requests()[#flat:http_requests()]
  h:assert(flat_last.path:find("/state", 1, true) ~= nil, "fallback frame targets /state")
  h:assert_eq(#flat:udp_sent(), 0, "fallback path does not stream UDP")
end
