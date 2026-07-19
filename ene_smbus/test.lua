return function(h)
  local reads = { 1 }
  for i = 0, 15 do reads[#reads + 1] = i end
  for _ = 1, 6 do reads[#reads + 1] = 0 end
  local version = "LED-0116"
  for i = 1, 16 do reads[#reads + 1] = i <= #version and version:byte(i) or 0 end
  for i = 0, 63 do reads[#reads + 1] = i == 2 and 4 or 0 end

  local dev = h:open({ smbus_reads = reads })
  h:assert(dev:initialize(), "ENE signature and configuration initialize")
  dev:clear()

  dev:apply({ mode = "static", color = { r = 1, g = 2, b = 3 } })
  local w = dev:smbus_writes()
  local block
  for _, op in ipairs(w) do
    if op.operation == "write_block_data" then block = op break end
  end
  h:assert(block ~= nil, "direct color block was written")
  h:assert_eq(block.cmd, 0x03, "ENE auto-increment block command")
  h:assert_eq(#block.data, 12, "four LEDs encoded")
  h:assert_eq(block.data[1], 1, "red wire byte")
  h:assert_eq(block.data[2], 3, "ENE swaps blue before green")
  h:assert_eq(block.data[3], 2, "green wire byte")
end
