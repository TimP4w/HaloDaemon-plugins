-- SPDX-License-Identifier: GPL-2.0-or-later
-- HID++2 ONBOARD_PROFILES profile-sector codec (see docs/hidpp2.md).

local M = {}

local OFF = {
  report_rate = 0, dpi_default = 1, dpi_shift = 2, dpi = 3, dpi_colors = 13,
  power_save = 28, power_off = 30, buttons = 32, shifted = 96, name = 160, leds = 208,
}
M.BUTTONS, M.LEDS, M.LED_SIZE, M.NAME_SIZE, M.DPI_STEPS = 16, 4, 11, 48, 5
M.SIGNATURE_EFFECTS = { [0x0f] = 0x10, [0x18] = 0x19, [0x1a] = 0x1b }

local function u16le(b, i) return (b[i + 1] or 0) | ((b[i + 2] or 0) << 8) end

function M.decode_binding(b1, b2, b3, b4)
  if b1 == 0xff and b2 == 0xff and b3 == 0xff and b4 == 0xff then return { kind = "disabled" } end
  if b1 == 0x80 and b2 == 0x01 then return { kind = "mouse", buttons = (b3 << 8) | b4 } end
  if b1 == 0x80 and b2 == 0x02 then return { kind = "key", modifiers = b3, key = b4 } end
  if b1 == 0x80 and b2 == 0x03 then return { kind = "consumer", usage = (b3 << 8) | b4 } end
  if b1 == 0x90 then return { kind = "special", code = b2 } end
  if b1 == 0x00 then return { kind = "macro", page = b2, offset = b4 } end
  return { kind = "raw", bytes = { b1, b2, b3, b4 } }
end

function M.encode_binding(binding)
  local kind = binding.kind
  if kind == "disabled" then return 0xff, 0xff, 0xff, 0xff end
  if kind == "mouse" then return 0x80, 0x01, (binding.buttons >> 8) & 0xff, binding.buttons & 0xff end
  if kind == "key" then return 0x80, 0x02, binding.modifiers & 0xff, binding.key & 0xff end
  if kind == "consumer" then return 0x80, 0x03, (binding.usage >> 8) & 0xff, binding.usage & 0xff end
  if kind == "special" then return 0x90, binding.code & 0xff, 0, 0 end
  if kind == "macro" then return 0x00, binding.page & 0xff, 0, binding.offset & 0xff end
  if kind == "raw" then return table.unpack(binding.bytes) end
  error("unknown onboard binding kind: " .. tostring(kind))
end

local function bindings(b, base)
  local out = {}
  for i = 0, M.BUTTONS - 1 do
    local o = base + i * 4
    out[i + 1] = M.decode_binding(b[o + 1], b[o + 2], b[o + 3], b[o + 4])
  end
  return out
end

-- Decodes a full sector; `bytes` keeps the source so unknown bytes survive.
function M.parse(data)
  if #data < OFF.leds + M.LEDS * M.LED_SIZE + 2 then error("profile sector is too short") end
  local b = { data:byte(1, #data) }
  local p = {
    size = #data, bytes = b,
    report_rate = b[OFF.report_rate + 1], dpi_default = b[OFF.dpi_default + 1],
    dpi_shift = b[OFF.dpi_shift + 1], dpi = {}, dpi_colors = {},
    power_save = u16le(b, OFF.power_save), power_off = u16le(b, OFF.power_off),
    buttons = bindings(b, OFF.buttons), shifted = bindings(b, OFF.shifted),
    name = data:sub(OFF.name + 1, OFF.name + M.NAME_SIZE), leds = {},
    crc = (b[#data - 1] << 8) | b[#data],
  }
  for i = 0, M.DPI_STEPS - 1 do
    local value = u16le(b, OFF.dpi + i * 2)
    p.dpi[i + 1] = (value ~= 0 and value ~= 0xffff) and value or nil
    local c = OFF.dpi_colors + i * 3
    p.dpi_colors[i + 1] = { r = b[c + 1], g = b[c + 2], b = b[c + 3] }
  end
  for i = 0, M.LEDS - 1 do
    local o = OFF.leds + i * M.LED_SIZE
    local params = {}
    for k = 1, 10 do params[k] = b[o + 1 + k] end
    p.leds[i + 1] = { id = b[o + 1], params = params }
  end
  return p
end

function M.dpi_steps(p)
  local out = {}
  for i = 1, M.DPI_STEPS do if p.dpi[i] then out[#out + 1] = p.dpi[i] end end
  return out
end

-- Serializes every decoded field over the original bytes and appends the CRC.
function M.serialize(p, crc16)
  local b = {}
  for i = 1, p.size do b[i] = p.bytes[i] end
  local function put(offset, ...) for k, v in ipairs({ ... }) do b[offset + k] = v & 0xff end end
  put(OFF.report_rate, p.report_rate, p.dpi_default, p.dpi_shift)
  for i = 0, M.DPI_STEPS - 1 do
    local value = p.dpi[i + 1]
    if value then put(OFF.dpi + i * 2, value, value >> 8)
    elseif u16le(b, OFF.dpi + i * 2) ~= 0xffff then put(OFF.dpi + i * 2, 0, 0) end
    local c = p.dpi_colors[i + 1]
    put(OFF.dpi_colors + i * 3, c.r, c.g, c.b)
  end
  put(OFF.power_save, p.power_save, p.power_save >> 8)
  put(OFF.power_off, p.power_off, p.power_off >> 8)
  for i = 0, M.BUTTONS - 1 do
    put(OFF.buttons + i * 4, M.encode_binding(p.buttons[i + 1]))
    put(OFF.shifted + i * 4, M.encode_binding(p.shifted[i + 1]))
  end
  for i = 1, M.NAME_SIZE do b[OFF.name + i] = p.name:byte(i) or 0xff end
  for i = 0, M.LEDS - 1 do
    local led = p.leds[i + 1]
    put(OFF.leds + i * M.LED_SIZE, led.id, table.unpack(led.params))
  end
  local body = string.char(table.unpack(b, 1, p.size - 2))
  local crc = crc16(body)
  return body .. string.char((crc >> 8) & 0xff, crc & 0xff)
end

-- Records 1-2 run while active, 3-4 while power saving.
function M.signature(p)
  local id = p.leds[1].id
  if M.SIGNATURE_EFFECTS[id] then return id, M.SIGNATURE_EFFECTS[id] end
end

return M
