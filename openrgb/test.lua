-- OpenRGB protocol-v3 enumeration fixture, exercised by `halod plugin-test`.
local function bytes(s)
  local out = {}
  for i = 1, #s do out[i] = s:byte(i) end
  return out
end

local function str(s)
  return string.pack("<I2", #s + 1) .. s .. "\0"
end

local function controller(name, serial, location, leds)
  return string.pack("<I4I4", 0, 0)
    .. str(name) .. str("Vendor") .. str("") .. str("1.0")
    .. str(serial) .. str(location)
    .. string.pack("<I2I4I2", 0, 0, 1)
    .. str("Zone") .. string.pack("<I4I4I4I4I2I4I4", 1, 1, leds, leds, 8, 0, 0)
    .. string.pack("<I2I2", 0, 0)
end

local function reply(packet, payload)
  return {
    bytes("ORGB"),
    bytes(string.pack("<I4I4I4", 0, packet, #payload)),
    bytes(payload),
  }
end

return function(h)
  local reads = {}
  local function append(target, parts)
    for _, part in ipairs(parts) do target[#target + 1] = part end
  end
  append(reads, reply(40, string.pack("<I4", 3)))
  append(reads, reply(0, string.pack("<I4", 2)))
  append(reads, reply(1, controller("Board", "ABC123", "HID: /dev/hidraw6", 12)))
  append(reads, reply(1, controller("Empty", "", "", 4)))
  -- open_controller resolves the route through a fresh enumeration.
  append(reads, reply(0, string.pack("<I4", 2)))
  append(reads, reply(1, controller("Board", "ABC123", "HID: /dev/hidraw6", 12)))
  append(reads, reply(1, controller("Empty", "", "", 4)))

  local dev = h:open_integration({ reads = reads })
  h:assert(dev:initialize(), "OpenRGB handshake succeeds")
  h:assert_eq(#dev:writes(), 2, "client name and protocol-version requests sent")

  local controllers = dev:enumerate_controllers()
  h:assert_eq(#controllers, 2, "two controllers enumerate")
  h:assert_eq(controllers[1].index, 0, "first controller index")
  h:assert_eq(controllers[1].name, "Board", "name has no trailing NUL")
  h:assert_eq(controllers[1].serial, "ABC123", "serial has no trailing NUL")
  h:assert_eq(controllers[1].location, "HID: /dev/hidraw6", "location has no trailing NUL")
  h:assert_eq(controllers[1].channels[1].led_count, 12, "zone data remains intact")
  local child_ok, child_zones = dev:open_controller(controllers[1].index):initialize()
  h:assert(child_ok, "controller child initializes")
  h:assert_eq(#child_zones, 1, "controller child reports its lighting zone")
  h:assert_eq(child_zones[1].id, "0", "controller child preserves the zone route")
  h:assert_eq(child_zones[1].led_count, 12, "controller child preserves the zone LED count")
  h:assert_eq(controllers[2].index, 1, "second controller index")
  h:assert_eq(controllers[2].serial, nil, "empty serial is absent")
  h:assert_eq(controllers[2].location, nil, "empty location is absent")

  local oversized = {}
  append(oversized, reply(40, string.pack("<I4", 3)))
  append(oversized, reply(0, string.pack("<I4", 257)))
  local bad = h:open_integration({ reads = oversized })
  h:assert(bad:initialize(), "oversized-count fixture handshakes")
  local ok, err = pcall(function() bad:enumerate_controllers() end)
  h:assert(not ok, "peer controller count above the host limit is rejected")
  h:assert(tostring(err):find("controller count 257 exceeds limit 256"),
    "oversized controller error identifies the violated bound")
end
