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

  local accessory = {}
  for i = 1, 64 do accessory[i] = 0 end
  accessory[1], accessory[2], accessory[16] = 0x21, 0x03, 19
  dev:queue_read(accessory)
  local children = dev:enumerate_controllers()
  local discovery_writes = dev:writes()
  h:assert_eq(#discovery_writes, 1, "accessory discovery command sent")
  h:assert_eq(discovery_writes[1].data, { 0x20, 0x03 }, "accessory discovery opcode")
  h:assert_eq(#children, 1, "only the RGB radiator fan is a connected child")
  h:assert_eq(children[1].name, "F120 RGB", "detected radiator fan model")
  h:assert(children[1].has_cooling, "radiator fan exposes cooling")
  h:assert(children[1].has_lighting, "radiator fan exposes lighting")
  local parent = dev:serialize()
  local parent_cooling, parent_lighting
  for _, capability in ipairs(parent.capabilities or {}) do
    if capability.kind == "cooling" then parent_cooling = capability end
    if capability.kind == "lighting" then parent_lighting = capability end
  end
  -- The radiator fan moved to the child, so the Kraken keeps only the pump. A
  -- cooling channel must never be reachable from both the parent and a child.
  h:assert(parent_cooling ~= nil, "Kraken keeps its pump cooling")
  h:assert_eq(#parent_cooling.data.channels, 1, "Kraken gives up the claimed fan channel")
  h:assert_eq(parent_cooling.data.channels[1].id, "pump", "the channel it keeps is the pump")
  -- The chainable channel is composed from its links, so it is not a plain zone.
  local ids = {}
  for _, channel in ipairs(parent_lighting.data.descriptor.channels) do
    ids[#ids + 1] = channel.id
  end
  h:assert_eq(ids, { "ring", "0" }, "ring is a plain zone, the fan chain is divisible")
  h:assert_eq(parent_lighting.data.descriptor.channels[2].division.max_leds, 40,
    "the fan chain reports its header capacity")
  dev:clear()

  local status = {}
  for i = 1, 26 do status[i] = 0 end
  status[1], status[16], status[17] = 0x75, 30, 5
  dev:queue_read(status)
  local sensors = dev:poll_sensors()
  h:assert_eq(sensors[1].value, 30.5, "valid liquid temperature is sampled")
  status[16], status[17] = 0xFF, 0xFF
  dev:queue_read(status)
  sensors = dev:poll_sensors()
  h:assert_eq(sensors[1].value, 30.5, "FF FF sentinel preserves the last valid temperature")

  dev:apply({ mode = "static", color = { r = 5, g = 6, b = 7 } })
  local aw = dev:writes()
  h:assert_eq(#aw, 2, "static apply sends ring data and its firmware commit")
  h:assert_eq(aw[1].data[1], 0x26, "lighting opcode")
  h:assert_eq(aw[1].data[2], 0x14, "lighting sub")
  h:assert_eq(aw[1].data[3], 0x01, "ring channel byte")
  h:assert_eq(aw[1].data[4], 0x01, "ring channel byte (repeated)")
  h:assert_eq(aw[1].data[5], 6, "ring led0 G")
  h:assert_eq(aw[1].data[6], 5, "ring led0 R")
  h:assert_eq(aw[1].data[7], 7, "ring led0 B")
  h:assert_eq(aw[2].data[1], 0x26, "lighting commit opcode")
  h:assert_eq(aw[2].data[2], 0x16, "lighting commit sub")
  h:assert_eq(aw[2].data[3], 0x01, "commit ring channel byte")
  h:assert_eq(aw[2].data[4], 0x01, "commit ring channel byte (repeated)")
  h:assert_eq(aw[2].data[5], 0x01, "commit fixed payload")
  h:assert_eq(aw[2].data[13], 0x32, "commit fixed timing value")
  h:assert_eq(aw[2].data[16], 0x01, "commit fixed payload terminator")
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
