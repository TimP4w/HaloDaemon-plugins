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
  local function append(parts)
    for _, part in ipairs(parts) do reads[#reads + 1] = part end
  end
  append(reply(40, string.pack("<I4", 3)))
  append(reply(0, string.pack("<I4", 2)))
  append(reply(1, controller("Board", "ABC123", "HID: /dev/hidraw6", 12)))
  append(reply(1, controller("Empty", "", "", 4)))

  local dev = h:open_integration({ reads = reads })
  h:assert(dev:initialize(), "OpenRGB handshake succeeds")
  h:assert_eq(#dev:writes(), 2, "client name and protocol-version requests sent")

  local controllers = dev:enumerate_controllers()
  h:assert_eq(#controllers, 2, "two controllers enumerate")
  h:assert_eq(controllers[1].index, 0, "first controller index")
  h:assert_eq(controllers[1].name, "Board", "name has no trailing NUL")
  h:assert_eq(controllers[1].serial, "ABC123", "serial has no trailing NUL")
  h:assert_eq(controllers[1].location, "HID: /dev/hidraw6", "location has no trailing NUL")
  h:assert_eq(controllers[1].zones[1].led_count, 12, "zone data remains intact")
  h:assert_eq(controllers[2].index, 1, "second controller index")
  h:assert_eq(controllers[2].serial, nil, "empty serial is absent")
  h:assert_eq(controllers[2].location, nil, "empty location is absent")
end
