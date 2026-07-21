-- Exercised via `halod plugin-test <package-dir>`.

return function(h)
  local dev = h:open()

  h:assert(dev:initialize(), "initialize succeeds")
  local w = dev:writes()
  h:assert_eq(#w, 2, "status-push interval config + detect_fans")
  h:assert_eq(w[1].data, { 0x60, 0x02, 0x01, 0xE8, 0x03, 0x01, 0xE8, 0x03 }, "status push interval (~1000ms)")
  h:assert_eq(w[2].data, { 0x60, 0x03 }, "detect_fans")

  local function cooling_ids()
    local out = {}
    for _, capability in ipairs(dev:serialize().capabilities or {}) do
      if capability.kind == "cooling" then
        for _, channel in ipairs(capability.data.channels) do out[#out + 1] = channel.id end
      end
    end
    return out
  end

  -- With nothing attached, every output's fan is an ordinary hub channel.
  h:assert_eq(cooling_ids(), { "0", "1", "2", "3", "4" }, "all five fans start on the hub")

  local accessory = {}
  for i = 1, 64 do accessory[i] = 0 end
  accessory[1], accessory[2] = 0x21, 0x03
  accessory[15], accessory[16] = 1, 19 -- one F120 RGB on channel 0
  dev:queue_read(accessory)
  local children = dev:enumerate_controllers()
  h:assert_eq(#children, 1, "detected accessory is exposed as one child")
  h:assert(children[1].has_cooling, "fan child exposes cooling")
  h:assert(children[1].has_lighting, "fan child exposes lighting")
  -- Channel 0's fan now belongs to that child alone.
  h:assert_eq(cooling_ids(), { "1", "2", "3", "4" }, "the hub gives up the claimed fan")
  dev:clear()

  local function status(rpm, duty)
    local r = {}
    for i = 1, 64 do r[i] = 0 end
    r[1], r[2] = 0x67, 0x02
    r[17] = 1 -- channel 0 fan type
    r[25], r[26] = rpm & 0xff, (rpm >> 8) & 0xff
    r[41] = duty
    return r
  end

  dev:queue_read(status(1200, 50))
  dev:queue_read(status(0, 0))
  dev:poll_sensors()
  local by_id = {}
  for _, channel in ipairs(dev:cached_cooling()) do by_id[channel.id] = channel end
  h:assert(by_id["0"] == nil, "the claimed fan is not cached on the hub either")
  h:assert_eq(by_id["1"].rpm, 0, "newest queued RPM wins")
  h:assert_eq(by_id["1"].duty, 0, "newest queued duty wins")

  dev:clear()
  dev:write_divided_frame("2", { 1, 2, 3, 4, 5, 6 })
  w = dev:writes()
  h:assert_eq(#w, 2, "RGB data and commit reports")
  h:assert_eq(w[1].data, { 0x26, 0x04, 0x04, 0x00, 2, 1, 3, 5, 4, 6 }, "channel 2 GRB payload")
  h:assert_eq(w[2].data[1], 0x26, "RGB commit command")
  h:assert_eq(w[2].data[2], 0x06, "RGB commit subcommand")
  h:assert_eq(w[2].data[3], 0x04, "RGB commit channel mask")

  dev:clear()
  dev:set_cooling_duty("3", 73)
  w = dev:writes()
  h:assert_eq(#w, 1, "one cooling-duty report")
  h:assert_eq(w[1].data[1], 0x62, "cooling command")
  h:assert_eq(w[1].data[2], 0x01, "cooling subcommand")
  h:assert_eq(w[1].data[3], 0x08, "fan channel 3 bitmask")
  h:assert_eq(w[1].data[7], 73, "duty stored in selected channel slot")
end
