-- Exercised via `halod plugin-test <package-dir>`. `initialize()` drains any
-- stale HID reports and then queries the LCD state — feed one empty
-- scripted read so `drain_hid` exits immediately and the LCD query's
-- unanswered read falls back to its (pcall-guarded) defaults.

return function(h)
  local dev = h:open({ reads = { {} } })

  h:assert(dev:initialize(), "initialize succeeds")
  local w = dev:writes()
  h:assert_eq(#w, 4, "INIT_SET + firmware push + status stream enable + LCD state query")
  h:assert_eq(w[1].data, { 0x70, 0x02, 0x01, 0xB8, 0x01 }, "INIT_SET packet")
  h:assert_eq(w[2].data, { 0x70, 0x01 }, "firmware push")
  h:assert_eq(w[3].data, { 0x10, 0x01 }, "enable status stream")
  h:assert_eq(w[4].data, { 0x30, 0x01 }, "LCD state query")
  dev:clear()

  dev:apply({ mode = "static", color = { r = 5, g = 6, b = 7 } })
  local aw = dev:writes()
  h:assert_eq(#aw, 1, "static apply sends only the ring channel (no accessory yet)")
  h:assert_eq(aw[1].data[1], 0x26, "lighting opcode")
  h:assert_eq(aw[1].data[2], 0x14, "lighting sub")
  h:assert_eq(aw[1].data[3], 0x01, "ring channel byte")
  h:assert_eq(aw[1].data[4], 0x01, "ring channel byte (repeated)")
  h:assert_eq(aw[1].data[5], 6, "ring led0 G")
  h:assert_eq(aw[1].data[6], 5, "ring led0 R")
  h:assert_eq(aw[1].data[7], 7, "ring led0 B")
  dev:clear()

  -- Q565 LCD streaming keeps HID command/ACK traffic on the primary stream
  -- while the header and payload route through allowlisted USB endpoint 0x02.
  dev:queue_read({})
  dev:queue_read({ 0x37, 0x01 })
  dev:queue_read({ 0x37, 0x02 })
  dev:lcd_stream_frame({ 1, 2, 3, 255 }, 1, 1, 0, false, 80)
  local uw = dev:usb_writes()
  h:assert_eq(#uw, 2, "LCD stream emits USB header and payload")
  h:assert_eq(uw[1].device, "primary", "LCD USB routes to composite primary")
  h:assert_eq(uw[1].endpoint, 0x02, "LCD header uses bulk OUT endpoint")
  h:assert_eq(uw[1].data[13], 0x08, "LCD bulk header selects Q565 mode")
  h:assert(#uw[2].data > 0, "LCD payload is non-empty")
end
