-- HID++ feature discovery fixture.  The replies retain the raw report header;
-- this proves the package emits padded short ROOT and padded long FEATURE_SET
-- requests with software id 1, exactly like the former messenger.
local function profile_management_tests(h, report)
  -- PROFILE_MANAGEMENT codecs against the live G915 X flash.
  local PM = halod.require("lib.hidpp2.profile_mgmt")({ bytes = string.char,
    feature = function() error("codec only") end, feature_id = 0x8101 })
  local FKC = halod.require("lib.hidpp2.fkc")({ bytes = string.char,
    feature = function() error("codec only") end, request = function() error("codec only") end,
    feature_id = 0x1b05, control_list = 0x1b10 })
  local function unhex(text)
    return (text:gsub("%s+", ""):gsub("..", function(x) return string.char(tonumber(x, 16)) end))
  end
  h:assert_eq(PM.crc32("123456789"), 0xcbf43926, "profile files are checked with CRC-32")
  local live_dir = unhex([[b8 38 06 b2 03 01 81 01 40 63 31 dc 31 09 08 02 81 01 40 63 f5 02 35 0e 09
    03 81 01 40 63 00 67 34 cc 0a ff]])
  local parsed_dir = PM.parse_directory(live_dir)
  h:assert_eq(#parsed_dir.entries, 3, "the directory lists one entry per profile")
  h:assert_eq(parsed_dir.entries[3], { id = 3, type = 0x8101, flags = 0x40, length = 99,
    crc = 0x006734cc, location = 0x0a }, "directory entries decode")
  h:assert_eq(PM.serialize_directory(parsed_dir), live_dir, "the directory round-trips with its checksum")
  local live_profile = unhex([[
    01 01 00 3c 01 2c ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff 18 ff
    00 81 80 aa ff 00 00 64 00 00 00 00 00 00 00 00 00 00 00 00 19 ff 00 81 80 aa ff 00 00 64 00 00
    00 00 00 00 00 00 00 00 00 00 03 00 00 00 00 00 00 00 00 00 00 00 00 44 00 18 08 ff ff ff ff ff
    ff ff ff]])
  h:assert_eq(PM.crc32(live_profile), 0x31dc3109, "a profile's directory checksum is its CRC-32")
  local prof = PM.parse_profile(live_profile, 4)
  h:assert_eq({ prof.id, prof.idle, prof.sleep, prof.flags }, { 1, 60, 300, 3 }, "profile header decodes")
  h:assert_eq(prof.leds[1].id, 0x18, "LED record 0 holds the firmware signature")
  h:assert_eq(prof.leds[3].id, 0x19, "LED record 2 holds the power-saving signature")
  h:assert_eq(prof.refs, { false, false, false, false }, "unused file references decode as absent")
  h:assert_eq(PM.serialize_profile(prof), live_profile, "a profile round-trips")
  prof.refs[1] = 4
  h:assert_eq({ PM.serialize_profile(prof):byte(92, 93) }, { 0, 4 }, "a file reference is a big-endian id")
  h:assert_eq(PM.allocate(parsed_dir, 13), 1, "new files take the first free sector")
  h:assert_eq(PM.allocate({ entries = { { length = 200, location = 1 } } }, 13), 3, "a long file spans sectors")
  local preset_groups = FKC.decode_preset(FKC.encode_preset({
    { cidx = 5, rows = { { opcode = 0x8002, action = 0x02, params = 0x04 }, { opcode = 0x8000 } } } }))
  h:assert_eq(preset_groups[1].cidx, 5, "preset groups name the control-list index")
  h:assert_eq(preset_groups[1].rows[1], { index = 0, modifiers = 0, action = 2, opcode = 0x8002, params = 4 },
    "preset rows round-trip")
  h:assert_eq(preset_groups[1].rows[2].index, 1, "rows are numbered across the file")
  h:assert_eq(FKC.disable_preset({ 7, 2 }), unhex("00 02 02 01 00 00 00 00 00 00 80 00 00 07 01 01 00 00 00 00 00 80 00 00"),
    "taken-over keys become sorted disabled rows")

  -- A keyboard with PROFILE_MANAGEMENT only shows host lighting in host mode
  -- with both cluster and power-mode ownership claimed.
  local function chunk_reports(sub, data, devnum)
    local out = {}
    for offset = 1, #data, 16 do
      out[#out + 1] = report(0x11, devnum or 0x01, sub, 0xc1, { data:byte(offset, offset + 15) })
    end
    return out
  end
  -- The live factory profile, trimmed to one 0x1b05 file reference.
  local FACTORY_PROFILE = live_profile:sub(1, 93)
  local function directory(entries)
    local out = {}
    for _, e in ipairs(entries) do
      out[#out + 1] = { id = e.id, type = e.type, flags = 0x40, length = #e.data,
        crc = PM.crc32(e.data), location = e.location }
    end
    return PM.serialize_directory({ entries = out })
  end
  local function pm_reads(sub, user_dir, profile, devnum)
    devnum = devnum or 0x01
    local out = {
      report(0x11, devnum, sub, 0x11, { 0x01, 0x02, 0x12, 0x13, 0x03, 0x0c, 0x0d, 0x0e, 0x0f, 0x07, 0x30,
        0xe0, 0x1b, 0x05, 0xff }),
      report(0x11, devnum, sub, 0x61, { 0x03, 0, 1 }),
      report(0x11, devnum, sub, 0x81, {}),
    }
    for _, r in ipairs(chunk_reports(sub, user_dir, devnum)) do out[#out + 1] = r end
    out[#out + 1] = report(0x11, devnum, sub, 0x81, {})
    local factory_dir = directory({ { id = 1, type = 0x8101, data = FACTORY_PROFILE, location = 1 } })
    for _, r in ipairs(chunk_reports(sub, factory_dir, devnum)) do out[#out + 1] = r end
    out[#out + 1] = report(0x11, devnum, sub, 0x81, {})
    for _, r in ipairs(chunk_reports(sub, profile, devnum)) do out[#out + 1] = r end
    return out
  end
  local function queue_file_write(dev, sub, data, devnum)
    devnum = devnum or 0x01
    dev:queue_read(report(0x11, devnum, sub, 0x21, {}))
    for _ = 1, math.ceil(#data / 16) do dev:queue_read(report(0x11, devnum, sub, 0x31, {})) end
    for _, r in ipairs(chunk_reports(sub, data, devnum)) do dev:queue_read(r) end
    dev:queue_read(report(0x11, devnum, sub, 0x71, {}))
    dev:queue_read(report(0x11, devnum, sub, 0x81, {}))
    for _, r in ipairs(chunk_reports(sub, data, devnum)) do dev:queue_read(r) end
  end
  local function find_write(writes, sub, fn, byte5)
    for i, w in ipairs(writes) do
      if w.data[3] == sub and w.data[4] == fn and (byte5 == nil or w.data[5] == byte5) then return w, i end
    end
  end
  local function appended_file(writes, sub, first, length)
    local parts, seen = {}, 0
    for i = first, #writes do
      local w = writes[i]
      if w.data[3] == sub and w.data[4] == 0x31 then
        parts[#parts + 1] = string.char(table.unpack(w.data, 5, 20))
        seen = seen + 1
        if seen * 16 >= length then break end
      end
    end
    return table.concat(parts):sub(1, length)
  end
  local user_dir = directory({ { id = 1, type = 0x8101, data = FACTORY_PROFILE, location = 8 } })
  local managed_reads = {
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }),
    report(0x10, 0x01, 0x00, 0x01, { 3 }),
    report(0x11, 0x01, 0x03, 0x01, { 2 }),
    report(0x11, 0x01, 0x03, 0x11, { 0x80, 0x71 }),
    report(0x11, 0x01, 0x03, 0x11, { 0x81, 0x01 }),
  }
  for _, r in ipairs(pm_reads(0x02, user_dir, FACTORY_PROFILE)) do managed_reads[#managed_reads + 1] = r end
  for _, r in ipairs({
    report(0x11, 0x01, 0x01, 0x01, { 0, 0, 1 }),
    report(0x11, 0x01, 0x01, 0x01, { 0, 0, 0, 0, 2 }),
    report(0x11, 0x01, 0x01, 0x01, { 0, 0, 0, 1 }),
    report(0x11, 0x01, 0x01, 0x01, { 0, 1, 0, 0x15 }),
    report(0x11, 0x01, 0x02, 0x61, { 0, 0, 1 }),
    report(0x11, 0x01, 0x01, 0x51, { 1, 3, 4 }),
    report(0x11, 0x01, 0x01, 0x71, { 0, 0, 0, 0, 60, 0x01, 0x2c }),
    report(0x11, 0x01, 0x01, 0x71, { 1 }),
  }) do managed_reads[#managed_reads + 1] = r end
  local managed = h:open({ pid = 0xc547, key = "1", reads = managed_reads })
  h:assert(managed:initialize(), "profile-managed keyboard initializes")
  local managed_init = managed:writes()
  local claim_mode, claim_at = find_write(managed_init, 0x02, 0x61, 0x05)
  local claim_control = managed_init[claim_at + 1]
  local timers = managed_init[claim_at + 3]
  h:assert_eq(claim_mode.data[3], 0x02, "claim addresses PROFILE_MANAGEMENT first")
  h:assert_eq(claim_mode.data[4], 0x61, "claim uses the mode function")
  h:assert_eq(claim_mode.data[5], 0x05, "claim selects host mode")
  h:assert_eq(claim_control.data[4], 0x51, "claim then takes RGB software control")
  h:assert_eq(claim_control.data[6], 0x03, "claim owns clusters and power modes")
  h:assert_eq(claim_control.data[7], 0x04, "claim subscribes to the idle timeout")
  h:assert_eq(timers.data[8], 0x01, "idle timeout is moved to the firmware's sleep timeout")
  h:assert_eq(timers.data[9], 0x2c, "idle timeout keeps the sleep timeout's low byte")
  local managed_onboard
  for _, cap in ipairs(managed:serialize().capabilities) do
    if cap.kind == "onboard_profiles" then managed_onboard = cap.data end
  end
  h:assert(managed_onboard, "a tag-managed profile directory is an onboard-profile capability")
  h:assert_eq(managed_onboard.active_slot, 0, "host mode shows no active onboard profile")
  h:assert_eq(managed_onboard.slots[1].index, 1, "slots are the directory's profile ids")
  h:assert(managed_onboard.slots[1].has_rom_default, "a factory copy makes the slot restorable")
  local managed_effects = {}
  for _, effect in ipairs(managed:lighting_descriptor().native_effects or {}) do managed_effects[effect.id] = effect end
  h:assert(managed_effects.signature, "the profile's signature record is offered as a native effect")
  h:assert_eq(managed_effects.signature.params[1].default, { r = 0xff, g = 0, b = 0x81 },
    "signature colours come from the profile")
  h:assert_eq(managed_effects.signature.params[2].default, { r = 0x80, g = 0xaa, b = 0xff },
    "the second signature colour follows")

  managed:clear()
  managed:queue_read(report(0x11, 0x01, 0x01, 0x51, { 1, 0, 0 }))
  managed:queue_read(report(0x11, 0x01, 0x02, 0x61, { 3, 0, 1 }))
  managed:set_boolean("host_mode", false)
  local release = managed:writes()
  h:assert_eq(release[1].data[6], 0x00, "leaving host mode releases RGB software control")
  h:assert_eq(release[2].data[5], 0x03, "leaving host mode returns to the onboard profile")

  -- In onboard mode an effect is stored in the active profile instead.
  local cycle_profile = PM.parse_profile(FACTORY_PROFILE, 1)
  local cycle_params = { 0, 255, 0, 0, 0, 0, 0x27, 0x10, 100, 0 }
  cycle_profile.leds[2] = { id = 0x15, params = cycle_params }
  cycle_profile.leds[4] = { id = 0x15, params = cycle_params }
  cycle_profile.flags = 0
  local cycle_data = PM.serialize_profile(cycle_profile)
  managed:clear()
  queue_file_write(managed, 0x02, cycle_data)
  queue_file_write(managed, 0x02, directory({ { id = 1, type = 0x8101, data = cycle_data, location = 8 } }))
  managed:queue_read(report(0x11, 0x01, 0x02, 0x91, {}))
  managed:queue_read(report(0x11, 0x01, 0x02, 0x61, { 3, 0, 1 }))
  managed:apply({ mode = "native_effect", id = "color_cycle", params = {} })
  local managed_effect = managed:writes()
  h:assert_eq(managed_effect[1].data[4], 0x21, "an onboard-mode effect opens the profile edit buffer")
  h:assert_eq(appended_file(managed_effect, 0x02, 1, #cycle_data), cycle_data,
    "the effect is written to LED records 1 and 3 with the custom flag")
  local save = find_write(managed_effect, 0x02, 0x71)
  h:assert_eq({ save.data[5], save.data[6], save.data[7], save.data[8] }, { 0, 8, 0, 93 },
    "the profile is committed to its directory location")
  local activate = find_write(managed_effect, 0x02, 0x91)
  h:assert_eq({ table.unpack(activate.data, 5, 11) }, { 0x81, 0x01, 0x01, 0x00, 0x01, 0x00, 93 },
    "activation names the profile file, id and length")
  h:assert_eq(find_write(managed_effect, 0x02, 0x61, 0x05), nil, "an onboard-mode effect does not claim host mode")
  local managed_status
  for _, cap in ipairs(managed:serialize().capabilities) do
    if cap.kind == "onboard_profiles" then managed_status = cap.data end
  end
  h:assert_eq(managed_status.active_slot, 1, "onboard mode reports the firmware's active profile")

  -- The signature plays from the profile, so applying it hands the LEDs back.
  local signature_profile = PM.parse_profile(cycle_data, 1)
  local signature_params = { 1, 2, 3, 0x80, 0xaa, 0xff, 0, 0, 50, 0 }
  signature_profile.leds[1] = { id = 0x18, params = signature_params }
  signature_profile.leds[3] = { id = 0x19, params = signature_params }
  signature_profile.flags = 3
  local signature_data = PM.serialize_profile(signature_profile)
  managed:clear()
  managed:queue_read(report(0x11, 0x01, 0x02, 0x61, { 0, 0, 1 }))
  managed:queue_read(report(0x11, 0x01, 0x01, 0x51, { 1, 3, 4 }))
  managed:queue_read(report(0x11, 0x01, 0x01, 0x11, {}))
  managed:set_boolean("host_mode", true)
  local back_to_host = managed:writes()
  h:assert_eq(back_to_host[1].data[5], 0x05, "turning host mode on claims the LEDs first")
  h:assert_eq(back_to_host[#back_to_host].data[4], 0x11, "then the last effect plays live")
  managed:clear()
  queue_file_write(managed, 0x02, signature_data)
  queue_file_write(managed, 0x02, directory({ { id = 1, type = 0x8101, data = signature_data, location = 8 } }))
  managed:queue_read(report(0x11, 0x01, 0x02, 0x91, {}))
  managed:queue_read(report(0x11, 0x01, 0x02, 0x61, { 0, 0, 1 }))
  managed:queue_read(report(0x11, 0x01, 0x01, 0x51, { 1, 0, 0 }))
  managed:queue_read(report(0x11, 0x01, 0x02, 0x61, { 3, 0, 1 }))
  managed:apply({ mode = "native_effect", id = "signature",
    params = { color = { r = 1, g = 2, b = 3 }, brightness = 50 } })
  local signature_writes = managed:writes()
  h:assert_eq(appended_file(signature_writes, 0x02, 1, #signature_data), signature_data,
    "the signature's colours and brightness go to LED records 0 and 2")
  h:assert_eq(signature_writes[#signature_writes].data[5], 0x03, "the signature ends in onboard mode")
  h:assert_eq(signature_writes[#signature_writes - 1].data[6], 0x00, "the signature releases software control")

  managed:clear()
  managed:queue_read(report(0x11, 0x01, 0x02, 0x61, { 0, 0, 1 }))
  managed:queue_read(report(0x11, 0x01, 0x01, 0x51, { 1, 3, 4 }))
  managed:set_boolean("host_mode", true)
  h:assert_eq(#managed:writes(), 2, "host mode after the signature only claims the LEDs")
  managed:clear()
  managed:queue_read(report(0x11, 0x01, 0x02, 0x61, { 0, 0, 1 }))
  managed:queue_read(report(0x11, 0x01, 0x01, 0x51, { 1, 3, 4 }))
  managed:queue_read(report(0x11, 0x01, 0x01, 0x11, {}))
  managed:apply({ mode = "native_effect", id = "color_cycle", params = {} })
  managed_effect = managed:writes()
  h:assert_eq(managed_effect[1].data[5], 0x05, "a live effect in host mode renews the claim")
  h:assert_eq(managed_effect[3].data[4], 0x11, "the effect follows the claim")
  h:assert_eq(managed_effect[3].data[6], 1, "the effect uses the slot the firmware reports")
  managed:clear()
  managed:queue_event(report(0x11, 0x01, 0x01, 0x10, { 0 }))
  managed:queue_event(report(0x11, 0x01, 0x01, 0x10, { 1 }))
  managed:pump_events()
  h:assert_eq(#managed:writes(), 0, "the idle/active pair that follows a claim is ignored")

  -- FULL_KEY_CUSTOMIZATION keyboards take keys over through a preset file in
  -- PROFILE_MANAGEMENT flash and report them as triggers.
  local fkc_reads = {
    report(0x10, 0xff, 0x00, 0x01, { 4 }),
    report(0x11, 0xff, 0x04, 0x01, { 3 }),
    report(0x11, 0xff, 0x04, 0x11, { 0x81, 0x01 }),
    report(0x11, 0xff, 0x04, 0x11, { 0x1b, 0x05 }),
    report(0x11, 0xff, 0x04, 0x11, { 0x1b, 0x10 }),
  }
  for _, r in ipairs(pm_reads(0x01, user_dir, FACTORY_PROFILE, 0xff)) do fkc_reads[#fkc_reads + 1] = r end
  fkc_reads[#fkc_reads + 1] = report(0x11, 0xff, 0x03, 0x01, { 3 })
  fkc_reads[#fkc_reads + 1] = report(0x11, 0xff, 0x03, 0x11, { 0x01, 0x4c, 0x01, 0x22, 0x00, 0x4e })
  local fkc_dev = h:open({ pid = 0xc356, reads = fkc_reads })
  h:assert(fkc_dev:initialize(), "full-key-customization keyboard initializes")
  local fkc_status = fkc_dev:key_remap_status()
  h:assert_eq(#fkc_status.buttons, 3, "every control-list entry is a remappable key")
  h:assert_eq(fkc_status.buttons[2].label, "Standard Key A", "keys are labelled by control id")
  h:assert_eq(fkc_status.buttons[3].label, "Scroll Lock", "legacy control ids keep their names")
  h:assert(not fkc_status.requires_host_mode, "onboard key assignments do not depend on host mode")

  local preset = FKC.disable_preset({ 1 })
  local profile_with_ref = FACTORY_PROFILE:sub(1, 91) .. "\0\2"
  local dir_with_preset = directory({
    { id = 1, type = 0x8101, data = FACTORY_PROFILE, location = 8 },
    { id = 2, type = 0x1b05, data = preset, location = 1 },
  })
  local dir_with_ref = directory({
    { id = 1, type = 0x8101, data = profile_with_ref, location = 8 },
    { id = 2, type = 0x1b05, data = preset, location = 1 },
  })
  fkc_dev:clear()
  queue_file_write(fkc_dev, 0x01, preset, 0xff)
  queue_file_write(fkc_dev, 0x01, dir_with_preset, 0xff)
  queue_file_write(fkc_dev, 0x01, profile_with_ref, 0xff)
  queue_file_write(fkc_dev, 0x01, dir_with_ref, 0xff)
  fkc_dev:queue_read(report(0x11, 0xff, 0x02, 0x31, { 1, 1 }))
  fkc_dev:queue_read(report(0x11, 0xff, 0x01, 0x91, {}))
  fkc_dev:queue_read(report(0x11, 0xff, 0x01, 0x61, { 3, 0, 1 }))
  fkc_dev:set_button_mapping({ cid = 0x0122,
    base = { type = "disable" }, shifted = { type = "native" } })
  local fkc_writes = fkc_dev:writes()
  h:assert_eq(appended_file(fkc_writes, 0x01, 1, #preset), preset,
    "the taken-over key is written as a disabled row in a new preset file")
  local preset_save = find_write(fkc_writes, 0x01, 0x71)
  h:assert_eq({ preset_save.data[5], preset_save.data[6], preset_save.data[8] }, { 0, 1, #preset },
    "the preset is committed to the first free sector")
  local _, preset_save_at = find_write(fkc_writes, 0x01, 0x71)
  local after_preset = { table.unpack(fkc_writes, preset_save_at + 1) }
  local dir_begin = find_write(after_preset, 0x01, 0x21)
  h:assert_eq(dir_begin.data[6], #dir_with_preset, "the directory gains the preset's entry")
  local dir_save = find_write(after_preset, 0x01, 0x71)
  h:assert_eq({ table.unpack(dir_save.data, 5, 12) }, { 0, 0, 0, #dir_with_preset, dir_with_preset:byte(1, 4) },
    "the directory is committed under its own header checksum")
  local fkc_activate = find_write(fkc_writes, 0x01, 0x91)
  h:assert_eq({ table.unpack(fkc_activate.data, 5, 9) }, { 0x81, 0x01, 0x01, 0x00, 0x01 },
    "the profile that now references the preset is activated")
  h:assert_eq(fkc_writes[#fkc_writes].data[4], 0x61, "activation is followed by a mode read")

  fkc_dev:clear()
  fkc_dev:queue_event(report(0x11, 0xff, 0x02, 0x10, { 0x02 }))
  local fkc_pressed = fkc_dev:pump_events()
  h:assert_eq(fkc_pressed[1].pressed[1], 0x0122, "a trigger bitmap names the key by control id")
  fkc_dev:queue_event(report(0x11, 0xff, 0x02, 0x00, { 0x01, 0xff }))
  local fkc_held = fkc_dev:pump_events()
  h:assert_eq(#fkc_held[1].pressed + #fkc_held[1].released, 0, "a trigger list of the same key changes nothing")
  fkc_dev:queue_event(report(0x11, 0xff, 0x02, 0x10, {}))
  local fkc_released = fkc_dev:pump_events()
  h:assert_eq(fkc_released[1].released[1], 0x0122, "an empty bitmap releases the key")
end

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
    {}, {}, {}, {}, -- first ROOT attempt exhausts its empty read windows
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x1d, 0x4b }), -- WIRELESS_DEVICE_STATUS
  } })
  h:assert(waking_dev:initialize(), "cold G502 retries its initial ROOT lookup")
  h:assert_eq(#waking_dev:writes(), 4,
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

  local approximate_battery_dev = h:open({ reads = {
    report(0x10, 0xff, 0, 1, { 2 }),
    report(0x11, 0xff, 2, 1, { 1 }),
    report(0x11, 0xff, 2, 0x11, { 0x10, 4 }),
    report(0x11, 0xff, 1, 0x11, { 0, 4, 6 }),
  } })
  h:assert(approximate_battery_dev:initialize(), "approximate battery fixture initializes")
  local approximate_battery = approximate_battery_dev:get_batteries()[1]
  h:assert_eq(approximate_battery.level, 50, "unified battery falls back to its coarse level")
  h:assert_eq(approximate_battery.status, "unknown", "a battery thermal error is not reported as charging")

  local function voltage_battery(code, flags)
    local dev = h:open({ reads = {
      report(0x10, 0xff, 0, 1, { 2 }),
      report(0x11, 0xff, 2, 1, { 1 }),
      report(0x11, 0xff, 2, 0x11, { code >> 8, code & 0xff }),
      report(0x11, 0xff, 1, 1, { 0x0f, 0xe3, flags }), -- 4067 mV
    } })
    h:assert(dev:initialize(), "voltage battery fixture initializes")
    return dev:get_batteries()
  end
  h:assert_eq(voltage_battery(0x1001, 0x80)[1].status, "charging",
    "battery voltage uses the charging flag instead of a magic status byte")
  h:assert_eq(voltage_battery(0x1001, 0)[1].status, "discharging",
    "battery voltage without charging flag discharges")
  h:assert_eq(voltage_battery(0x1f20, 3)[1].status, "charging", "ADC charging bit is decoded")
  h:assert_eq(voltage_battery(0x1f20, 1)[1].status, "discharging", "ADC discharging bit is decoded")
  h:assert_eq(#voltage_battery(0x1f20, 0), 0, "invalid ADC measurement does not publish a battery")

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

  local default_dpi_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x22, 0x01 }),
    report(0x11, 0xff, 0x01, 0x11, { 0, 0x01, 0x90, 0x03, 0x20, 0, 0 }),
    report(0x11, 0xff, 0xff, 0x01, { 0x11, 0x02 }), -- stale get-list error
    report(0x11, 0xff, 0x01, 0x21, { 0, 0, 0, 0x03, 0x20 }),
  } })
  h:assert(default_dpi_dev:initialize(), "stale errors from another function do not abort DPI reads")
  h:assert_eq(default_dpi_dev:dpi_status().current_dpi, 800,
    "zero current DPI uses the firmware default resolution")

  -- Full daemon state snapshots run every 250 ms. Onboard status must use the
  -- state populated during initialization instead of re-reading the directory
  -- and active-profile flash sectors on every serialization pass.
  local onboard_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x00 }),
    report(0x11, 0xff, 0x01, 0x01, { 1, 1, 0, 1, 1, 0, 2, 0, 16 }),
    report(0x11, 0xff, 0x01, 0x21, { 1 }),
    report(0x11, 0xff, 0x01, 0x51, { 0, 1, 1, 0 }),
    report(0x11, 0xff, 0x01, 0x41, { 0, 1 }),
    report(0x11, 0xff, 0x01, 0x51, { 0, 0, 0, 0 }),
  } })
  h:assert(onboard_dev:initialize(), "onboard-profile fixture initializes")
  onboard_dev:clear()
  onboard_dev:serialize()
  onboard_dev:serialize()
  h:assert_eq(#onboard_dev:writes(), 0,
    "state serialization serves cached onboard profiles without HID writes")

  local function onboard_reads(dev, active, enabled)
    local replies = {
      report(0x11, 0xff, 0x01, 0x01, { 1, 1, 0, 1, 1, 5, 2, 0, 16 }),
      report(0x11, 0xff, 0x01, 0x21, { 1 }),
      report(0x11, 0xff, 0x01, 0x51, { 0, 1, enabled and 1 or 0, 0, 0xff, 0xff }),
      report(0x11, 0xff, 0x01, 0x41, { active >> 8, active & 0xff }),
      report(0x11, 0xff, 0x01, 0x51, { 1, 0, 0, 0x90, 1, 0x20, 3 }),
    }
    for _, reply in ipairs(replies) do dev:queue_read(reply) end
  end
  local flash_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x00 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x22, 0x01 }),
  } })
  onboard_reads(flash_dev, 1, false)
  flash_dev:queue_read(report(0x11, 0xff, 0x02, 0x11, { 0, 1, 0x90, 3, 0x20, 0, 0 }))
  flash_dev:queue_read(report(0x11, 0xff, 0x02, 0x21, { 0, 3, 0x20 }))
  h:assert(flash_dev:initialize(), "flash editing fixture initializes")
  flash_dev:clear()
  onboard_reads(flash_dev, 0x0101, false)
  h:assert(not pcall(function() flash_dev:set_dpi_steps({ 400, 800 }) end),
    "editing a ROM profile must fail instead of overwriting its writable counterpart")
  h:assert_eq(#flash_dev:writes(), 5, "ROM DPI edit performs no flash write")

  flash_dev:clear()
  onboard_reads(flash_dev, 1, false)
  flash_dev:queue_read(report(0x11, 0xff, 0x01, 0x51, { 1, 0, 0, 0x90, 1, 0x20, 3 }))
  flash_dev:set_dpi_steps({ 400, 800 })
  h:assert_eq(#flash_dev:writes(), 6, "unchanged DPI stages do not wear flash")

  flash_dev:clear()
  onboard_reads(flash_dev, 1, false)
  flash_dev:queue_read(report(0x11, 0xff, 0x01, 0x61, {}))
  flash_dev:queue_read(report(0x11, 0xff, 0x01, 0x71, {}))
  flash_dev:queue_read(report(0x11, 0xff, 0x01, 0x81, {}))
  onboard_reads(flash_dev, 1, true)
  flash_dev:set_profile_enabled(1, true)
  local flash_writes = flash_dev:writes()
  h:assert_eq(#flash_writes, 13, "enabling a profile writes only its directory")
  h:assert_eq(flash_writes[6].data[4], 0x61, "directory write begins after reading current state")
  h:assert_eq(flash_writes[6].data[6], 0, "profile enabling targets the directory sector")
  h:assert_eq(flash_writes[7].data[7], 1, "directory marks the existing profile enabled")
  flash_dev:clear()
  onboard_reads(flash_dev, 1, true)
  flash_dev:set_profile_enabled(1, true)
  h:assert_eq(#flash_dev:writes(), 5, "enabling an enabled profile is a flash no-op")

  flash_dev:clear()
  onboard_reads(flash_dev, 2, true)
  flash_dev:queue_read(report(0x11, 0xff, 0x01, 0x51, { 1, 0, 0, 0x90, 1, 0x20, 3 }))
  h:assert(not pcall(function() flash_dev:set_dpi_steps({ 800, 400 }) end),
    "a profile outside the declared writable sectors is rejected before erase")
  h:assert_eq(#flash_dev:writes(), 6, "out-of-range sector never starts a flash write")

  flash_dev:clear()
  onboard_reads(flash_dev, 1, true)
  flash_dev:queue_read(report(0x11, 0xff, 1, 0x51,
    { 1, 0, 0, 0x90, 1, 0x20, 3, 0, 0, 0, 0, 0, 0, 0x5a, 0, 0 }))
  flash_dev:queue_read(report(0x11, 0xff, 1, 0x61, {}))
  flash_dev:queue_read(report(0x11, 0xff, 1, 0x71, {}))
  flash_dev:queue_read(report(0x11, 0xff, 1, 0x81, {}))
  onboard_reads(flash_dev, 1, true)
  flash_dev:set_dpi_steps({ 800, 400 })
  local changed_flash_writes = flash_dev:writes()
  h:assert_eq(#changed_flash_writes, 14, "changed DPI stages use one erase/write/commit transaction")
  h:assert_eq(changed_flash_writes[8].data[8], 0x20, "profile DPI uses little-endian values")
  h:assert_eq(changed_flash_writes[8].data[9], 3, "profile DPI preserves the requested stage order")
  h:assert_eq(changed_flash_writes[8].data[18], 0x5a, "DPI edit preserves unrelated profile bytes")

  local rom_directory_dev = h:open({ reads = {
    report(0x10, 0xff, 0, 1, { 2 }),
    report(0x11, 0xff, 2, 1, { 1 }),
    report(0x11, 0xff, 2, 0x11, { 0x81, 0 }),
    report(0x11, 0xff, 1, 1, { 1, 1, 0, 1, 1, 5, 2, 0, 16 }),
    report(0x11, 0xff, 1, 0x21, { 1 }),
    report(0x11, 0xff, 1, 0x51, {}), -- blank RAM directory
    report(0x11, 0xff, 1, 0x51, { 1, 1, 1, 0, 0xff, 0xff }),
    report(0x11, 0xff, 1, 0x41, { 1, 1 }),
    report(0x11, 0xff, 1, 0x51, { 1, 0, 0, 0x90, 1, 0x20, 3 }),
  } })
  h:assert(rom_directory_dev:initialize(), "blank RAM directory falls back to ROM headers")
  local rom_state=rom_directory_dev:serialize()
  for _,cap in ipairs(rom_state.capabilities) do
    if cap.kind=="onboard_profiles" then
      h:assert_eq(cap.data.active_slot,0x101,"active ROM sector retains its full ID")
      h:assert_eq(cap.data.slots[1].index,0x101,"ROM slot retains its full ID")
      h:assert(cap.data.slots[1].read_only,"ROM slot is read-only")
    end
  end
  h:assert(not pcall(function() rom_directory_dev:set_profile_enabled(0x101,false) end),"ROM enable mutation is rejected")
  local rom_writes = rom_directory_dev:writes()
  h:assert_eq(rom_writes[7].data[5], 1, "directory fallback reads ROM bank 0x0100")
  h:assert_eq(rom_writes[9].data[5], 1, "ROM profile remains addressed in the ROM bank")

  local unsupported_onboard = h:open({ reads = {
    report(0x10, 0xff, 0, 1, { 2 }),
    report(0x11, 0xff, 2, 1, { 1 }),
    report(0x11, 0xff, 2, 0x11, { 0x81, 0 }),
    report(0x11, 0xff, 1, 1, { 2, 6, 0, 1, 1, 5, 2, 0, 16 }),
  } })
  h:assert(not pcall(function() unsupported_onboard:initialize() end),
    "unknown onboard memory layouts are not interpreted using the known flash format")
  h:assert_eq(#unsupported_onboard:writes(), 4, "unknown layout stops before reading profile sectors")

  -- A DPI change reads the onboard mode from the same cache. Re-reading it put
  -- a second exchange on the DPI-button path, and one late reply there aborted
  -- the DPI change before its own write ever went out.
  local host_dpi_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 3 }),
    report(0x11, 0xff, 0x03, 0x01, { 2 }),
    report(0x11, 0xff, 0x03, 0x11, { 0x81, 0x00 }),   -- ONBOARD_PROFILES
    report(0x11, 0xff, 0x03, 0x11, { 0x22, 0x01 }),   -- ADJUSTABLE_DPI
    report(0x11, 0xff, 0x01, 0x01, { 1, 1, 0, 1, 1, 0, 2, 0, 16 }),
    report(0x11, 0xff, 0x01, 0x21, { 2 }),            -- host mode
    report(0x11, 0xff, 0x01, 0x51, { 0, 1, 1, 0 }),
    report(0x11, 0xff, 0x01, 0x41, { 0, 1 }),
    report(0x11, 0xff, 0x01, 0x51, { 1,0,0,0x90,1,0x20,3 }),
    report(0x11, 0xff, 0x02, 0x11, { 0, 0x01, 0x90, 0x03, 0x20, 0, 0 }),
    report(0x11, 0xff, 0x02, 0x21, { 0, 0x03, 0x20 }),
    report(0x11, 0xff, 0x02, 0x31, {}),
  } })
  h:assert(host_dpi_dev:initialize(), "host-mode DPI fixture initializes")
  host_dpi_dev:clear()
  host_dpi_dev:set_dpi(400)
  local host_dpi_writes = host_dpi_dev:writes()
  h:assert_eq(#host_dpi_writes, 1, "a host-mode DPI change is one write")
  h:assert_eq(host_dpi_writes[1].data[4], 0x31, "the write is setSensorDpi")

  local shift_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 3 }),
    report(0x11, 0xff, 0x03, 0x01, { 2 }),
    report(0x11, 0xff, 0x03, 0x11, { 0x81, 0x00 }),
    report(0x11, 0xff, 0x03, 0x11, { 0x22, 0x01 }),
    report(0x11, 0xff, 0x01, 0x01, { 1, 1, 0, 1, 1, 0, 2, 0, 16 }),
    report(0x11, 0xff, 0x01, 0x21, { 1 }),            -- onboard mode
    report(0x11, 0xff, 0x01, 0x51, { 0, 1, 1, 0 }),
    report(0x11, 0xff, 0x01, 0x41, { 0, 1 }),
    report(0x11, 0xff, 0x01, 0x51, { 1,0,0,0x90,1,0x20,3 }),
    report(0x11, 0xff, 0x02, 0x11, { 0, 0x01, 0x90, 0x03, 0x20, 0, 0 }),
    report(0x11, 0xff, 0x02, 0x21, { 0, 0x03, 0x20 }),
    report(0x11, 0xff, 0x02, 0x31, {}),
  } })
  h:assert(shift_dev:initialize(), "onboard-mode shift fixture initializes")
  shift_dev:clear()
  shift_dev:set_dpi(400)
  local shift_writes = shift_dev:writes()
  h:assert_eq(#shift_writes, 1, "an onboard-mode DPI change never touches the profile sector")
  h:assert_eq(shift_writes[1].data[4], 0x31, "an onboard-mode DPI change is setSensorDpi")
  h:assert_eq(shift_dev:dpi_status().current_dpi,400,"momentary onboard DPI reports the sensor value")
  shift_dev:clear()
  shift_dev:queue_event(report(0x11,0xff,1,0x10,{1}))
  shift_dev:pump_events()
  h:assert_eq(shift_dev:dpi_status().current_dpi,800,"physical DPI event updates the current sensor value")
  h:assert_eq(shift_dev:dpi_status().current_index,1,"physical DPI event updates the selected stage")
  h:assert_eq(#shift_dev:writes(),0,"physical DPI notification uses its payload without USB reads")

  local lossy_dpi_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x22, 0x01 }),
    report(0x11, 0xff, 0x01, 0x11, { 0, 0x01, 0x90, 0x03, 0x20, 0, 0 }),
    report(0x11, 0xff, 0x01, 0x21, { 0, 0x03, 0x20 }),
    {}, {}, {}, {},
    report(0x11, 0xff, 0x01, 0x31, {}),
  } })
  h:assert(lossy_dpi_dev:initialize(), "lossy DPI fixture initializes")
  lossy_dpi_dev:clear()
  lossy_dpi_dev:set_dpi(400)
  local lossy_writes = lossy_dpi_dev:writes()
  h:assert_eq(#lossy_writes, 2, "an unacknowledged setSensorDpi is resent once")
  h:assert_eq(lossy_writes[2].data[4], 0x31, "the resend is setSensorDpi")
  h:assert_eq(lossy_dpi_dev:dpi_status().current_dpi, 400, "the acknowledged resend updates the DPI")

  -- A mode switch can take effect while its acknowledgement is lost during
  -- the transition. Confirm the live mode before retrying or surfacing the
  -- transport timeout.
  local mode_switch_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x00 }),
    report(0x11, 0xff, 0x01, 0x01, { 1, 1, 0, 1, 1, 0, 2, 0, 16 }),
    report(0x11, 0xff, 0x01, 0x21, { 1 }),
    report(0x11, 0xff, 0x01, 0x51, { 0, 1, 1, 0 }),
    report(0x11, 0xff, 0x01, 0x41, { 0, 1 }),
    report(0x11, 0xff, 0x01, 0x51, { 0, 0, 0, 0 }),
    {}, {}, {}, {},                        -- setMode acknowledgement is lost
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
    report(0x11, 0xff, 0x01, 0x31, { 1, 2, 3, 4, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }), -- remap table
    report(0x11, 0xff, 0x01, 0x11, {}), -- start spy
    report(0x11, 0xff, 0x01, 0x41, {}), -- remap table per default mapping
    report(0x11, 0xff, 0x01, 0x41, {}),
    report(0x11, 0xff, 0x01, 0x41, {}),
  } })
  h:assert(mapped_dev:initialize(), "G502 X button fixture initializes")
  local spy_init = mapped_dev:writes()
  local start_write
  for _, w in ipairs(spy_init) do if w.data[4] == 0x11 and w.data[3] == 0x01 then start_write = w end end
  h:assert(start_write and start_write.data[5] == 0, "spy start carries no payload")
  local table_write = spy_init[#spy_init]
  h:assert_eq(table_write.data[4], 0x41, "spy remap table is written with function 0x40")
  h:assert_eq(table_write.data[5], 1, "unmapped left click keeps its HID button")
  h:assert_eq(table_write.data[10], 5, "unmapped G5 keeps HID button 5")
  h:assert_eq(table_write.data[14], 0, "remapped G8 (physical button 10) is suppressed")
  h:assert_eq(table_write.data[15], 0, "remapped G7 (physical button 11) is suppressed")
  local remap = mapped_dev:key_remap_status()
  h:assert_eq(#remap.buttons, 11, "G502 X exposes only its physical bitmap buttons")
  h:assert_eq(remap.buttons[1].label, "G9", "G502 X uses native button names")
  h:assert_eq(remap.buttons[5].label, "Right Click", "G502 X keeps sparse native ordering")
  h:assert_eq(#remap.mappings, 3, "G502 X seeds every native default mapping")
  local g8
  for _, mapping in ipairs(remap.mappings) do if mapping.cid == 2 then g8 = mapping end end
  h:assert(g8 and g8.base.type == "dpi_cycle", "G502 X G8 defaults to DPI cycle")

  -- Replacing one host action with another leaves the button suppressed and
  -- spying; it must not resend either and wait for a redundant acknowledgement.
  mapped_dev:clear()
  mapped_dev:queue_read(report(0x11, 0xff, 0x01, 0x41, {}))
  mapped_dev:set_button_mapping({ cid = 1,
    base = { type = "media_key", key = "play" }, shifted = { type = "native" } })
  local g9_writes = mapped_dev:writes()
  h:assert_eq(#g9_writes, 1, "a new SPY mapping only rewrites the remap table")
  h:assert_eq(g9_writes[1].data[4], 0x41, "a new SPY mapping writes the remap table")
  h:assert_eq(g9_writes[1].data[13], 0, "remapped G9 (physical button 9) is suppressed")
  mapped_dev:clear()
  mapped_dev:set_button_mapping({ cid = 1, base = { type = "macro", steps = {
    { kind = { kind = "key_down", key = 0x41 }, delay_after_ms = 0 },
    { kind = { kind = "key_up", key = 0x41 }, delay_after_ms = 0 },
  } }, shifted = { type = "native" } })
  h:assert_eq(#mapped_dev:writes(), 0,
    "replacing a SPY mapping does not redundantly re-enable global reporting")

  mapped_dev:clear()
  for _ = 1, 4 do mapped_dev:queue_read(report(0x11, 0xff, 0x01, 0x41, {})) end
  mapped_dev:queue_read(report(0x11, 0xff, 0x01, 0x21, {}))
  for _, cid in ipairs({ 1, 2, 3, 13 }) do
    mapped_dev:set_button_mapping({ cid = cid, base = { type = "native" }, shifted = { type = "native" } })
  end
  local unmap_writes = mapped_dev:writes()
  local last_table, stop = unmap_writes[#unmap_writes - 1], unmap_writes[#unmap_writes]
  h:assert_eq(stop.data[4], 0x21, "clearing the last SPY mapping stops spying with function 0x20")
  h:assert_eq(stop.data[5], 0, "spy stop carries no payload")
  h:assert_eq(last_table.data[4], 0x41, "clearing a SPY mapping rewrites the remap table")
  for i = 1, 16 do
    h:assert_eq(last_table.data[4 + i], ({ 1, 2, 3, 4, 0, 5 })[i] or 0,
      "remap table entry " .. i .. " returns to the device default")
  end

  -- A button mapped only on the shift layer keeps its native click on the
  -- normal layer; it is suppressed only while the global layer shift is held.
  local layer_dev = h:open({ pid = 0xc095, reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x10 }),
    report(0x11, 0xff, 0x01, 0x31, { 1, 2, 3, 4, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
    report(0x11, 0xff, 0x01, 0x11, {}),
    report(0x11, 0xff, 0x01, 0x41, {}),
    report(0x11, 0xff, 0x01, 0x41, {}),
    report(0x11, 0xff, 0x01, 0x41, {}),
  } })
  h:assert(layer_dev:initialize(), "layer-shift fixture initializes")
  local function last_table()
    local writes = layer_dev:writes()
    return writes[#writes]
  end
  h:assert_eq(last_table().data[14], 0, "base-mapped G8 is suppressed")
  layer_dev:clear()
  layer_dev:set_button_mapping({ cid = 9, base = { type = "native" },
    shifted = { type = "media_key", key = "play" } })
  h:assert_eq(#layer_dev:writes(), 0, "a shift-only mapping leaves the normal left click untouched")
  layer_dev:queue_read(report(0x11, 0xff, 0x01, 0x41, {}))
  layer_dev:key_remap_layer(true)
  h:assert_eq(last_table().data[4], 0x41, "engaging the layer rewrites the remap table")
  h:assert_eq(last_table().data[5], 0, "left click is suppressed while the layer is held")
  h:assert_eq(last_table().data[14], 0, "G8 stays suppressed on the shift layer")
  layer_dev:queue_read(report(0x11, 0xff, 0x01, 0x41, {}))
  layer_dev:key_remap_layer(false)
  h:assert_eq(last_table().data[5], 1, "releasing the layer restores the native left click")
  h:assert_eq(last_table().data[14], 0, "G8 stays suppressed after release")
  local writes_before = #layer_dev:writes()
  layer_dev:key_remap_layer(false)
  h:assert_eq(#layer_dev:writes(), writes_before, "an unchanged layer state writes nothing")

  -- Firmware ignores button divert while a mouse is in onboard mode, so remap
  -- only works in host mode. A mouse with ONBOARD_PROFILES must advertise that
  -- requirement and report the live mode so the UI can prompt the user.
  local function onboard_remap_dev(mode)
    return h:open({ pid = 0xc095, reads = {
      report(0x10, 0xff, 0x00, 0x01, { 2 }),
      report(0x11, 0xff, 0x02, 0x01, { 2 }),
      report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x00 }), -- ONBOARD_PROFILES
      report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x10 }), -- MOUSE_BUTTON_SPY
      report(0x11, 0xff, 0x01, 0x01, { 1, 1, 0, 1, 1, 0, 2, 0, 16 }),
      report(0x11, 0xff, 0x01, 0x21, { mode }),
      report(0x11, 0xff, 0x01, 0x51, { 0, 1, 1, 0 }),
      report(0x11, 0xff, 0x01, 0x41, { 0, 1 }),
      report(0x11, 0xff, 0x01, 0x51, { 0, 0, 0, 0 }),
      report(0x11, 0xff, 0x02, 0x31, { 1, 2, 3, 4, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }),
      report(0x11, 0xff, 0x02, 0x11, {}), -- start spy
      report(0x11, 0xff, 0x02, 0x41, {}), -- remap table per default mapping
      report(0x11, 0xff, 0x02, 0x41, {}),
      report(0x11, 0xff, 0x02, 0x41, {}),
    } })
  end
  local onboard_mode_dev = onboard_remap_dev(1)
  h:assert(onboard_mode_dev:initialize(), "onboard-mode mouse remap fixture initializes")
  local onboard_remap = onboard_mode_dev:key_remap_status()
  h:assert(onboard_remap.requires_host_mode, "onboard mouse requires host mode for remap")
  h:assert(not onboard_remap.host_mode_active, "onboard-mode mouse reports host mode inactive")
  onboard_mode_dev:set_button_mapping({ cid = 2,
    base = { type = "dpi_cycle", direction = "up" }, shifted = { type = "native" } })
  onboard_mode_dev:clear()
  onboard_mode_dev:queue_read(report(0x11, 0xff, 0x01, 0x11, {}))
  onboard_mode_dev:queue_read(report(0x11, 0xff, 0x02, 0x11, {}))
  onboard_mode_dev:queue_read(report(0x11, 0xff, 0x02, 0x41, {}))
  onboard_mode_dev:set_boolean("host_mode", true)
  local restored_writes = onboard_mode_dev:writes()
  h:assert_eq(#restored_writes, 3, "host-mode restore re-arms cached button overrides")
  h:assert_eq(restored_writes[1].data[3], 1, "restore switches onboard mode first")
  h:assert_eq(restored_writes[2].data[3], 2, "restore then restarts button spying")
  h:assert_eq(restored_writes[2].data[4], 0x11, "button spying restarts with function 0x10")
  h:assert_eq(restored_writes[3].data[4], 0x41, "restore rewrites the remap table once")

  onboard_mode_dev:clear()
  onboard_mode_dev:queue_read(report(0x11, 0xff, 0x01, 0x11, {}))
  local rearm_ok = pcall(function() onboard_mode_dev:set_boolean("host_mode", true) end)
  h:assert(not rearm_ok, "a failed button re-arm fails mode restoration")
  onboard_mode_dev:clear()
  onboard_mode_dev:queue_read(report(0x11, 0xff, 0x01, 0x11, {}))
  onboard_mode_dev:queue_read(report(0x11, 0xff, 0x02, 0x11, {}))
  onboard_mode_dev:queue_read(report(0x11, 0xff, 0x02, 0x41, {}))
  onboard_mode_dev:set_boolean("host_mode", true)
  h:assert_eq(#onboard_mode_dev:writes(), 3,
    "retry retains desired mappings and re-arms reporting even when already in host mode")

  local host_mode_dev = onboard_remap_dev(2)
  h:assert(host_mode_dev:initialize(), "host-mode mouse remap fixture initializes")
  h:assert(host_mode_dev:key_remap_status().host_mode_active,
    "host-mode mouse reports host mode active")

  -- A LIGHTSPEED receiver uses HID++ 1.0 register reads at devnum 0xff to
  -- enumerate paired slots. The child receives slot 1 as its opaque key.
  local receiver = h:open({ pid = 0xc547, reads = {
    report(0x10, 0xff, 0x81, 0, {0x01,0x10,0x02}),
    report(0x10, 0xff, 0x80, 0, {0,9,0}),
    report(0x10, 0xff, 0x81, 0x02, { 0, 1 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0x30, 0, 0, 0x12, 0x34 }), -- stale bank reply
    report(0x11, 0xff, 0x83, 0xb5, { 0x20, 0, 0, 0x40, 0xb0, 0, 0, 0x01 }),
    report(0x10, 0xff, 0x83, 0xb5, { 0x30, 0xab, 0xcd, 0xef, 0x12 }),
  } })
  h:assert(receiver:initialize(), "receiver root initializes")
  h:assert_eq(receiver:writes()[1].data[3], 0x81, "receiver reads notification flags first")
  h:assert_eq(receiver:writes()[2].data,{0x10,0xff,0x80,0,0x01,0x19,0x02},
    "receiver adds wireless and software notifications without clearing other flags")
  receiver:clear()
  local children = receiver:enumerate_controllers()
  h:assert_eq(#children, 1, "receiver enumerates one paired slot")
  h:assert_eq(children[1].id, "logitech-ABCDEF12", "receiver child shares the id of the wired device")
  h:assert_eq(children[1].device_type, "keyboard", "pairing-record kind identifies a keyboard")
  local receiver_writes = receiver:writes()
  h:assert_eq(receiver_writes[1].data[3], 0x81, "device count uses HID++ 1.0 short read")
  h:assert_eq(receiver_writes[2].data[3], 0x83, "receiver-info uses banked HID++ 1.0 read")
  h:assert_eq(receiver_writes[2].data[5], 0x20, "pairing info slot selector")
  h:assert_eq(receiver_writes[3].data[5], 0x30, "extended-pairing selector")

  -- Receiver behavior is a device capability shared by the HID++ 1.x
  -- families, not a special case tied to the C547 LIGHTSPEED PID. The pairing
  -- record's kind nibble identifies devices unknown to the small WPID catalog.
  local unifying = h:open({ pid = 0xc52b, reads = {
    report(0x10, 0xff, 0x81, 0, {0,0,0}),
    report(0x10, 0xff, 0x80, 0, {0,9,0}),
    report(0x10, 0xff, 0x81, 0x02, { 0, 1 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0x20, 0, 0, 0x12, 0x34, 0, 0, 0x02 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0x30, 0x12, 0x34, 0x56, 0x78 }),
  } })
  h:assert(unifying:initialize(), "Unifying receiver root initializes")
  local unifying_children = unifying:enumerate_controllers()
  h:assert_eq(#unifying_children, 1, "Unifying receiver enumerates paired slot")
  h:assert_eq(unifying_children[1].device_type, "mouse", "pairing-record kind supplies device type")

  local wireless_child = h:open({ key = "1", reads = {
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }), -- wake ping: live, protocol 4.5
    report(0x10, 0x01, 0x00, 0x01, { 2 }),
    report(0x11, 0x01, 0x02, 0x01, { 1 }),
    report(0x11, 0x01, 0x02, 0x11, { 0x1d, 0x4b }), -- WIRELESS_DEVICE_STATUS
  } })
  h:assert(wireless_child:initialize(), "receiver child initializes")
  local child_writes = wireless_child:writes()
  h:assert_eq(#child_writes, 4, "receiver child init is ping plus the feature walk")
  h:assert_eq(child_writes[1].data[3], 0x00, "receiver child init opens with a ROOT request")
  h:assert_eq(child_writes[1].data[4], 0x11, "wake ping uses getProtocolVersion with software id")
  h:assert_eq(child_writes[1].data[7], 0x5a, "wake ping carries the echo payload byte")
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

  rgb_dev:clear()
  for _, r in ipairs({
    {}, {}, {}, {},
    report(0x11, 0xff, 0x01, 0x51, {}),
    report(0x11, 0xff, 0x01, 0x11, {}),
  }) do rgb_dev:queue_read(r) end
  rgb_dev:apply({ mode = "static", color = { r = 1, g = 2, b = 3 } })
  local retry_writes = rgb_dev:writes()
  h:assert_eq(#retry_writes, 3, "an unanswered reclaim is retried before the apply")
  h:assert_eq(retry_writes[2].data[4], 0x51, "the retry repeats the software-control request")
  h:assert_eq(retry_writes[3].data[4], 0x11, "the apply follows the acknowledged reclaim")

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

  -- The receiver answers for an absent child in its own HID++ 1.0 code space,
  -- where 0x08 is "unknown device" and not the feature-level "busy" a device
  -- would mean by it. Only the reply class separates them.
  local err_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x83, 0x10 }),
    report(0x11, 0xff, 0x01, 0x01, { 2, 12, 0, 0, 0 }),
    report(0x11, 0xff, 0x01, 0x11, { 0, 0, 31, 0, 250 }),
    report(0x11, 0xff, 0x01, 0x21, { 0xfb, 6 }),
    report(0x10, 0xff, 0x8f, 0x01, { 0x31, 0x08 }),
    report(0x10, 0xff, 0xff, 0x01, { 0x31, 0x08 }),
  } })
  h:assert(err_dev:initialize(), "error-reply fixture initializes")
  err_dev:get_equalizer()
  local _, receiver_err = pcall(function() err_dev:set_eq_bands({ 0, 0 }) end)
  h:assert(tostring(receiver_err):match("0x08 %(unknown device%) from the receiver"),
    "a 0x8f reply decodes in the receiver's code space")
  local _, feature_err = pcall(function() err_dev:set_eq_bands({ 0, 0 }) end)
  h:assert(tostring(feature_err):match("0x08 %(busy%) from the device"),
    "a 0xff reply decodes in the feature code space")

  -- Effect table as reported by a PRO X TKL: Off, Static, Breathing,
  -- Color Cycle S (0x15), Color Wave S (0x16), Ripple S (0x17).
  local function tkl_effects_dev()
    return h:open({ pid = 0xc352, reads = {
      report(0x10, 0xff, 0x00, 0x01, { 2 }),
      report(0x11, 0xff, 0x02, 0x01, { 1 }),
      report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x71 }),
      report(0x11, 0xff, 0x01, 0x01, { 0xff, 0, 1 }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 1, 6 }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0x00, 0x00 }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 1, 0x00, 0x01 }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 2, 0x00, 0x0a }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 3, 0x00, 0x15 }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 4, 0x00, 0x16 }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 5, 0x00, 0x17 }),
      report(0x11, 0xff, 0x01, 0x51, {}),
      report(0x11, 0xff, 0x01, 0x51, {}),
      report(0x11, 0xff, 0x01, 0x11, {}),
    } })
  end
  local native_dev = tkl_effects_dev()
  h:assert(native_dev:initialize(), "native-effect fixture initializes")
  local tkl_effects = {}
  for _, effect in ipairs(native_dev:lighting_descriptor().native_effects or {}) do tkl_effects[effect.id] = effect end
  h:assert(tkl_effects.off and tkl_effects.breathing and tkl_effects.color_cycle
    and tkl_effects.color_wave and tkl_effects.ripple, "keyboard advertises every effect its firmware reports")
  h:assert(tkl_effects.decomposition == nil, "effects absent from the firmware table are not advertised")
  native_dev:clear()
  native_dev:apply({ mode = "native_effect", id = "ripple", params = {
    background = { r = 1, g = 2, b = 3 }, rate = 25, saturation = 50,
  } })
  local native_writes = native_dev:writes()
  h:assert_eq(native_writes[1].data[4], 0x51, "native effect reclaims RGB software control")
  h:assert_eq(native_writes[2].data[4], 0x11, "native effect uses RGB SetEffect")
  h:assert_eq(native_writes[2].data[5], 0, "native effect addresses the zone that reports it")
  h:assert_eq(native_writes[2].data[6], 5, "ripple selects the slot reporting Ripple S (0x17)")
  h:assert_eq(native_writes[2].data[7], 1, "native effect overlays background red")
  h:assert_eq(native_writes[2].data[9], 3, "native effect overlays background blue")
  h:assert_eq(native_writes[2].data[10], 127, "native effect scales saturation")
  h:assert_eq(native_writes[2].data[13], 0, "ripple S period high byte")
  h:assert_eq(native_writes[2].data[14], 25, "ripple S period low byte")
  h:assert_eq(native_writes[2].data[17], 0x01, "native effect applies without NV persistence")

  local wave_dev = tkl_effects_dev()
  h:assert(wave_dev:initialize(), "color-wave fixture initializes")
  wave_dev:clear()
  wave_dev:apply({ mode = "native_effect", id = "color_wave", params = {
    rate = 3000, direction = "center_out", brightness = 40, saturation = 100,
  } })
  local ww = wave_dev:writes()
  h:assert_eq(ww[2].data[6], 4, "color wave selects the slot reporting Color Wave S (0x16)")
  h:assert_eq(ww[2].data[8], 255, "color wave S saturation")
  h:assert_eq(ww[2].data[13], 0x0b, "color wave S period high byte")
  h:assert_eq(ww[2].data[14], 0xb8, "color wave S period low byte")
  h:assert_eq(ww[2].data[15], 40, "color wave S intensity")
  h:assert_eq(ww[2].data[16], 3, "color wave S direction byte")

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

  -- FN_INVERSION replies [host, inverted, default, caps] and takes [host, state];
  -- a v0 feature (PRO X TKL) accepts the setter.
  local fn_dev = h:open({ pid = 0xc352, reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x40, 0xa3, 0, 0 }),
    report(0x11, 0xff, 0x01, 0x01, { 0, 1, 0, 1 }),
  } })
  h:assert(fn_dev:initialize(), "fn-inversion fixture initializes")
  local fn_writes = fn_dev:writes()
  h:assert_eq(fn_writes[#fn_writes].data[5], 0, "fn-inversion get addresses host 0")
  fn_dev:clear()
  fn_dev:queue_read(report(0x11, 0xff, 0x01, 0x11, { 0, 0, 0, 1 }))
  fn_dev:set_boolean("fn_inversion", false)
  local fn_set = fn_dev:writes()[#fn_dev:writes()]
  h:assert_eq(fn_set.data[4], 0x11, "fn-inversion set uses function 0x10")
  h:assert_eq(fn_set.data[5], 0, "fn-inversion set addresses host 0")
  h:assert_eq(fn_set.data[6], 0, "fn-inversion set carries the state second")

  -- Effect table as reported by a G502 X Plus: Off, Static, Breathing, Cycle.
  local function g502_effects_dev()
    return h:open({ pid = 0xc095, reads = {
      report(0x10, 0xff, 0x00, 0x01, { 2 }),
      report(0x11, 0xff, 0x02, 0x01, { 2 }),
      report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x71 }),
      report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x81 }),
      report(0x11, 0xff, 0x01, 0x01, { 0xff, 0, 1 }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0, 1, 4 }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 0, 0x00, 0x00 }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 1, 0x00, 0x01 }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 2, 0x00, 0x0a, 0xc0, 0x01, 0x1e, 0x0b }),
      report(0x11, 0xff, 0x01, 0x01, { 0, 3, 0x00, 0x03, 0xc0, 0x05, 0x03, 0xe0 }),
      report(0x11, 0xff, 0x03, 0x01, { 0, 0, 0xfe, 0x01 }),
      report(0x11, 0xff, 0x03, 0x01, { 0, 0 }),
      report(0x11, 0xff, 0x03, 0x01, { 0, 0 }),
      report(0x11, 0xff, 0x02, 0x01, { 0, 0, 0xfe, 0x01 }),
      report(0x11, 0xff, 0x02, 0x01, { 0, 0 }),
      report(0x11, 0xff, 0x02, 0x01, { 0, 0 }),
      report(0x11, 0xff, 0x01, 0x51, {}),
      report(0x11, 0xff, 0x01, 0x51, {}),
      report(0x11, 0xff, 0x01, 0x11, {}),
    } })
  end
  local breathe_dev = g502_effects_dev()
  h:assert(breathe_dev:initialize(), "G502 effect-table fixture initializes")
  local advertised = {}
  for _, effect in ipairs(breathe_dev:lighting_descriptor().native_effects or {}) do advertised[effect.id] = true end
  h:assert(advertised.off and advertised.breathing and advertised.color_cycle,
    "G502 advertises firmware off, breathing and cycle")
  h:assert(not advertised.color_wave and not advertised.ripple,
    "G502 does not advertise wave or ripple, which its firmware lacks")
  breathe_dev:clear()
  breathe_dev:apply({ mode = "native_effect", id = "breathing", params = {
    color = { r = 0x10, g = 0x20, b = 0x30 }, rate = 5000, brightness = 0,
  } })
  local bw = breathe_dev:writes()
  h:assert_eq(bw[2].data[4], 0x11, "breathing uses RGB SetEffect")
  h:assert_eq(bw[2].data[5], 0, "breathing addresses zone 0")
  h:assert_eq(bw[2].data[6], 2, "breathing selects the slot reporting effect 0x0A")
  h:assert_eq(bw[2].data[7], 0x10, "breathing red")
  h:assert_eq(bw[2].data[9], 0x30, "breathing blue")
  h:assert_eq(bw[2].data[10], 0x13, "breathing period high byte")
  h:assert_eq(bw[2].data[11], 0x88, "breathing period low byte")
  h:assert_eq(bw[2].data[13], 1, "breathing intensity never encodes zero")
  h:assert_eq(bw[2].data[17], 0x01, "breathing persist byte")

  local cycle_dev = g502_effects_dev()
  h:assert(cycle_dev:initialize(), "G502 cycle fixture initializes")
  cycle_dev:clear()
  cycle_dev:apply({ mode = "native_effect", id = "color_cycle", params = { rate = 10000, brightness = 60 } })
  local cw = cycle_dev:writes()
  h:assert_eq(cw[2].data[6], 3, "cycle selects the slot reporting effect 0x03")
  h:assert_eq(cw[2].data[12], 0x27, "cycle period high byte")
  h:assert_eq(cw[2].data[13], 0x10, "cycle period low byte")
  h:assert_eq(cw[2].data[14], 60, "cycle intensity")

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
    report(0x11, 0xff, 0x03, 0x01,
      { 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0xfe, 0xff }),
    report(0x11, 0xff, 0x03, 0x01, { 0, 1, 0, 0, 0, 0, 0x40, 0x0f }), -- media LEDs 150, 152..155
    report(0x11, 0xff, 0x03, 0x01, { 0, 2 }),
    report(0x11, 0xff, 0x01, 0x51, {}),
    report(0x11, 0xff, 0x02, 0x11, { 73, 0, 0 }),       -- initial battery cache fill
    report(0x11, 0xff, 0x01, 0x51, {}), -- reclaim before Paint apply
    report(0x11, 0xff, 0x01, 0x51, {}), -- reclaim before first static apply
    report(0x11, 0xff, 0x01, 0x51, {}), -- reclaim before repeated static apply
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
  h:assert_eq(media_brightness.cell.col, 5.0, "a registered extra key keeps its own cell")
  h:assert_eq(#keyboard_dev:lighting_descriptor().channels[1].leds, 99,
    "the layout covers exactly the LEDs the firmware advertises")
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
  for _ = 1, #keyboard_lighting.channels[1].leds do
    breathing[#breathing + 1] = 10
    breathing[#breathing + 1] = 20
    breathing[#breathing + 1] = 30
  end
  keyboard_dev:write_frame("zone_0", breathing)
  local frame_writes = keyboard_dev:writes()
  h:assert_eq(#frame_writes, 2, "uniform per-key frame is one range plus commit")
  h:assert_eq(frame_writes[1].data[4], 0x51, "per-key frame uses SET_RANGE")
  h:assert_eq(frame_writes[1].data[5], 1, "per-key range starts at first firmware LED")
  h:assert_eq(frame_writes[1].data[6], 155, "per-key range ends at last firmware LED")
  h:assert_eq(frame_writes[2].data[4], 0x71, "per-key frame commits atomically")
  keyboard_dev:clear()
  local led_4_index
  for i, led in ipairs(keyboard_lighting.channels[1].leds) do
    if led.id == 4 then led_4_index = i end
  end
  h:assert(led_4_index ~= nil, "keyboard RGB descriptor contains firmware LED 4")
  local led_4_offset = (led_4_index - 1) * 3
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

  keyboard_dev:clear()
  keyboard_dev:apply({ mode = "static", color = { r = 0xa7, g = 0x8b, b = 0xfa } })
  local first_static = keyboard_dev:writes()
  h:assert_eq(first_static[1].data[4], 0x51, "static apply reclaims RGB software control")
  h:assert_eq(first_static[2].data[4], 0x51, "static apply writes the frame as a range")
  keyboard_dev:clear()
  keyboard_dev:apply({ mode = "static", color = { r = 0xa7, g = 0x8b, b = 0xfa } })
  local repeated = keyboard_dev:writes()
  h:assert_eq(#repeated, #first_static, "re-applying the same colour writes the frame again")
  h:assert_eq(repeated[2].data[7], 0xa7, "repeated static apply carries the colour, not a no-op")

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
    report(0x10, 0xff, 0x81, 0, {0,0,0}),
    report(0x10, 0xff, 0x80, 0, {0,9,0}),
    report(0x10, 0xff, 0x81, 0x02, { 0, 1 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0x20, 0, 0, 0x40, 0xb0 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0x30, 0xab, 0xcd, 0xef, 0x12 }),
  } })
  h:assert(mixed_rx:initialize(), "mixed-collection receiver root initializes")
  local mixed_children = mixed_rx:enumerate_controllers()
  h:assert_eq(#mixed_children, 1, "receiver enumerates a slot from mixed short/long replies")
  h:assert_eq(mixed_children[1].id, "logitech-ABCDEF12", "child serial decoded from a long pairing reply")

  -- Unpairing leaves holes: slot 1 returns HID++1 INVALID_ADDRESS (0x09),
  -- while the mouse remains paired in slot 2. Enumeration must continue so
  -- the mouse stays registered and pairing_status remains available.
  local sparse_rx = h:open({ pid = 0xc547, reads = {
    report(0x10, 0xff, 0x81, 0, {0,0,0}),
    report(0x10, 0xff, 0x80, 0, {0,9,0}),
    report(0x10, 0xff, 0x81, 0x02, { 0, 1 }),
    report(0x10, 0xff, 0x8f, 0x83, { 0xb5, 0x09 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0x21, 0, 0, 0x40, 0x99, 0, 0, 0x02 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0x31, 0x12, 0x34, 0x56, 0x78 }),
  } })
  h:assert(sparse_rx:initialize(), "sparse receiver root initializes")
  sparse_rx:clear()
  local sparse_children = sparse_rx:enumerate_controllers()
  h:assert_eq(#sparse_children, 1, "empty slot does not hide a later paired mouse")
  h:assert_eq(sparse_children[1].id, "logitech-12345678", "later-slot mouse keeps its identity")
  h:assert_eq(sparse_children[1].device_type, "mouse", "pairing-record kind identifies a mouse")
  local sparse_writes = sparse_rx:writes()
  h:assert_eq(sparse_writes[2].data[5], 0x20, "sparse scan probes empty slot 1")
  h:assert_eq(sparse_writes[3].data[5], 0x21, "sparse scan continues to paired slot 2")
  h:assert_eq(sparse_writes[4].data[5], 0x31, "sparse scan reads slot 2 extended identity")

  -- Pairing-lock notifications are HID++ 1.0 packets. Byte 4 is the lock
  -- state, not a HID++ 2.0 software id: an open notification must reach Lua,
  -- and a clean close must both finish the UI state and rescan receiver slots.
  local pairing_rx = h:open({ pid = 0xc547, reads = {report(0x10,0xff,0x81,0,{0,0,0}), report(0x10,0xff,0x80,0,{0,9,0})} })
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

  -- G560 speaker: long-only HID++ 2.0 with the live feature table and replies.
  local function g560_dev()
    local reads = {
      report(0x11, 0xff, 0x00, 0x01, { 1 }),
      report(0x11, 0xff, 0x01, 0x01, { 9 }),
    }
    for _, code in ipairs({ 0x0001, 0x0003, 0x0005, 0x8070, 0x8010, 0x8310, 0x8320, 0x8040, 0x8305 }) do
      reads[#reads + 1] = report(0x11, 0xff, 0x01, 0x11, { code >> 8, code & 0xff })
    end
    local name = "G560 Gaming Speaker"
    reads[#reads + 1] = report(0x11, 0xff, 0x03, 0x01, { #name })
    for offset = 0, #name - 1, 16 do
      reads[#reads + 1] = report(0x11, 0xff, 0x03, 0x11, { name:byte(offset + 1, math.min(#name, offset + 16)) })
    end
    reads[#reads + 1] = report(0x11, 0xff, 0x05, 0x01, { 1 })
    reads[#reads + 1] = report(0x11, 0xff, 0x04, 0x01, { 4, 0, 3, 0, 5 })
    for zone = 0, 3 do
      reads[#reads + 1] = report(0x11, 0xff, 0x04, 0x11, { zone, 0, zone + 1, 5 })
      for slot, id in ipairs({ 0x00, 0x01, 0x03, 0x07, 0x0a }) do
        reads[#reads + 1] = report(0x11, 0xff, 0x04, 0x21, { zone, slot - 1, 0, id })
      end
    end
    reads[#reads + 1] = report(0x11, 0xff, 0x04, 0x81, {})
    reads[#reads + 1] = report(0x11, 0xff, 0x06, 0x01, { 10, 26, 0, 0xec, 6 })
    reads[#reads + 1] = report(0x11, 0xff, 0x06, 0x11, { 0, 0, 32, 0, 64, 0, 125, 0, 250, 1, 244, 3, 232, 7, 208 })
    reads[#reads + 1] = report(0x11, 0xff, 0x06, 0x11, { 7, 15, 160, 31, 64, 62, 128 })
    reads[#reads + 1] = report(0x11, 0xff, 0x06, 0x21, {})
    reads[#reads + 1] = report(0x11, 0xff, 0x09, 0x01, { 50 })
    reads[#reads + 1] = report(0x11, 0xff, 0x08, 0x01, { 0, 100, 4, 0 })
    reads[#reads + 1] = report(0x11, 0xff, 0x08, 0x11, { 0, 50 })
    return h:open({ pid = 0x0a78, refused_report_ids = { 0x10 }, reads = reads })
  end
  local g560 = g560_dev()
  h:assert(g560:initialize(), "G560 initializes through the standard HID++ path")
  h:assert_eq(g560:writes()[1].data[1], 0x11, "G560 ROOT lookup uses a long report")
  local g560_light = g560:lighting_descriptor()
  h:assert_eq(#g560_light.channels, 4, "G560 has four zones")
  local g560_names = {}
  for _, channel in ipairs(g560_light.channels) do g560_names[channel.id] = channel.name end
  h:assert_eq(g560_names.zone_2, "Left Primary", "G560 zone names come from its profile")
  local g560_effects = {}
  for _, effect in ipairs(g560_light.native_effects or {}) do g560_effects[effect.id] = true end
  h:assert(g560_effects.off and g560_effects.color_cycle and g560_effects.breathing,
    "G560 advertises its 0x8070 firmware effects")

  g560:clear()
  g560:queue_read(report(0x11, 0xff, 0x04, 0x81, {}))
  for _ = 1, 4 do g560:queue_read(report(0x11, 0xff, 0x04, 0x31, {})) end
  g560:apply({ mode = "static", color = { r = 255, g = 0, b = 128 } })
  local gw = g560:writes()
  h:assert_eq(gw[4].data[5], 2, "static writes zone 2 third")
  h:assert_eq(gw[4].data[6], 1, "static uses the slot reporting effect 0x01")
  h:assert_eq(gw[4].data[7], 255, "static red")
  h:assert_eq(gw[4].data[10], 0x02, "static carries the fixed-effect 0x02 parameter")

  g560:clear()
  g560:queue_read(report(0x11, 0xff, 0x04, 0x81, {}))
  for _ = 1, 4 do g560:queue_read(report(0x11, 0xff, 0x04, 0x31, {})) end
  g560:apply({ mode = "native_effect", id = "breathing", params = { color = { r = 1, g = 2, b = 3 }, rate = 3000, brightness = 70 } })
  gw = g560:writes()
  h:assert_eq(gw[2].data[3], 0x04, "native effect uses COLOR_LED_EFFECTS on a 0x8070 device")
  h:assert_eq(gw[2].data[4], 0x31, "native effect uses setZoneEffect")
  h:assert_eq(gw[2].data[6], 4, "breathing selects the slot reporting effect 0x0A")
  h:assert_eq(gw[2].data[10], 0x0b, "breathing period high byte")
  h:assert_eq(gw[2].data[13], 70, "breathing intensity")

  local g560_eq = g560:get_equalizer()
  h:assert_eq(#g560_eq.bands, 10, "G560 EQ has ten bands")
  h:assert_eq(g560_eq.bands[1].min, -20.0, "G560 EQ minimum")
  h:assert_eq(g560_eq.presets[3].label, "FPS", "G560 profile presets are offered")
  h:assert_eq(g560_eq.selected_preset, 1, "a flat device curve selects the Flat preset")
  g560:clear()
  g560:queue_read(report(0x11, 0xff, 0x06, 0x31, { 2 }))
  g560:set_eq_preset(2)
  h:assert_eq(g560:writes()[1].data, { 0x11, 0xff, 0x06, 0x31, 0x02, 0, 0, 0xfa, 0xfb, 0xfd, 0xfe, 0xfd, 0xfd, 0xfb, 0xfa, 0, 0, 0, 0, 0 },
    "FPS preset writes its bands with the 0x02 prefix")
  h:assert_eq(g560:get_equalizer().selected_preset, 2, "preset selection is kept")
  g560:clear()
  g560:queue_read(report(0x11, 0xff, 0x06, 0x31, { 2 }))
  g560:set_eq_bands({ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
  h:assert_eq(g560:get_equalizer().selected_preset, 0, "custom bands select Custom")

  g560:clear()
  g560:queue_read(report(0x11, 0xff, 0x09, 0x11, {}))
  g560:set_range("subwoofer_volume", 101)
  h:assert_eq(g560:writes()[1].data, { 0x11, 0xff, 0x09, 0x11, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    "G560 subwoofer volume uses BASS_TONE and clamps to 100")

  g560:clear()
  g560:queue_read(report(0x11, 0xff, 0x08, 0x21, {}))
  g560:set_range("brightness", 40)
  h:assert_eq(g560:writes()[1].data[6], 50, "G560 brightness snaps to its nearest accepted level")

  local g560_remap = g560:key_remap_status()
  h:assert_eq(#g560_remap.buttons, 1, "G560 exposes its G-key")
  h:assert_eq(g560_remap.buttons[1].label, "G1", "G560 G-key label")

  -- PRO X Wireless: ADC_MEASUREMENT 0x10 reports the auto power-off timer.
  local prox = h:open({ pid = 0x0aba, refused_report_ids = { 0x10 }, reads = {
    report(0x11, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x1f, 0x20 }),
    report(0x11, 0xff, 0x01, 0x11, { 30 }),
  } })
  h:assert(prox:initialize(), "PRO X power-off fixture initializes")
  prox:clear()
  prox:queue_read(report(0x11, 0xff, 0x01, 0x21, {}))
  prox:set_range("power_off_timer", 90)
  h:assert_eq(prox:writes()[1].data[4], 0x21, "power-off timer set uses function 0x20")
  h:assert_eq(prox:writes()[1].data[5], 60, "power-off timer clamps to 60 minutes")

  -- A powered-off device is rejected, not failed, so the daemon re-registers it
  -- silently once it wakes. An off PRO X headset still enumerates through its
  -- dongle and only errors (0x05) once a read needs the headset itself; a
  -- receiver child that is off instead answers nothing at all. Neither may raise.
  local asleep_headset = h:open({ pid = 0x0aba, refused_report_ids = { 0x10 }, reads = {
    report(0x11, 0xff, 0x00, 0x01, { 2 }),          -- ROOT -> FEATURE_SET index
    report(0x11, 0xff, 0x02, 0x01, { 1 }),          -- FEATURE_SET count
    report(0x11, 0xff, 0x02, 0x11, { 0x83, 0x00 }), -- feature[1] = SIDETONE
    -- [report, devnum, 0xff, feature_idx=1, func_byte=0x01, err_code=0x05]
    report(0x11, 0xff, 0xff, 0x01, { 0x01, 0x05 }),
  } })
  h:assert(not asleep_headset:initialize(), "an error reply rejects rather than fails init")

  local silent_child = h:open({ key = "1", reads = {
    -- three wake-ping attempts, four empty read windows each
    {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {},
  } })
  h:assert(not silent_child:initialize(), "a device that answers nothing is rejected")

  -- A zeroed ROOT record is a sleeping slot, not a featureless device.
  local zeroed_child = h:open({ key = "1", reads = {
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }), report(0x10, 0x01, 0x00, 0x01, { 0 }),
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }), report(0x10, 0x01, 0x00, 0x01, { 0 }),
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }), report(0x10, 0x01, 0x00, 0x01, { 0 }),
  } })
  h:assert(not zeroed_child:initialize(), "a zeroed ROOT reply is rejected")

  -- ROOT resolves from the receiver's pairing cache, so a sleeping slot can get
  -- past the index lookup and zero the enumeration instead. Both shapes leave a
  -- table with no features and must be rejected, or the daemon registers the
  -- device with no capabilities and nothing ever re-initializes it.
  local empty_count_child = h:open({ key = "1", reads = {
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }),
    report(0x10, 0x01, 0x00, 0x01, { 2 }), report(0x11, 0x01, 0x02, 0x01, { 0 }),
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }),
    report(0x10, 0x01, 0x00, 0x01, { 2 }), report(0x11, 0x01, 0x02, 0x01, { 0 }),
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }),
    report(0x10, 0x01, 0x00, 0x01, { 2 }), report(0x11, 0x01, 0x02, 0x01, { 0 }),
  } })
  h:assert(not empty_count_child:initialize(), "a zeroed feature count is rejected")

  local zeroed_ids_child = h:open({ key = "1", reads = {
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }),
    report(0x10, 0x01, 0x00, 0x01, { 2 }), report(0x11, 0x01, 0x02, 0x01, { 1 }),
    report(0x11, 0x01, 0x02, 0x11, { 0, 0 }),
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }),
    report(0x10, 0x01, 0x00, 0x01, { 2 }), report(0x11, 0x01, 0x02, 0x01, { 1 }),
    report(0x11, 0x01, 0x02, 0x11, { 0, 0 }),
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }),
    report(0x10, 0x01, 0x00, 0x01, { 2 }), report(0x11, 0x01, 0x02, 0x01, { 1 }),
    report(0x11, 0x01, 0x02, 0x11, { 0, 0 }),
  } })
  h:assert(not zeroed_ids_child:initialize(), "zeroed feature ids are rejected")

  -- The receiver can still zero a later feature reply once the slot has
  -- enumerated, such as the onboard-profile description; that is the same
  -- sleeping device, rejected so a connection event re-initializes it.
  local zeroed_onboard = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x00 }), -- ONBOARD_PROFILES
    report(0x11, 0xff, 0x01, 0x01, {}),             -- zeroed getDescription
  } })
  h:assert(not zeroed_onboard:initialize(), "a zeroed onboard description is rejected")

  -- A sleeping slot can bounce the ping request back instead of answering it;
  -- the echo carries protocol version zero, which no live device reports.
  local echoed_child = h:open({ key = "1", reads = {
    report(0x10, 0x01, 0x00, 0x11, { 0, 0, 0x5a }),
    report(0x10, 0x01, 0x00, 0x11, { 0, 0, 0x5a }),
    report(0x10, 0x01, 0x00, 0x11, { 0, 0, 0x5a }),
  } })
  h:assert(not echoed_child:initialize(), "a bounced ping echo is rejected")
  local echoed_writes = echoed_child:writes()
  h:assert_eq(#echoed_writes, 3, "a rejected ping is retried without starting the walk")
  h:assert_eq(echoed_writes[3].data[4], 0x11, "every rejected attempt is the wake ping")

  -- An offline slot answers the ping with a HID++ 1.0 error relayed by the
  -- receiver: rejected immediately, without retrying the walk.
  local offline_child = h:open({ key = "1", reads = {
    report(0x10, 0x01, 0x8f, 0x00, { 0x11, 0x09 }),
  } })
  h:assert(not offline_child:initialize(), "an offline slot's ping error rejects init")
  h:assert_eq(#offline_child:writes(), 1,
    "a receiver-reported offline slot is not retried and never walked")

  -- A paired device this plugin does not service (only classic BATTERY_STATUS
  -- 0x1000) that answers the ping is a real device: it keeps its
  -- connection-only registration instead of being mistaken for a sleeping slot.
  local office_child = h:open({ key = "1", reads = {
    report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }), -- wake ping: live
    report(0x10, 0x01, 0x00, 0x01, { 2 }),
    report(0x11, 0x01, 0x02, 0x01, { 1 }),
    report(0x11, 0x01, 0x02, 0x11, { 0x10, 0x00 }), -- BATTERY_STATUS
  } })
  h:assert(office_child:initialize(), "an unserviced but real feature table initializes")
  h:assert_eq(office_child:connection_status().connection_type, "wireless",
    "unserviced receiver child keeps its connection capability")

  local windows_asleep_headset = h:open({ pid = 0x0aba, refused_report_ids = { 0x10 },
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
    report(0x11, 0xff, 0x01, 0x01, { 2 }),                -- reprog control count
    report(0x11, 0xff, 0x01, 0x11, { 0, 0x38, 0, 0x38, 0x20, 0, 0 }), -- divertable cid 0x38
    report(0x11, 0xff, 0x01, 0x11, { 0, 0x39, 0, 0x39, 0x08, 0, 0 }), -- Fn-sensitive only
  } })
  h:assert(evt_dev:initialize(), "event fixture initializes past an interleaved packet")
  h:assert_eq(#evt_dev:key_remap_status().buttons, 1, "Fn-sensitive controls are not assumed divertable")
  local pumped = evt_dev:pump_events()
  h:assert_eq(#pumped, 1, "deferred interleaved packet is delivered through event()")
  h:assert_eq(pumped[1].pressed[1], 0x38, "event() decodes the deferred button press")

  evt_dev:queue_read(report(0x11, 0xff, 0x01, 0x31, {}))
  evt_dev:set_button_mapping({ cid = 0x38,
    base = { type = "dpi_cycle", direction = "up" }, shifted = { type = "native" } })
  local divert_writes = evt_dev:writes()
  h:assert_eq(divert_writes[#divert_writes].data[7], 0x03,
    "diversion enable includes the diverted-valid bit")
  evt_dev:queue_read(report(0x11, 0xff, 0x01, 0x31, {}))
  evt_dev:set_button_mapping({ cid = 0x38,
    base = { type = "native" }, shifted = { type = "native" } })
  divert_writes = evt_dev:writes()
  h:assert_eq(divert_writes[#divert_writes].data[7], 0x02,
    "diversion disable includes the diverted-valid bit")

  -- A queued button release for an already-pressed control produces a release
  -- transition on the next pump.
  evt_dev:queue_event(report(0x11, 0xff, 0x01, 0x00, {}))
  local released = evt_dev:pump_events()
  h:assert_eq(#released, 1, "release notification produces an event() outcome")
  h:assert_eq(released[1].released[1], 0x38, "event() decodes the button release")

  local labeled_dev = h:open({ reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 1 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x1b, 0x04 }),
    report(0x11, 0xff, 0x01, 0x01, { 2 }),
    report(0x11, 0xff, 0x01, 0x11, { 0x00, 0xe8, 0x00, 0xc8, 0x20, 0, 0 }),
    report(0x11, 0xff, 0x01, 0x11, { 0x0f, 0xff, 0x00, 0x00, 0x20, 0, 0 }),
  } })
  h:assert(labeled_dev:initialize(), "label fixture initializes")
  local labeled = labeled_dev:key_remap_status().buttons
  h:assert_eq(labeled[1].label, "Volume Down", "controls are labeled by CID, not by task id")
  h:assert_eq(labeled[2].label, "Button 0x0FFF", "unknown CIDs fall back to their hex id")

  -- Onboard profile codec against a real G502 X Plus sector 0x0001.
  local PROFILE = halod.require("lib.hidpp2.profile")
  local function crc16(data)
    local crc = 0xffff
    for i = 1, #data do
      crc = crc ~ (data:byte(i) << 8)
      for _ = 1, 8 do
        crc = ((crc & 0x8000) ~= 0) and (((crc << 1) ~ 0x1021) & 0xffff) or ((crc << 1) & 0xffff)
      end
    end
    return crc
  end
  local hex = "0102002003b00440066009800cffffffff00ffffffffffffffffffff3c002c01"
    .. "8001000180010002800100048001000890070000800100109001000090020000"
    .. "900a00009003000090040000ffffffffffffffffffffffffffffffffffffffff"
    .. "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    .. "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    .. "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    .. "ffffffffffffffffffffffffffffffff0f000000000000006400000f00000000"
    .. "000000640000100000000000000064000010000000000000006400000394fb"
  local raw = hex:gsub("..", function(x) return string.char(tonumber(x, 16)) end)
  h:assert_eq(#raw, 255, "fixture is one 255-byte sector")
  h:assert_eq(crc16(raw:sub(1, 253)), 0x94fb, "sector CRC is CRC-16/CCITT-FALSE")
  local parsed = PROFILE.parse(raw)
  h:assert_eq(parsed.report_rate, 1, "profile byte 0 is the report rate")
  h:assert_eq(parsed.dpi_default, 2, "default DPI index")
  h:assert_eq(PROFILE.dpi_steps(parsed), { 800, 1200, 1600, 2400, 3200 }, "DPI steps decode little-endian")
  h:assert_eq(parsed.power_save, 60, "power-save timeout")
  h:assert_eq(parsed.power_off, 300, "power-off timeout")
  h:assert_eq(parsed.buttons[1], { kind = "mouse", buttons = 1 }, "left click binding")
  h:assert_eq(parsed.buttons[5], { kind = "special", code = 7 }, "thumb binding is DPI shift")
  h:assert_eq(parsed.buttons[12], { kind = "disabled" }, "unused binding")
  h:assert_eq(parsed.shifted[1], { kind = "disabled" }, "empty G-shift layer")
  h:assert_eq(parsed.leds[1].id, 0x0f, "active LED record holds the signature effect")
  h:assert_eq(parsed.leds[3].id, 0x10, "power-saving LED record holds the inactive signature")
  local sig_active, sig_inactive = PROFILE.signature(parsed)
  h:assert_eq(sig_active, 0x0f, "signature effect detected")
  h:assert_eq(sig_inactive, 0x10, "paired inactive signature")
  h:assert_eq(PROFILE.serialize(parsed, crc16), raw, "parse/serialize round-trips a real sector byte for byte")

  for _, binding in ipairs({
    { kind = "disabled" }, { kind = "mouse", buttons = 0x0010 }, { kind = "key", modifiers = 0x02, key = 0x04 },
    { kind = "consumer", usage = 0x00e9 }, { kind = "special", code = 0x0a }, { kind = "macro", page = 3, offset = 0x20 },
  }) do
    h:assert_eq(PROFILE.decode_binding(PROFILE.encode_binding(binding)), binding,
      "binding round-trips: " .. binding.kind)
  end

  parsed.buttons[9] = { kind = "key", modifiers = 0, key = 0x2c }
  parsed.dpi[2], parsed.power_off = 1000, 600
  local edited = PROFILE.parse(PROFILE.serialize(parsed, crc16))
  h:assert_eq(edited.buttons[9], { kind = "key", modifiers = 0, key = 0x2c }, "edited binding persists")
  h:assert_eq(PROFILE.dpi_steps(edited)[2], 1000, "edited DPI step persists")
  h:assert_eq(edited.power_off, 600, "edited power-off timeout persists")
  h:assert_eq(edited.crc, crc16(PROFILE.serialize(parsed, crc16):sub(1, 253)), "edited sector carries a fresh CRC")

  -- Signature (Pulsar Point) on a G502 X Plus: advertised from the onboard
  -- profile's LED records and applied by rewriting them, then releasing LED
  -- control so the firmware plays the profile lighting.
  local function sector_replies(dev, index, data)
    local function chunk(offset)
      local out = {}
      for i = 1, 16 do out[i] = data:byte(offset + i) or 0 end
      dev:queue_read(report(0x11, 0xff, index, 0x51, out))
    end
    local offset = 0
    while offset + 15 < #data do chunk(offset); offset = offset + 16 end
    if offset < #data then chunk(#data - 16) end
  end
  local directory = "  " .. string.rep("ÿ", 251)
  local function g502_onboard_reads(dev, data)
    dev:queue_read(report(0x11, 0xff, 0x01, 0x01, { 1, 5, 1, 5, 2, 0x0b, 0x10, 0x00, 0xff, 0x0a, 4 }))
    dev:queue_read(report(0x11, 0xff, 0x01, 0x21, { 2 }))
    sector_replies(dev, 0x01, directory)
    dev:queue_read(report(0x11, 0xff, 0x01, 0x41, { 0, 1 }))
    sector_replies(dev, 0x01, data)
  end
  local sig_dev = h:open({ pid = 0xc095, reads = {
    report(0x10, 0xff, 0x00, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x01, { 2 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x81, 0x00 }),
    report(0x11, 0xff, 0x02, 0x11, { 0x80, 0x71 }),
  } })
  g502_onboard_reads(sig_dev, raw)
  for _, r in ipairs({
    report(0x11, 0xff, 0x02, 0x01, { 0xff, 0, 1 }),
    report(0x11, 0xff, 0x02, 0x01, { 0, 0, 0, 1, 4 }),
    report(0x11, 0xff, 0x02, 0x01, { 0, 0, 0x00, 0x00 }),
    report(0x11, 0xff, 0x02, 0x01, { 0, 1, 0x00, 0x01 }),
    report(0x11, 0xff, 0x02, 0x01, { 0, 2, 0x00, 0x0a }),
    report(0x11, 0xff, 0x02, 0x01, { 0, 3, 0x00, 0x03 }),
    report(0x11, 0xff, 0x02, 0x51, {}),
  }) do sig_dev:queue_read(r) end
  h:assert(sig_dev:initialize(), "G502 onboard + RGB fixture initializes")
  local sig_effect
  for _, effect in ipairs(sig_dev:lighting_descriptor().native_effects or {}) do
    if effect.id == "signature" then sig_effect = effect end
  end
  h:assert(sig_effect and sig_effect.name == "Pulsar Point", "G502 X Plus advertises Pulsar Point")

  sig_dev:clear()
  sig_dev:queue_read(report(0x11, 0xff, 0x02, 0x51, {}))
  g502_onboard_reads(sig_dev, raw)
  sig_dev:queue_read(report(0x11, 0xff, 0x01, 0x61, {}))
  for _ = 1, 16 do sig_dev:queue_read(report(0x11, 0xff, 0x01, 0x71, {})) end
  sig_dev:queue_read(report(0x11, 0xff, 0x01, 0x81, {}))
  g502_onboard_reads(sig_dev, raw)
  sig_dev:queue_read(report(0x11, 0xff, 0x02, 0x51, {}))
  sig_dev:apply({ mode = "native_effect", id = "signature", params = { brightness = 40 } })
  local sig_writes = sig_dev:writes()
  local written = {}
  for _, w in ipairs(sig_writes) do
    if w.data[3] == 0x01 and w.data[4] == 0x71 then
      for i = 5, 20 do written[#written + 1] = w.data[i] end
    end
  end
  h:assert_eq(#written, 256, "the whole profile sector is rewritten")
  h:assert_eq(written[0xd0 + 1], 0x0f, "active LED record keeps the signature effect")
  h:assert_eq(written[0xd0 + 9], 40, "active LED record carries the new brightness")
  h:assert_eq(written[0xe6 + 1], 0x10, "power-saving LED record keeps the inactive signature")
  local rewritten = string.char(table.unpack(written, 1, 255))
  h:assert_eq(crc16(rewritten:sub(1, 253)), (written[254] << 8) | written[255], "rewritten sector has a valid CRC")
  local release = sig_writes[#sig_writes]
  h:assert_eq(release.data[4], 0x51, "signature releases RGB software control")
  h:assert_eq(release.data[5], 1, "software control set operation")
  h:assert_eq(release.data[6], 0, "software control flags cleared")

  local unlisted_rx = h:open({ pid = 0xc547, reads = {
    report(0x10, 0xff, 0x81, 0, {0,0,0}),
    report(0x10, 0xff, 0x80, 0, {0,9,0}),
    report(0x10, 0xff, 0x81, 0x02, { 0, 1 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0x20, 0x1b, 0x08, 0x40, 0xb7, 0x11, 0, 0x01 }),
    report(0x11, 0xff, 0x83, 0xb5, { 0x30, 0x68, 0x2f, 0xd5, 0xfd }),
    report(0x11, 0xff, 0x83, 0xb5, { 0x40, 9, 0x47, 0x39, 0x39, 0x39, 0x20, 0x58, 0x20, 0x4c, 0x53 }),
  } })
  h:assert(unlisted_rx:initialize(), "receiver with an unlisted child initializes")
  unlisted_rx:clear()
  local unlisted_children = unlisted_rx:enumerate_controllers()
  h:assert_eq(#unlisted_children, 1, "unlisted paired device is enumerated")
  h:assert_eq(unlisted_children[1].name, "Logitech G999 X LS",
    "an unlisted child is named from the receiver's pairing record")
  h:assert_eq(unlisted_children[1].device_type, "keyboard", "unlisted child keeps its paired kind")
  h:assert_eq(unlisted_rx:writes()[4].data[5], 0x40, "codename uses the slot's name selector")
  h:assert_eq(children[1].name, "Logitech HID++ Device",
    "a child whose pairing record has no name gets the generic one")

  local function discovered_keyboard_dev(first_page)
    local dev = h:open({ pid = 0xc547, key = "1", reads = {
      report(0x10, 0x01, 0x00, 0x11, { 4, 5, 0x5a }),
      report(0x10, 0x01, 0x00, 0x01, { 2 }),
      report(0x11, 0x01, 0x02, 0x01, { 2 }),
      report(0x11, 0x01, 0x02, 0x11, { 0x80, 0x71 }),
      report(0x11, 0x01, 0x02, 0x11, { 0x80, 0x81 }),
      report(0x11, 0x01, 0x01, 0x01, { 0, 0, 2 }),
      report(0x11, 0x01, 0x01, 0x01, { 0, 0, 0, 0, 1 }),
      report(0x11, 0x01, 0x01, 0x01, { 0, 0, 0, 1 }),
      report(0x11, 0x01, 0x01, 0x01, { 1, 0, 0, 0, 1 }),
      report(0x11, 0x01, 0x01, 0x01, { 1, 0, 0, 1 }),
      report(0x11, 0x01, 0x02, 0x01, first_page),
      report(0x11, 0x01, 0x02, 0x01, { 0, 1, 0, 0, 0, 0, 0, 0x7a, 0, 0, 0xf0, 0x1f, 0, 0, 0x04, 0 }),
      report(0x11, 0x01, 0x02, 0x01, { 0, 2 }),
      report(0x11, 0x01, 0x01, 0x51, {}),
    } })
    h:assert(dev:initialize(), "unlisted multi-zone per-key keyboard initializes")
    return dev
  end
  local function key_by_led(status)
    local out = {}
    for _, key in ipairs(status.keys) do out[key.led_id] = key end
    return out
  end

  local full_dev = discovered_keyboard_dev(
    { 0, 0, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff })
  local full_channels = full_dev:lighting_descriptor().channels
  h:assert_eq(#full_channels, 1, "per-key LEDs replace the firmware's coarse zones")
  h:assert_eq(#full_channels[1].leds, 126, "every advertised per-key LED is addressable")
  local full_keys = key_by_led(full_dev:keyboard_layout_status())
  h:assert_eq(full_keys[1].cell.id, "a", "usage-ordered LED 1 is the A key")
  h:assert_eq(full_keys[111].cell.id, "right_super", "modifier LEDs follow the usage order")
  h:assert_eq(full_keys[95].cell.id, "num0", "numpad LEDs select the full-size template")
  h:assert_eq(full_keys[97], nil, "the ANSI variant has no ISO extra key")
  h:assert_eq(full_keys[99], nil, "usage-range LEDs without a standard key stay unplaced")
  h:assert_eq(full_keys[153].cell.row, -1.5, "vendor LEDs sit in a row above the keys")
  h:assert_eq(full_keys[153].cell.col, 0.0, "vendor LEDs start at the left edge")
  h:assert_eq(full_keys[210].cell.col, 14.0, "vendor LEDs keep ascending LED order")
  local widest = 0
  for _, led in ipairs(full_channels[1].leds) do widest = math.max(widest, led.x) end
  h:assert(widest > 0.95 and widest <= 1, "full-size keys span the zone without leaving it")
  full_dev:clear()
  full_dev:queue_read(report(0x11, 0x01, 0x01, 0x51, {}))
  full_dev:apply({ mode = "static", color = { r = 9, g = 8, b = 7 } })
  local full_static = full_dev:writes()
  h:assert_eq(full_static[2].data[3], 0x02, "static colour is written through per-key lighting")
  h:assert_eq(full_static[#full_static].data[4], 0x71, "static colour ends with a per-key commit")

  local tkl_keys = key_by_led(discovered_keyboard_dev(
    { 0, 0, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0xfe, 0xff })
    :keyboard_layout_status())
  h:assert_eq(tkl_keys[79].cell.id, "up", "a keyboard without numpad LEDs uses the TKL template")
  h:assert_eq(tkl_keys[80], nil, "absent numpad LEDs produce no keys")
  h:assert_eq(tkl_keys[111].cell.col, 11.25, "TKL right-super keeps its bottom-row cell")
  h:assert_eq(tkl_keys[98].cell.id, "menu", "TKL menu key is placed explicitly")

  profile_management_tests(h, report)

  do
  local profiles = halod.require("lib.hidpp2.profiles")()
  local function tkl_keyboard()
    local ids = {}
    for id = 1, 111 do if id < 80 or id > 96 then ids[#ids + 1] = id end end
    return (profiles.discovered_keyboard(ids))
  end
  local gpro = tkl_keyboard()
  profiles.bind_gkeys_to_function_row(gpro, 12)
  for _, variant in ipairs({ gpro.ansi, gpro.iso }) do
    local bound = {}
    for _, mapping in ipairs(variant.keys) do
      if mapping.remap_cid then bound[mapping.key] = mapping.remap_cid end
    end
    for n = 1, 12 do
      h:assert_eq(bound["f" .. n], n, "F" .. n .. " selects G-key " .. n)
    end
    h:assert_eq(bound.escape, nil, "keys outside the function row stay unbound")
  end
  local partial = tkl_keyboard()
  profiles.bind_gkeys_to_function_row(partial, 3)
  for _, mapping in ipairs(partial.ansi.keys) do
    if mapping.key == "f4" then h:assert_eq(mapping.remap_cid, nil, "F4 is unbound past the G-key count") end
  end
  local function bound_f1(keyboard)
    for _, mapping in ipairs(keyboard.ansi.keys) do
      if mapping.key == "f1" then return mapping.remap_cid end
    end
  end
  local two_buttons = { { cid = 1 }, { cid = 2 } }
  h:assert_eq(bound_f1(profiles.keyboard_with_remap(tkl_keyboard(), "gkey", two_buttons)), 1,
    "a gkey backend binds the function row")
  h:assert_eq(bound_f1(profiles.keyboard_with_remap(tkl_keyboard(), "reprog", two_buttons)), nil,
    "other remap backends leave the keyboard alone")
  h:assert_eq(profiles.keyboard_with_remap(nil, "gkey", two_buttons), nil, "a mouse has no keyboard to bind")
  local function bound_key(keyboard, key)
    for _, mapping in ipairs(keyboard.ansi.keys) do
      if mapping.key == key then return mapping.remap_cid end
    end
  end
  local fkc_bound = profiles.keyboard_with_remap(tkl_keyboard(), "fkc", { { cid = 0x0122 }, { cid = 0x014c } })
  h:assert_eq(bound_key(fkc_bound, "a"), 0x0122, "a full-key-customization keyboard binds keys by control id")
  h:assert_eq(bound_key(fkc_bound, "escape"), 0x014c, "every documented standard key binds")
  h:assert_eq(bound_key(fkc_bound, "b"), nil, "keys without a listed control stay unbound")
  h:assert_eq(halod.require("lib.hidpp2.control_keys")[0x0177], "num7", "numpad control ids bind to numpad keys")
  h:assert_eq(halod.require("lib.hidpp2.controls")[0x0192], "G4", "G-key control ids are labelled")
  h:assert_eq(halod.require("lib.hidpp2.controls")[0x018c], "Left Start", "alt/start control ids are labelled")
  end
end
