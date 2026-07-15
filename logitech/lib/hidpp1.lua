-- SPDX-License-Identifier: GPL-2.0-or-later
-- HID++ 1.0 receiver register access and paired-child enumeration.

return function(api)
  local DIRECT = 0xff

  local function read(dev, devnum, reg, args)
    args = args or ""
    local sub = 0x81 | ((reg >> 8) & 0x02)
    api.send(dev, api.packet(devnum, sub, reg & 0xff, args, false))
    return api.dispatch(dev, devnum, sub, reg & 0xff, false)
  end

  local function write(dev, devnum, reg, args)
    args = args or ""
    local sub = 0x80 | ((reg >> 8) & 0x02)
    api.send(dev, api.packet(devnum, sub, reg & 0xff, args, false))
  end

  local function receiver_children(dev, product_name, device_type)
    if dev.match.pid ~= 0xc547 then return {} end
    -- The count is not a dense upper bound: pairing slots remain sparse after
    -- unpairing and powered-off children may not be included in it.
    pcall(read, dev, DIRECT, 0x0002)
    local out = {}
    for slot = 1, 6 do
      local pair_ok, pair = pcall(read, dev, DIRECT, 0x02b5, api.bytes(0x20 + slot - 1))
      local hi, lo = pair_ok and pair:byte(4) or nil, pair_ok and pair:byte(5) or nil
      local wpid = hi and lo and ((hi << 8) | lo) or 0
      if wpid ~= 0 and wpid ~= 0xffff then
        local ext_ok, ext = pcall(read, dev, DIRECT, 0x02b5, api.bytes(0x30 + slot - 1))
        local a, b, c, d
        if ext_ok then a, b, c, d = ext:byte(2, 5) end
        local serial = a and b and c and d
          and string.format("%02X%02X%02X%02X", a, b, c, d) or nil
        if serial == "00000000" or serial == "FFFFFFFF" then serial = nil end
        out[#out + 1] = {
          index = slot, key = tostring(slot), serial = serial,
          id = serial and ("logitech_" .. serial)
            or string.format("logitech_%04x_%d", wpid, slot),
          name = product_name(nil, wpid), device_type = device_type(wpid),
          extra = { wpid = wpid },
        }
      end
    end
    return out
  end

  return { read = read, write = write, receiver_children = receiver_children }
end
