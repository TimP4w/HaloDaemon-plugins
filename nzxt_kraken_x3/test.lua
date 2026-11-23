-- Exercised via `halod plugin-test <package-dir>`.

return function(h)
  local dev = h:open()

  h:assert(dev:initialize(), "initialize succeeds")
  h:assert_eq(#dev:writes(), 3, "initialize: INIT_SET + firmware push + status stream enable")
  h:assert_eq(dev:writes()[1].data, { 0x70, 0x02, 0x01, 0xB8, 0x01 }, "INIT_SET packet")
  h:assert_eq(dev:writes()[2].data, { 0x70, 0x01 }, "firmware push")
  h:assert_eq(dev:writes()[3].data, { 0x10, 0x01 }, "enable status stream")
  dev:clear()

  h:assert_eq(#dev:poll_sensors(),0,"missing status never fabricates a temperature")
  local status = {}
  for i = 1, 26 do status[i] = 0 end
  status[1], status[16], status[17] = 0x75, 28, 7
  dev:queue_read(status)
  local sensors = dev:poll_sensors()
  h:assert_eq(sensors[1].value, 28.7, "valid liquid temperature is sampled")
  status[16], status[17] = 0xFF, 0xFF
  dev:queue_read(status)
  sensors = dev:poll_sensors()
  h:assert_eq(sensors[1].value, 28.7, "FF FF sentinel preserves the last valid temperature")

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
  dev:clear()
  dev:set_cooling_duty("pump",25)
  local pump=dev:writes()[1].data
  h:assert_eq({pump[1],pump[2],pump[3],pump[4]},{0x72,1,0,0},"X3 pump header")
  h:assert_eq(pump[5],25,"X3 pump fixed duty")
  h:assert_eq(pump[44],100,"X3 critical temperature overrides fixed duty")

  local reply = {}
  for i = 1, 64 do reply[i] = 0 end
  reply[1], reply[2], reply[15], reply[16], reply[22] = 0x21, 0x03, 2, 16, 20
  dev:queue_read(reply)
  local found = dev:enumerate_controllers()
  h:assert_eq(#found, 1, "the pump ring is not a chained accessory")
  h:assert_eq(found[1].name, "F140 RGB", "chained fan is found on any channel")
  h:assert(not found[1].has_cooling, "the X3 accessory header carries lighting only")

  dev:clear()
  dev:apply({ mode = "native_effect", id = "candle", params = { color = { r = 9, g = 8, b = 7 } } })
  w = dev:writes()
  h:assert_eq(#w, 3, "ring, logo and chain each get the effect")
  h:assert_eq({ w[1].data[3], w[1].data[5], w[1].data[6], w[1].data[59] }, { 0x02, 0x08, 50, 8 }, "candle on the 8-LED ring at fixed speed")
  h:assert_eq({ w[2].data[3], w[2].data[59] }, { 0x04, 1 }, "logo is a single LED")
  h:assert_eq({ w[3].data[3], w[3].data[59] }, { 0x01, 18 }, "chain uses the F140 RGB LED count")
end
