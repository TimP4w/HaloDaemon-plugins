-- Recorded routing regression: initialization probes DDC on the primary USB
-- device; Ambiglow writes must go to the named companion.
return function(h)
  local dev = h:open()
  h:assert(dev:initialize(), "initialize remains usable when DDC probes time out")
  local writes = dev:usb_writes()
  h:assert(#writes > 0, "initialization records DDC control traffic")
  h:assert_eq(writes[1].device, "primary", "DDC routes to primary USB device")
  h:assert_eq(writes[1].request_type, 0x40, "DDC uses vendor control OUT")
  dev:clear()

  dev:apply({ mode = "static", color = { r = 1, g = 2, b = 3 } })
  local lighting = dev:usb_writes()
  h:assert(#lighting >= 2, "capture and frame writes were recorded")
  h:assert_eq(lighting[1].device, "ambiglow", "Ambiglow routes to companion USB device")
  h:assert_eq(lighting[#lighting].device, "ambiglow", "frame stays on companion USB device")
end
