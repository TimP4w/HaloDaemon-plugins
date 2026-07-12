-- Exercised via `halod plugin-test asus_aura_usb`. `initialize()` queries the
-- firmware string and the config table over HID, so we script those two input
-- reports; the config reports 2 ARGB channels (10 + 8 LEDs) and 3 fixed on-board
-- LEDs, which drives the zone layout the assertions below check.

return function(h)
  -- Build a 65-byte report as a 1-based byte array, with the given index→value
  -- overrides (indices are 1-based, so wire offset `o` is index `o + 1`).
  local function report(overrides)
    local r = {}
    for i = 1, 65 do r[i] = 0 end
    for idx, val in pairs(overrides) do r[idx] = val end
    return r
  end

  -- Firmware reply: 0xEC 0x02 then "AURA\0".
  local fw = report({ [1] = 0xEC, [2] = 0x02, [3] = 0x41, [4] = 0x55, [5] = 0x52, [6] = 0x41 })
  -- Config reply: 0xEC 0x30 then the config table at wire offset 4.
  --   argb_count @ offset 6  → index 7  = 2
  --   ch0 leds   @ offset 10 → index 11 = 10
  --   ch1 leds   @ offset 16 → index 17 = 8
  --   mb_leds    @ offset 31 → index 32 = 3
  local cfg = report({ [1] = 0xEC, [2] = 0x30, [7] = 2, [11] = 10, [17] = 8, [32] = 3 })

  local dev = h:open({ reads = { fw, cfg } })
  h:assert(dev:initialize(), "initialize succeeds")

  local w = dev:writes()
  h:assert_eq(#w, 6, "stop_gen2 + firmware + config + 3× set-direct (ch 0,1,2)")
  h:assert_eq(w[1].data[1], 0xEC, "stop_gen2 header")
  h:assert_eq(w[1].data[2], 0x52, "stop_gen2 marker")
  h:assert_eq(w[2].data[2], 0x82, "firmware query cmd")
  h:assert_eq(w[3].data[2], 0xB0, "config query cmd")
  h:assert_eq(w[4].data[2], 0x35, "set-direct cmd")
  h:assert_eq(w[4].data[3], 0, "first set-direct is channel 0 (on-board)")
  h:assert_eq(w[4].data[6], 0xFF, "MODE_DIRECT at byte 5")
  h:assert_eq(w[6].data[3], 2, "last set-direct is ARGB effect channel 2")
  dev:clear()

  -- Static: on-board zone (3 LEDs, direct channel 4) then argb_0 (10, ch0) and
  -- argb_1 (8, ch1) — one direct packet each, apply bit (0x80) set.
  dev:apply({ mode = "static", color = { r = 1, g = 2, b = 3 } })
  local sw = dev:writes()
  h:assert_eq(#sw, 3, "static → one direct packet per zone")
  h:assert_eq(sw[1].data[2], 0x40, "CMD_DIRECT")
  h:assert_eq(sw[1].data[3], 0x84, "on-board channel 4 + apply bit")
  h:assert_eq(sw[1].data[5], 3, "on-board LED count")
  h:assert_eq(sw[1].data[6], 1, "led0 R")
  h:assert_eq(sw[1].data[7], 2, "led0 G")
  h:assert_eq(sw[1].data[8], 3, "led0 B")
  h:assert_eq(sw[2].data[3], 0x80, "argb_0 channel 0 + apply bit")
  h:assert_eq(sw[2].data[5], 10, "argb_0 LED count")
  h:assert_eq(sw[3].data[3], 0x81, "argb_1 channel 1 + apply bit")
  h:assert_eq(sw[3].data[5], 8, "argb_1 LED count")
  dev:clear()

  -- Native effect: only the two ARGB effect channels (the on-board zone has no
  -- effect channel).
  dev:apply({ mode = "native_effect", id = "breathing", params = { color = { r = 9, g = 8, b = 7 } } })
  local ew = dev:writes()
  h:assert_eq(#ew, 2, "breathing → one 0x3B packet per ARGB effect channel")
  h:assert_eq(ew[1].data[2], 0x3B, "CMD_ADDR_EFFECT")
  h:assert_eq(ew[1].data[3], 1, "argb_0 effect channel = 1")
  h:assert_eq(ew[1].data[5], 0x02, "breathing mode byte")
  h:assert_eq(ew[1].data[6], 9, "effect R")
  h:assert_eq(ew[1].data[7], 8, "effect G")
  h:assert_eq(ew[1].data[8], 7, "effect B")
  h:assert_eq(ew[2].data[3], 2, "argb_1 effect channel = 2")
end
