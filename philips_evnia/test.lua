local function xor(bytes, seed)
  local x = seed
  for _, b in ipairs(bytes) do x = x ~ b end
  return x
end

local function reply(vcp, value)
  local frame = { 0x6e, 0x88, 0x02, 0x00, vcp, 0x00, 0x00, 0xFF, (value >> 8) & 0xFF, value & 0xFF }
  frame[#frame + 1] = xor(frame, 0x50)
  frame[#frame + 1] = 0x00
  return frame
end

local function ddc_writes(dev)
  local out = {}
  for _, w in ipairs(dev:usb_writes()) do
    if w.device == "primary" then out[#out + 1] = w.data end
  end
  return out
end

local function requested(dev, kind, code)
  for _, d in ipairs(ddc_writes(dev)) do
    if kind == "std" and d[3] == 0x82 and d[4] == 0x01 and d[5] == code then return true end
    if kind == "ext" and d[3] == 0x84 and d[4] == 0x01 and d[6] == 0xa0 and d[7] == code then return true end
  end
  return false
end

local function ext_set(dev, sub)
  local found = {}
  for _, d in ipairs(ddc_writes(dev)) do
    if d[3] == 0x86 and d[4] == 0x03 and d[7] == sub then found[#found + 1] = d[9] end
  end
  return found
end

local function boot(h, dc)
  local dev = h:open({ reads = { { 0x00 }, reply(0xDC, dc), reply(0x10, 50), reply(0x12, 50) } })
  h:assert(dev:initialize(), "initialize accepts partial DDC state")
  return dev
end

return function(h)
  local dev = h:open()
  h:assert(dev:initialize(), "initialize remains usable when DDC probes time out")
  local writes = dev:usb_writes()
  h:assert(#writes > 0, "initialization records DDC control traffic")
  h:assert_eq(writes[1].device, "primary", "DDC routes to primary USB device")
  h:assert_eq(writes[1].request_type, 0x40, "DDC uses vendor control OUT")
  dev:clear()

  dev:apply({ mode = "static", color = { r = 1, g = 2, b = 3 } })
  local lighting = dev:usb_writes()
  h:assert(#lighting >= 3, "host link, capture and frame writes were recorded")
  h:assert_eq(lighting[1].device, "ambiglow", "Ambiglow routes to companion USB device")
  h:assert_eq(#lighting[1].data, 1, "capture starts with the one-byte host-link write")
  h:assert_eq(lighting[1].data[1], 0x04, "host link is switched on before capture")
  h:assert_eq(lighting[#lighting].device, "ambiglow", "frame stays on companion USB device")
  dev:clear()

  dev:apply({ mode = "native_effect", id = "monitor", params = {} })
  local released = dev:usb_writes()
  h:assert_eq(#released[1].data, 64, "release writes the baseline region")
  h:assert_eq(#released[2].data, 1, "release then writes the host link")
  h:assert_eq(released[2].data[1], 0x00, "release switches the host link off")

  local hdr = boot(h, 0x24)
  h:assert(requested(hdr, "ext", 0x3D), "HDR init reads Light Enhancement")
  h:assert(not requested(hdr, "std", 0x87), "HDR init skips SDR-only sharpness")
  h:assert(not requested(hdr, "std", 0x14), "HDR init skips SDR-only color temperature")
  hdr:clear()
  hdr:set_choice("smart_image", 0)
  h:assert_eq(#ddc_writes(hdr), 0, "SDR preset is not written while the monitor is in HDR")
  hdr:set_range("sharpness", 40)
  h:assert_eq(#ddc_writes(hdr), 0, "SDR-only range is not written in HDR")
  hdr:set_range("brightness", 40)
  h:assert_eq(#ddc_writes(hdr), 1, "brightness stays writable in HDR")
  hdr:clear()
  hdr:apply({ mode = "native_effect", id = "static",
    params = { color = { r = 255, g = 16, b = 0 }, brightness = "Bright" } })
  local fx = hdr:usb_writes()
  h:assert_eq(#ddc_writes(hdr), 0, "colour effects run on the ENE controller, not over DDC")
  h:assert_eq(fx[1].data[1], 0x04, "colour effect takes the host link")
  h:assert_eq(fx[2].data[1], 0x00, "zone block selects the controller effect source")
  h:assert_eq(fx[2].data[2], 1, "Static is controller mode 1")
  h:assert_eq(fx[2].data[10], 0x04, "Bright maps to controller brightness 4")
  h:assert_eq(fx[2].data[16], 0x00, "zone block is written uncommitted")
  for slot = 4, 7 do
    h:assert_eq(#fx[slot].data, 3, "effect colour slot takes one RGB triple")
    h:assert_eq(fx[slot].data[2], 16, "effect colour slot carries the chosen RGB colour")
  end
  h:assert_eq(#fx, 9, "colour effect writes link, two blocks, four colour slots and two commits")
  h:assert_eq(#fx[8].data, 1, "commit is a single byte")
  h:assert_eq(fx[8].data[1], 0x01, "commit applies effect and colour together")
  hdr:clear()
  hdr:apply({ mode = "native_effect", id = "color_wave", params = { rainbow = true, speed = "High" } })
  local wave = hdr:usb_writes()
  h:assert_eq(#wave[1].data, 16, "switching colour effects does not rewrite the host link")
  h:assert_eq(wave[1].data[2], 6, "rainbow selects the next controller mode")
  h:assert_eq(wave[1].data[3], 0xFE, "High speed maps to 0xFE")
  hdr:clear()
  hdr:apply({ mode = "native_effect", id = "follow_video", params = { brightness = "Bright" } })
  h:assert_eq(ext_set(hdr, 0x19)[1], 1, "Follow Video selects scaler mode 1")
  h:assert_eq(ext_set(hdr, 0x1C)[1], 0, "scaler brightness is written by index")
  hdr:clear()
  hdr:apply({ mode = "native_effect", id = "follow_audio", params = {} })
  local ambi = 0
  for _, w in ipairs(hdr:usb_writes()) do
    if w.device == "ambiglow" then ambi = ambi + 1 end
  end
  h:assert_eq(ambi, 0, "switching between scaler effects leaves the ENE controller untouched")
  h:assert_eq(ext_set(hdr, 0x19)[1], 2, "Follow Audio selects scaler mode 2")
  hdr:clear()
  hdr:set_choice("smart_image_hdr", 2)
  h:assert_eq(ddc_writes(hdr)[1][7], 0x23, "HDR list index 2 selects HDR Photo")

  local sdr = boot(h, 0x00)
  h:assert(requested(sdr, "std", 0x87), "SDR init reads sharpness")
  h:assert(not requested(sdr, "ext", 0x3D), "SDR init skips HDR-only Light Enhancement")
  sdr:clear()
  sdr:set_range("light_enhancement", 2)
  h:assert_eq(#ddc_writes(sdr), 0, "HDR-only range is not written in SDR")
  sdr:set_choice("input_source", 1)
  local input = ddc_writes(sdr)[1]
  h:assert_eq(input[5], 0x60, "input source writes VCP 0x60")
  h:assert_eq(input[7], 0x15, "index 1 selects USB-C")
end
