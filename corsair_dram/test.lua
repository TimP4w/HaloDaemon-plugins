return function(h)
  local function crc8(data)
    local crc = 0
    for _, byte in ipairs(data) do
      crc = (crc ~ byte) & 0xFF
      for _ = 1, 8 do
        crc = (crc & 0x80) ~= 0 and (((crc << 1) ~ 0x07) & 0xFF) or ((crc << 1) & 0xFF)
      end
    end
    return crc
  end

  local info = {}
  for i = 1, 32 do info[i] = 0 end
  info[1], info[2] = 0x1C, 0x1B
  info[3], info[4] = 0x00, 0x07 -- Vengeance DDR5, ten LEDs
  info[29] = 4                 -- direct block protocol
  local reads = { 0x1A, 0x01 }
  for _, byte in ipairs(info) do reads[#reads + 1] = byte end
  reads[#reads + 1] = crc8(info)

  local dev = h:open({ smbus_reads = reads })
  h:assert(dev:initialize(), "Corsair identity and CRC initialize")
  dev:clear()

  dev:apply({ mode = "static", color = { r = 4, g = 5, b = 6 } })
  local w = dev:smbus_writes()
  h:assert_eq(#w, 1, "ten-LED direct packet fits one SMBus block")
  h:assert_eq(w[1].cmd, 0x31, "first color-buffer register")
  h:assert_eq(#w[1].data, 32, "count + RGB data + CRC")
  h:assert_eq(w[1].data[1], 10, "LED count")
  h:assert_eq(w[1].data[2], 4, "first red byte")
  h:assert_eq(w[1].data[3], 5, "first green byte")
  h:assert_eq(w[1].data[4], 6, "first blue byte")
  local body = {}
  for i = 1, 31 do body[i] = w[1].data[i] end
  h:assert_eq(w[1].data[32], crc8(body), "direct packet CRC")
end
