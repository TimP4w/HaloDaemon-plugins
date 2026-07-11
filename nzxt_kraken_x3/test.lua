-- Exercised via `halod plugin-test <package-dir>`.

return function(h)
  local dev = h:open()

  h:assert(dev:initialize(), "initialize succeeds")
  h:assert_eq(#dev:writes(), 3, "initialize: INIT_SET + firmware push + status stream enable")
  h:assert_eq(dev:writes()[1].data, { 0x70, 0x02, 0x01, 0xB8, 0x01 }, "INIT_SET packet")
  h:assert_eq(dev:writes()[2].data, { 0x70, 0x01 }, "firmware push")
  h:assert_eq(dev:writes()[3].data, { 0x10, 0x01 }, "enable status stream")
  dev:clear()

  dev:apply({ mode = "static", color = { r = 10, g = 20, b = 30 } })
  local w = dev:writes()
  h:assert_eq(#w, 4, "static apply: 2 ring data packets + ring commit + logo")

  h:assert_eq(w[1].data[1], 0x22, "ring pkt0 opcode")
  h:assert_eq(w[1].data[2], 0x10, "ring pkt0 seq (pkt_num=0)")
  h:assert_eq(w[1].data[3], 0x02, "ring pkt0 channel (ring)")
  h:assert_eq(w[1].data[5], 20, "ring pkt0 led0 G")
  h:assert_eq(w[1].data[6], 10, "ring pkt0 led0 R")
  h:assert_eq(w[1].data[7], 30, "ring pkt0 led0 B")

  h:assert_eq(w[3].data[1], 0x22, "ring commit opcode")
  h:assert_eq(w[3].data[2], 0xA0, "ring commit sub")
  h:assert_eq(w[3].data[3], 0x02, "ring commit channel")

  h:assert_eq(w[4].data[1], 0x2A, "logo opcode")
  h:assert_eq(w[4].data[8], 20, "logo G")
  h:assert_eq(w[4].data[9], 10, "logo R")
  h:assert_eq(w[4].data[10], 30, "logo B")
end
