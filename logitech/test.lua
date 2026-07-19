-- HID++ feature discovery fixture.  The replies retain the raw report header;
-- this proves the package emits padded short ROOT and padded long FEATURE_SET
-- requests with software id 1, exactly like the former messenger.
return function(h)
  local function report(report_id, devnum, sub, address, data)
    local out = { report_id, devnum, sub, address }
    for _, b in ipairs(data or {}) do out[#out + 1] = b end
    while #out < 20 do out[#out + 1] = 0 end
    return out
  end

  local dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),             -- ROOT -> FEATURE_SET index
    report(0x11, 0xff, 0x02, 0x01, { 1 }),             -- FEATURE_SET count
    report(0x11, 0xff, 0x02, 0x11, { 0x10, 0x04 }),    -- UNIFIED_BATTERY
    report(0x11, 0xff, 0x01, 0x11, { 73, 0, 0 }),      -- initial battery cache fill
  } })
  h:assert(dev:initialize(), "feature enumeration initializes")
  local writes = dev:writes()
  h:assert_eq(#writes, 4, "ROOT + FEATURE_SET count/item + capability cache fill")
  h:assert_eq(writes[1].data[1], 0x10, "ROOT lookup uses a short report")
  h:assert_eq(#writes[1].data, 7, "short report is padded to 7 bytes")
  h:assert_eq(writes[1].data[3], 0x00, "ROOT feature index")
  h:assert_eq(writes[1].data[4], 0x01, "ROOT function with software id")
  h:assert_eq(writes[2].data[1], 0x11, "feature-index requests use a long report")
  h:assert_eq(#writes[2].data, 20, "long report is padded to 20 bytes")
  h:assert_eq(writes[3].data[4], 0x11, "FEATURE_SET getFeature function with software id")

  local waking_dev = h:open({ pid = 0xc095, reads = {
    {}, {}, -- first ROOT attempt exhausts its two empty read windows
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 0 }),
  } })
  h:assert(waking_dev:initialize(), "cold G502 retries its initial ROOT lookup")
  h:assert_eq(#waking_dev:writes(), 3,
    "cold-device retry repeats ROOT once before feature enumeration")

  -- The same UNIFIED_BATTERY feature is queried using its enumerated runtime
  -- index.  It reports percentage directly and byte 3 signals charging.
  local battery_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x10, 0x04 }),
    report(0x11, 0xff, 0x01, 0x11, { 73, 0, 1 }),
  } })
  h:assert(battery_dev:initialize(), "battery fixture initializes")
  local batteries = battery_dev:get_batteries()
  h:assert_eq(#batteries, 1, "unified battery produces one reading")
  h:assert_eq(batteries[1].level, 73, "unified battery percent")
  h:assert_eq(batteries[1].status, "charging", "unified battery charging state")

  -- ADJUSTABLE_DPI has an explicit list followed by a current-value query.
  -- Setting DPI must use function 0x30 and preserve sensor 0 in byte 5.
  local dpi_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x10, 0x04 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x22, 0x01 }),
    report(0x11, 0xff, 0x02, 0x11, { 0, 0x01, 0x90, 0x03, 0x20, 0, 0 }),
    report(0x11, 0xff, 0x02, 0x21, { 0, 0x03, 0x20 }),
    report(0x11, 0xff, 0x01, 0x11, { 73, 0, 0 }),
    report(0x11, 0xff, 0x02, 0x31, {}),
  } })
  h:assert(dpi_dev:initialize(), "DPI fixture initializes")
  dpi_dev:set_dpi(800)
  local dpi_writes = dpi_dev:writes()
  h:assert_eq(dpi_writes[5].data[4], 0x11, "DPI list uses function 0x10 with software id")
  h:assert_eq(dpi_writes[6].data[4], 0x21, "DPI current uses function 0x20 with software id")
  h:assert_eq(dpi_writes[8].data[4], 0x31, "DPI set uses function 0x30 with software id")
  h:assert_eq(dpi_writes[8].data[5], 0, "DPI set selects sensor zero")
  h:assert_eq(dpi_writes[8].data[6], 0x03, "DPI set high byte")
  h:assert_eq(dpi_writes[8].data[7], 0x20, "DPI set low byte")
  local dpi_status = dpi_dev:dpi_status()
  h:assert_eq(#dpi_status.available_dpis, 2, "DPI exposes the exact hardware value list")
  h:assert_eq(dpi_status.available_dpis[1], 400, "DPI list keeps its first exact point")
  h:assert_eq(dpi_status.available_dpis[2], 800, "DPI list keeps its second exact point")

  -- Full daemon state snapshots run every 250 ms. Onboard status must use the
  -- state populated during initialization instead of re-reading the directory
  -- and active-profile flash sectors on every serialization pass.
  local onboard_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x00 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 0, 1, 0, 0, 0, 16 }),
    report(0x11, 0xff, 0x01, 0x21, { 1 }),
    report(0x11, 0xff, 0x01, 0x51, { 0, 1, 1, 0 }),
    report(0x11, 0xff, 0x01, 0x41, { 0, 1 }),
    report(0x11, 0xff, 0x01, 0x51, { 0, 0, 0, 0 }),
    report(0x11, 0xff, 0x01, 0x21, { 1 }), -- initial host status-cache fill
  } })
  h:assert(onboard_dev:initialize(), "onboard-profile fixture initializes")
  onboard_dev:clear()
  onboard_dev:serialize()
  onboard_dev:serialize()
  h:assert_eq(#onboard_dev:writes(), 0,
    "state serialization serves cached onboard profiles without HID writes")

  -- A mode switch can take effect while its acknowledgement is lost during
  -- the transition. Confirm the live mode before retrying or surfacing the
  -- transport timeout.
  local mode_switch_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x00 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 0, 1, 0, 0, 0, 16 }),
    report(0x11, 0xff, 0x01, 0x21, { 1 }),
    report(0x11, 0xff, 0x01, 0x51, { 0, 1, 1, 0 }),
    report(0x11, 0xff, 0x01, 0x41, { 0, 1 }),
    report(0x11, 0xff, 0x01, 0x51, { 0, 0, 0, 0 }),
    report(0x11, 0xff, 0x01, 0x21, { 1 }), -- initial host status-cache fill
    {}, {},                                -- setMode acknowledgement is lost
    report(0x11, 0xff, 0x01, 0x21, { 2 }), -- getMode confirms it was applied
  } })
  h:assert(mode_switch_dev:initialize(), "mode-switch fixture initializes")
  mode_switch_dev:clear()
  mode_switch_dev:set_boolean("host_mode", true)
  local mode_switch_writes = mode_switch_dev:writes()
  h:assert_eq(#mode_switch_writes, 2, "lost setMode acknowledgement uses one read-back")
  h:assert_eq(mode_switch_writes[1].data[4], 0x11, "host mode uses setMode")
  h:assert_eq(mode_switch_writes[2].data[4], 0x21, "timed-out setMode reads mode back")

  -- MOUSE_BUTTON_SPY devices use the native sparse physical-button table and
  -- seed the same default DPI actions as the former native profile.
  local mapped_dev = h:open({ pid = 0xc095, reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x10 }),
    report(0x11, 0xff, 0x01, 0x11, {}), -- first SPY enable
  } })
  h:assert(mapped_dev:initialize(), "G502 X button fixture initializes")
  local remap = mapped_dev:key_remap_status()
  h:assert_eq(#remap.buttons, 11, "G502 X exposes only its physical bitmap buttons")
  h:assert_eq(remap.buttons[1].label, "G9", "G502 X uses native button names")
  h:assert_eq(remap.buttons[5].label, "Right Click", "G502 X keeps sparse native ordering")
  h:assert_eq(#remap.mappings, 3, "G502 X seeds every native default mapping")
  local g8
  for _, mapping in ipairs(remap.mappings) do if mapping.cid == 2 then g8 = mapping end end
  h:assert(g8 and g8.base.type == "dpi_cycle", "G502 X G8 defaults to DPI cycle")

  -- Replacing one host action with another leaves this global backend enabled;
  -- it must not resend setSpyState and wait for a redundant acknowledgement.
  mapped_dev:set_button_mapping({ cid = 1,
    base = { type = "media_key", key = "play" }, shifted = { type = "native" } })
  mapped_dev:clear()
  mapped_dev:set_button_mapping({ cid = 1, base = { type = "macro", steps = {
    { kind = { kind = "key_down", key = 0x41 }, delay_after_ms = 0 },
    { kind = { kind = "key_up", key = 0x41 }, delay_after_ms = 0 },
  } }, shifted = { type = "native" } })
  h:assert_eq(#mapped_dev:writes(), 0,
    "replacing a SPY mapping does not redundantly re-enable global reporting")

  -- Firmware ignores button divert while a mouse is in onboard mode, so remap
  -- only works in host mode. A mouse with ONBOARD_PROFILES must advertise that
  -- requirement and report the live mode so the UI can prompt the user.
  local function onboard_remap_dev(mode)
    return h:open({ pid = 0xc095, reads = {
      report(0x10, 0xff, 0x00, 0x01, { 2 }),
      report(0x11, 0xff, 0x02, 0x01, { 2 }),
      report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x00 }), -- ONBOARD_PROFILES
      report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x10 }), -- MOUSE_BUTTON_SPY
      report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 0, 1, 0, 0, 0, 16 }),
      report(0x11, 0xff, 0x01, 0x21, { mode }),
      report(0x11, 0xff, 0x01, 0x51, { 0, 1, 1, 0 }),
      report(0x11, 0xff, 0x01, 0x41, { 0, 1 }),
      report(0x11, 0xff, 0x01, 0x51, { 0, 0, 0, 0 }),
    } })
  end
  local onboard_mode_dev = onboard_remap_dev(1)
  h:assert(onboard_mode_dev:initialize(), "onboard-mode mouse remap fixture initializes")
  local onboard_remap = onboard_mode_dev:key_remap_status()
  h:assert(onboard_remap.requires_host_mode, "onboard mouse requires host mode for remap")
  h:assert(not onboard_remap.host_mode_active, "onboard-mode mouse reports host mode inactive")
  local host_mode_dev = onboard_remap_dev(2)
  h:assert(host_mode_dev:initialize(), "host-mode mouse remap fixture initializes")
  h:assert(host_mode_dev:key_remap_status().host_mode_active,
    "host-mode mouse reports host mode active")

  -- A LIGHTSPEED receiver uses HID++ 1.0 register reads at devnum 0xff to
  -- enumerate paired slots. The child receives slot 1 as its opaque key.
  local receiver = h:open({ pid = 0xc547, reads = {
    report(0x10, 0xff, 0x81, 0x02, { 0, 1 }),
    report(0x10, 0xff, 0x83, 0xb5, { 0, 0, 0, 0x40, 0xb0 }),
    report(0x10, 0xff, 0x83, 0xb5, { 0, 0xab, 0xcd, 0xef, 0x12 }),
  } })
  h:assert(receiver:initialize(), "receiver root initializes")
  local children = receiver:enumerate_controllers()
  h:assert_eq(#children, 1, "receiver enumerates one paired slot")
  h:assert_eq(children[1].id, "logitech_ABCDEF12", "receiver child has stable serial id")
  h:assert_eq(children[1].device_type, "keyboard", "receiver WPID preserves keyboard type")
  local receiver_writes = receiver:writes()
  h:assert_eq(receiver_writes[1].data[3], 0x81, "device count uses HID++ 1.0 short read")
  h:assert_eq(receiver_writes[2].data[3], 0x83, "receiver-info uses banked HID++ 1.0 read")
  h:assert_eq(receiver_writes[2].data[5], 0x20, "pairing info slot selector")
  h:assert_eq(receiver_writes[3].data[5], 0x30, "extended-pairing selector")

  -- Receiver behavior is a device capability shared by the HID++ 1.x
  -- families, not a special case tied to the C547 LIGHTSPEED PID. The pairing
  -- record's kind nibble identifies devices unknown to the small WPID catalog.
  local unifying = h:open({ pid = 0xc52b, reads = {
    report(0x10, 0xff, 0x81, 0x02, { 0, 1 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0, 0, 0, 0x12, 0x34, 0, 0, 0x02 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0, 0x12, 0x34, 0x56, 0x78 }),
  } })
  h:assert(unifying:initialize(), "Unifying receiver root initializes")
  local unifying_children = unifying:enumerate_controllers()
  h:assert_eq(#unifying_children, 1, "Unifying receiver enumerates paired slot")
  h:assert_eq(unifying_children[1].device_type, "mouse", "pairing-record kind supplies device type")

  local wireless_child = h:open({ key = "1", reads = {
    report(0x10, 0x01, 0x00, 0x01, { 2 }),
    report(0x11, 0x01, 0x02, 0x01, { 0 }),
  } })
  h:assert(wireless_child:initialize(), "receiver child initializes")
  h:assert_eq(wireless_child:connection_status().connection_type, "wireless", "receiver child reports wireless connection")

  local rate_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x61 }),
    report(0x11, 0xff, 0x01, 0x11, { 0, 0x09 }),
    report(0x11, 0xff, 0x01, 0x21, { 3 }),
    report(0x11, 0xff, 0x01, 0x31, {}),
  } })
  h:assert(rate_dev:initialize(), "report-rate fixture initializes")
  rate_dev:set_choice("report_rate", 1)
  local rate_writes = rate_dev:writes()
  h:assert_eq(rate_writes[6].data[4], 0x31, "extended report-rate set function")
  h:assert_eq(rate_writes[6].data[5], 3, "report-rate writes advertised wire index")

  local rgb_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x71 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 1 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 0, 1 }), -- one effect in zone 0
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 1 }),    -- static is slot 0
    report(0x11, 0xff, 0x01, 0x51, {}),                 -- software control
    report(0x11, 0xff, 0x01, 0x51, {}),                 -- reclaim before apply
    report(0x11, 0xff, 0x01, 0x11, {}),                 -- static apply
  } })
  h:assert(rgb_dev:initialize(), "RGB-effects fixture initializes")
  rgb_dev:apply({ mode = "static", color = { r = 0x12, g = 0x34, b = 0x56 } })
  local rgb_writes = rgb_dev:writes()
  h:assert_eq(rgb_writes[8].data[4], 0x51, "RGB-effects apply reclaims software control")
  h:assert_eq(rgb_writes[9].data[4], 0x11, "RGB-effects static uses SetEffect function")
  h:assert_eq(rgb_writes[9].data[5], 0, "RGB-effects static zone")
  h:assert_eq(rgb_writes[9].data[7], 0x12, "RGB-effects red payload")
  h:assert_eq(rgb_writes[9].data[9], 0x56, "RGB-effects blue payload")
  h:assert_eq(rgb_writes[9].data[10], 0x64, "RGB-effects static timing preset")

  -- EQUALIZER reads its band count/range, frequencies and signed levels.  The
  -- writable custom curve must use function 0x30 with the mandatory 0x02
  -- prefix, mirroring the former native HID++ codec.
  local eq_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x83, 0x10 }),
    report(0x11, 0xff, 0x01, 0x01, { 2, 12, 0, 0, 0 }),
    report(0x11, 0xff, 0x01, 0x11, { 0, 0, 31, 0, 250 }),
    report(0x11, 0xff, 0x01, 0x21, { 0xfb, 6 }),
    report(0x11, 0xff, 0x01, 0x31, {}),
  } })
  h:assert(eq_dev:initialize(), "equalizer fixture initializes")
  local eq = eq_dev:get_equalizer()
  h:assert_eq(#eq.bands, 2, "equalizer exposes all bands")
  h:assert_eq(eq.bands[1].label, "31 Hz", "equalizer labels low frequencies")
  h:assert_eq(eq.bands[2].value, 6.0, "equalizer decodes signed band values")
  eq_dev:set_eq_bands({ -20, 7 })
  local eq_writes = eq_dev:writes()
  h:assert_eq(eq_writes[#eq_writes].data[4], 0x31, "equalizer set uses function 0x30")
  h:assert_eq(eq_writes[#eq_writes].data[5], 0x02, "equalizer set carries custom prefix")
  h:assert_eq(eq_writes[#eq_writes].data[6], 0xf4, "equalizer set clamps to device db minimum")
  h:assert_eq(eq_writes[#eq_writes].data[7], 7, "equalizer set preserves valid values")
  h:assert_eq(eq_dev:get_equalizer().bands[1].value, -12.0, "successful EQ write updates cached value")
  h:assert(not pcall(function() eq_dev:set_eq_bands({ 0, 0 }) end), "failed EQ write surfaces")
  h:assert_eq(eq_dev:get_equalizer().bands[1].value, -12.0, "failed EQ write preserves cached value")

  local native_dev = h:open({ pid = 0xc352, reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x71 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 1 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 0, 1 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 1 }),
    report(0x11, 0xff, 0x01, 0x51, {}),
    report(0x11, 0xff, 0x01, 0x51, {}),
    report(0x11, 0xff, 0x01, 0x11, {}),
  } })
  h:assert(native_dev:initialize(), "native-effect fixture initializes")
  native_dev:apply({ mode = "native_effect", id = "ripple", params = {
    background = { r = 1, g = 2, b = 3 }, rate = 25, saturation = 50,
  } })
  local native_writes = native_dev:writes()
  h:assert_eq(native_writes[8].data[4], 0x51, "native effect reclaims RGB software control")
  h:assert_eq(native_writes[9].data[4], 0x11, "native effect uses RGB SetEffect")
  h:assert_eq(native_writes[9].data[5], 0xff, "native effect addresses every zone")
  h:assert_eq(native_writes[9].data[6], 0x03, "native effect selects ripple slot")
  h:assert_eq(native_writes[9].data[7], 1, "native effect overlays background red")
  h:assert_eq(native_writes[9].data[9], 3, "native effect overlays background blue")
  h:assert_eq(native_writes[9].data[10], 127, "native effect scales saturation")
  h:assert_eq(native_writes[9].data[14], 25, "native effect overlays rate")

  local mouse_rgb_dev = h:open({ pid = 0xc095, reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x71 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x81 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 1 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 0, 1 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 1 }),
    report(0x11, 0xff, 0x03, 0x01, { 0, 0, 0xfe, 0x01 }),
    report(0x11, 0xff, 0x03, 0x01, { 0, 0 }),
    report(0x11, 0xff, 0x03, 0x01, { 0, 0 }),
    report(0x11, 0xff, 0x02, 0x01, { 0, 0, 0xfe, 0x01 }), -- firmware LEDs 1..8
    report(0x11, 0xff, 0x02, 0x01, { 0, 0 }),
    report(0x11, 0xff, 0x02, 0x01, { 0, 0 }),
    report(0x11, 0xff, 0x01, 0x51, {}),
  } })
  h:assert(mouse_rgb_dev:initialize(), "G502 per-LED fixture initializes")
  mouse_rgb_dev:clear()
  local mouse_frame = {}
  for i = 1, 8 do
    mouse_frame[#mouse_frame + 1] = i
    mouse_frame[#mouse_frame + 1] = i + 10
    mouse_frame[#mouse_frame + 1] = i + 20
  end
  mouse_rgb_dev:write_frame("zone_0", mouse_frame)
  local mouse_writes = mouse_rgb_dev:writes()
  h:assert_eq(#mouse_writes, 3, "G502 frame uses two explicit batches plus commit")
  h:assert_eq(mouse_writes[1].data[4], 0x11, "G502 pixmap uses SET_INDIVIDUAL")
  h:assert_eq(mouse_writes[2].data[4], 0x11, "G502 second half uses SET_INDIVIDUAL")
  local addressed = {}
  for packet_index = 1, 2 do
    for offset = 5, 17, 4 do addressed[mouse_writes[packet_index].data[offset]] = true end
  end
  for id = 1, 8 do h:assert(addressed[id], "G502 pixmap explicitly addresses LED " .. id) end
  h:assert_eq(mouse_writes[3].data[4], 0x71, "G502 explicit frame commits atomically")

  -- A real per-key keyboard fixture exercises the runtime keyboard topology
  -- (including the acronym's serde spelling) and the streaming frame encoder.
  local keyboard_dev = h:open({ pid = 0xc352, reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 3 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x71 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x10, 0x04 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x81 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 1 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 0, 1 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 1 }),
    report(0x11, 0xff, 0x03, 0x01, { 0, 0, 0xfe, 0x01 }), -- firmware LEDs 1..8
    report(0x11, 0xff, 0x03, 0x01, { 0, 0 }),
    report(0x11, 0xff, 0x03, 0x01, { 0, 0 }),
    report(0x11, 0xff, 0x01, 0x51, {}),
    report(0x11, 0xff, 0x01, 0x51, {}), -- reclaim before Paint apply
  } })
  h:assert(keyboard_dev:initialize(), "per-key TKL fixture initializes")
  local keyboard = keyboard_dev:keyboard_layout_status()
  h:assert(#keyboard.keys > 80, "keyboard layout exposes physical keys")
  local key_a, media_brightness
  for _, key in ipairs(keyboard.keys) do
    if key.led_id == 1 then key_a = key end
    if key.led_id == 150 then media_brightness = key end
  end
  h:assert(key_a and key_a.cell.id == "a", "firmware LED 1 maps to the A key")
  h:assert(media_brightness ~= nil, "keyboard layout includes Logitech media keys")
  local keyboard_lighting = keyboard_dev:lighting_descriptor()
  local led_a
  for _, led in ipairs(keyboard_lighting.channels[1].leds) do if led.id == 1 then led_a = led end end
  h:assert(led_a ~= nil, "keyboard RGB descriptor contains firmware LED 1")
  h:assert(math.abs(led_a.x - ((key_a.cell.col + key_a.cell.w / 2) / 18)) < 0.0001,
    "keyboard RGB uses the native key x position")
  h:assert(math.abs(led_a.y - ((key_a.cell.row + 1.5) / 7)) < 0.0001,
    "keyboard RGB uses the native key y position")
  keyboard_dev:clear()
  local breathing = {}
  for _ = 1, 8 do
    breathing[#breathing + 1] = 10
    breathing[#breathing + 1] = 20
    breathing[#breathing + 1] = 30
  end
  keyboard_dev:write_frame("zone_0", breathing)
  local frame_writes = keyboard_dev:writes()
  h:assert_eq(#frame_writes, 2, "uniform per-key frame is one range plus commit")
  h:assert_eq(frame_writes[1].data[4], 0x51, "per-key frame uses SET_RANGE")
  h:assert_eq(frame_writes[1].data[5], 1, "per-key range starts at first firmware LED")
  h:assert_eq(frame_writes[1].data[6], 8, "per-key range ends at last firmware LED")
  h:assert_eq(frame_writes[2].data[4], 0x71, "per-key frame commits atomically")
  keyboard_dev:clear()
  local led_4_index
  for i, led in ipairs(keyboard_lighting.channels[1].leds) do
    if led.id == 4 then led_4_index = i end
  end
  h:assert(led_4_index ~= nil, "keyboard RGB descriptor contains firmware LED 4")
  -- The descriptor is zero-based at the protocol boundary; frame bytes remain
  -- a flat, one-based Lua sequence, so LED id 4 starts after four RGB triples.
  local led_4_offset = led_4_index * 3
  breathing[led_4_offset + 1] = 255
  breathing[led_4_offset + 2] = 0
  breathing[led_4_offset + 3] = 0
  keyboard_dev:write_frame("zone_0", breathing)
  local one_led = keyboard_dev:writes()
  h:assert_eq(#one_led, 2, "one changed LED is one range plus commit")
  h:assert_eq(one_led[1].data[5], 4, "single-LED update addresses its firmware LED")
  h:assert_eq(one_led[1].data[6], 4, "single-LED range contains only that LED")
  keyboard_dev:clear()
  keyboard_dev:apply({ mode = "per_led", channels = {
    zone_0 = { ["6"] = { r = 0x44, g = 0x55, b = 0x66 } },
  } })
  local paint = keyboard_dev:writes()
  h:assert_eq(#paint, 3, "Paint mode reclaims control, sends one individual packet, and commits")
  h:assert_eq(paint[1].data[4], 0x51, "Paint mode reclaims RGB software control")
  h:assert_eq(paint[2].data[4], 0x11, "Paint mode uses SET_INDIVIDUAL")
  h:assert_eq(paint[2].data[5], 6, "Paint mode preserves the firmware LED id")
  h:assert_eq(paint[2].data[6], 0x44, "Paint mode writes the selected red value")
  h:assert_eq(paint[2].data[7], 0x55, "Paint mode writes the selected green value")
  h:assert_eq(paint[2].data[8], 0x66, "Paint mode writes the selected blue value")
  h:assert_eq(paint[2].data[9], 6, "Paint mode pads with the same LED, never LED zero")
  h:assert_eq(paint[3].data[4], 0x71, "Paint mode commits the sparse edit")

  -- On Windows a long request is written to the companion collection and a
  -- short one to the primary, but a reply is matched wherever it lands.  With a
  -- companion advertised, the short ROOT lookup routes to primary and the long
  -- FEATURE_SET calls to the companion.
  local comp_dev = h:open({ companion = true, reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x10, 0x04 }),
  } })
  h:assert(comp_dev:initialize(), "companion fixture initializes")
  local comp_writes = comp_dev:writes()
  h:assert_eq(comp_writes[1].endpoint, "primary", "short ROOT lookup routes to the primary collection")
  h:assert_eq(comp_writes[1].data[1], 0x10, "ROOT lookup is a short report")
  h:assert_eq(comp_writes[2].endpoint, "companion", "long FEATURE_SET routes to the companion collection")
  h:assert_eq(comp_writes[2].data[1], 0x11, "FEATURE_SET count is a long report")

  -- The device-count register answers with a short report but the pairing
  -- records answer long; dispatch matches each reply by (devnum, sub) whatever
  -- collection carried it, so enumeration works across the split.
  local mixed_rx = h:open({ pid = 0xc547, companion = true, reads = {
    report(0x10, 0xff, 0x81, 0x02, { 0, 1 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0, 0, 0, 0x40, 0xb0 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0, 0xab, 0xcd, 0xef, 0x12 }),
  } })
  h:assert(mixed_rx:initialize(), "mixed-collection receiver root initializes")
  local mixed_children = mixed_rx:enumerate_controllers()
  h:assert_eq(#mixed_children, 1, "receiver enumerates a slot from mixed short/long replies")
  h:assert_eq(mixed_children[1].id, "logitech_ABCDEF12", "child serial decoded from a long pairing reply")

  -- Unpairing leaves holes: slot 1 returns HID++1 INVALID_ADDRESS (0x09),
  -- while the mouse remains paired in slot 2. Enumeration must continue so
  -- the mouse stays registered and pairing_status remains available.
  local sparse_rx = h:open({ pid = 0xc547, reads = {
    report(0x10, 0xff, 0x81, 0x02, { 0, 1 }),
    report(0x10, 0xff, 0x8f, 0x83, { 0xb5, 0x09 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0, 0, 0, 0x40, 0x99 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0, 0x12, 0x34, 0x56, 0x78 }),
  } })
  h:assert(sparse_rx:initialize(), "sparse receiver root initializes")
  local sparse_children = sparse_rx:enumerate_controllers()
  h:assert_eq(#sparse_children, 1, "empty slot does not hide a later paired mouse")
  h:assert_eq(sparse_children[1].id, "logitech_12345678", "later-slot mouse keeps its identity")
  h:assert_eq(sparse_children[1].device_type, "mouse", "receiver WPID preserves mouse type")
  local sparse_writes = sparse_rx:writes()
  h:assert_eq(sparse_writes[2].data[5], 0x20, "sparse scan probes empty slot 1")
  h:assert_eq(sparse_writes[3].data[5], 0x21, "sparse scan continues to paired slot 2")
  h:assert_eq(sparse_writes[4].data[5], 0x31, "sparse scan reads slot 2 extended identity")

  -- Pairing-lock notifications are HID++ 1.0 packets. Byte 4 is the lock
  -- state, not a HID++ 2.0 software id: an open notification must reach Lua,
  -- and a clean close must both finish the UI state and rescan receiver slots.
  local pairing_rx = h:open({ pid = 0xc547 })
  h:assert(pairing_rx:initialize(), "pairing event receiver initializes")
  pairing_rx:queue_event(report(0x10, 0xff, 0x4a, 0x01, { 0x00 }))
  local pairing_open = pairing_rx:pump_events()
  h:assert_eq(#pairing_open, 1, "pairing lock-open notification reaches the receiver root")
  h:assert(pairing_open[1].state_changed, "pairing lock-open updates UI state")
  h:assert(not pairing_open[1].children_changed, "opening pairing does not rescan children")
  pairing_rx:queue_event(report(0x10, 0xff, 0x4a, 0x00, { 0x00 }))
  local pairing_done = pairing_rx:pump_events()
  h:assert_eq(#pairing_done, 1, "pairing lock-close notification reaches the receiver root")
  h:assert(pairing_done[1].state_changed, "successful pairing exits listening state")
  h:assert(pairing_done[1].children_changed, "successful pairing requests child registration")
  local pairing_writes = pairing_rx:writes()
  h:assert_eq(pairing_writes[#pairing_writes].data[3], 0x80,
    "successful pairing nudges the HID++ 1.0 receiver")
  h:assert_eq(pairing_writes[#pairing_writes].data[4], 0x02,
    "pairing nudge writes the device-count register")
  h:assert_eq(pairing_writes[#pairing_writes].data[5], 0x02,
    "pairing nudge requests connection rebroadcast")

  -- A powered-off device is rejected, not failed, so the daemon re-registers it
  -- silently once it wakes. An off PRO X headset still enumerates through its
  -- dongle and only errors (0x05) once a read needs the headset itself; a
  -- receiver child that is off instead answers nothing at all. Neither may raise.
  local asleep_headset = h:open({ pid = 0x0aba, reads = {
    report(0x11, 0xff, 0x00, 0x01, { 2 }),          -- ROOT -> FEATURE_SET index
    report(0x11, 0xff, 0x02, 0x01, { 1 }),          -- FEATURE_SET count
    report(0x11, 0xff, 0x02, 0x11, { 0x83, 0x00 }), -- feature[1] = SIDETONE
    -- [report, devnum, 0xff, feature_idx=1, func_byte=0x00, err_code=0x05]
    report(0x11, 0xff, 0xff, 0x01, { 0x00, 0x05 }),
  } })
  h:assert(not asleep_headset:initialize(), "an error reply rejects rather than fails init")

  local silent_child = h:open({ key = "1", reads = {
    {}, {}, {}, {}, {}, {}, -- three ROOT attempts, two empty read windows each
  } })
  h:assert(not silent_child:initialize(), "a device that answers nothing is rejected")

  local windows_asleep_headset = h:open({ pid = 0x0aba,
    write_error = "HID write error: hidapi error:" })
  h:assert(not windows_asleep_headset:initialize(),
    "a Windows HID write failure rejects a powered-off headset")

  -- A failure that is not the HID++ protocol answering is not an absent device
  -- and must still surface.
  local broken_dev = h:open({ reads = {} })
  h:assert(not pcall(function() return broken_dev:initialize() end),
    "a transport failure still fails initialization")

  -- A packet that arrives interleaved with a request must be handed to the
  -- event path, not dropped: the button notification queued before the ROOT
  -- feature reply is deferred, the request still completes, and once the
  -- device has enumerated its remap backend the deferred press is delivered
  -- via event(). It deliberately shares the requested feature/function and
  -- differs only by software id, pinning full-byte reply matching.
  local evt_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),                -- ROOT -> FEATURE_SET index 2
    report(0x11, 0xff, 0x02, 0x01, { 1 }),                -- FEATURE_SET count
    report(0x11, 0xff, 0x02, 0x11, { 0x1b, 0x04 }),       -- feature[1] = REPROG_CONTROLS_V4
    report(0x11, 0xff, 0x01, 0x00, { 0, 0x38 }),          -- interleaved button press (swid 0)
    report(0x11, 0xff, 0x01, 0x01, { 1 }),                -- reprog control count
    report(0x11, 0xff, 0x01, 0x11, { 0, 0x38, 0, 0x38, 0x08, 0, 0 }), -- divertable cid 0x38
  } })
  h:assert(evt_dev:initialize(), "event fixture initializes past an interleaved packet")
  local pumped = evt_dev:pump_events()
  h:assert_eq(#pumped, 1, "deferred interleaved packet is delivered through event()")
  h:assert_eq(pumped[1].pressed[1], 0x38, "event() decodes the deferred button press")

  -- A queued button release for an already-pressed control produces a release
  -- transition on the next pump.
  evt_dev:queue_event(report(0x11, 0xff, 0x01, 0x00, {}))
  local released = evt_dev:pump_events()
  h:assert_eq(#released, 1, "release notification produces an event() outcome")
  h:assert_eq(released[1].released[1], 0x38, "event() decodes the button release")
end
