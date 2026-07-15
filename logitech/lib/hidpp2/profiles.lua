-- SPDX-License-Identifier: GPL-2.0-or-later
-- Device-specific profiles and physical keyboard layouts for HID++2.

return function(product_name)

local G502X_LED_ORDER = { 3, 4, 8, 7, 6, 5, 2, 1 }
local G502X_BUTTONS = {
  [1] = "G9", [2] = "G8", [3] = "G7", [9] = "Left Click",
  [10] = "Right Click", [11] = "Wheel Center", [12] = "G4",
  [13] = "Thumb Trigger", [14] = "G5", [15] = "Wheel Left", [16] = "Wheel Right",
}
local G502_HERO_BUTTONS = {
  [1] = "G9", [9] = "Left Click", [10] = "Right Click", [11] = "Wheel Center",
  [12] = "G4", [13] = "G5", [14] = "Thumb Trigger", [15] = "G7", [16] = "G8",
}

local function device_profile(dev)
  local pid, wpid = dev.match.pid, dev.match.wpid
  if pid == 0xc095 or wpid == 0x4099 then
    return { name = "Logitech G502 X Plus", device_type = "mouse", wireless = true,
      zone_name = "Lighting", topology = "linear",
      led_order = G502X_LED_ORDER, buttons = G502X_BUTTONS, native_effects = { "color_wave" },
      defaults = {
        { cid = 2, base = { type = "dpi_cycle", direction = "up" }, shifted = { type = "native" } },
        { cid = 3, base = { type = "dpi_cycle", direction = "down" }, shifted = { type = "native" } },
        { cid = 13, base = { type = "momentary_dpi", dpi = 400 }, shifted = { type = "native" } },
      } }
  elseif pid == 0xc08b then
    return { name = "Logitech G502 Hero", device_type = "mouse", buttons = G502_HERO_BUTTONS, native_effects = {},
      defaults = {
        { cid = 16, base = { type = "dpi_cycle", direction = "up" }, shifted = { type = "native" } },
        { cid = 15, base = { type = "dpi_cycle", direction = "down" }, shifted = { type = "native" } },
        { cid = 14, base = { type = "momentary_dpi", dpi = 400 }, shifted = { type = "native" } },
      } }
  elseif pid == 0xc352 or wpid == 0x40b0 then
    return { name = "Logitech G PRO X TKL", device_type = "keyboard", wireless = true,
      zone_name = "Keys", topology = "keyboard",
      native_effects = { "ripple" }, button_prefix = "G" }
  end
  return { name = product_name(pid, wpid), device_type = "other", native_effects = {} }
end

-- G PRO X TKL firmware LED id -> standard host key. Geometry for standard
-- keys comes from Halo's generic TKL templates; only Logitech-specific keys
-- carry explicit cells. This is the same map used by the former native driver.
local GPRO_TKL_KEYS = {
  {38,"escape"},{55,"f1"},{56,"f2"},{57,"f3"},{58,"f4"},{59,"f5"},{60,"f6"},
  {61,"f7"},{62,"f8"},{63,"f9"},{64,"f10"},{65,"f11"},{66,"f12"},
  {67,"print_screen"},{68,"scroll_lock"},{69,"pause"},
  {50,"backtick"},{27,"digit1"},{28,"digit2"},{29,"digit3"},{30,"digit4"},
  {31,"digit5"},{32,"digit6"},{33,"digit7"},{34,"digit8"},{35,"digit9"},
  {36,"digit0"},{42,"minus"},{43,"equals"},{39,"backspace"},
  {70,"insert"},{71,"home"},{72,"page_up"},
  {40,"tab"},{17,"q"},{23,"w"},{5,"e"},{18,"r"},{20,"t"},{25,"y"},
  {21,"u"},{9,"i"},{15,"o"},{16,"p"},{44,"left_bracket"},
  {45,"right_bracket"},{46,"backslash"},{73,"delete"},{74,"end"},
  {75,"page_down"},{37,"enter"},
  {54,"caps_lock"},{1,"a"},{19,"s"},{4,"d"},{6,"f"},{7,"g"},{8,"h"},
  {10,"j"},{11,"k"},{12,"l"},{48,"semicolon"},{49,"quote"},
  {105,"left_shift"},{97,"iso_extra"},{26,"z"},{24,"x"},{3,"c"},{22,"v"},
  {2,"b"},{14,"n"},{13,"m"},{51,"comma"},{52,"period"},{53,"slash"},
  {109,"right_shift"},{79,"up"},
  {104,"left_ctrl"},{107,"left_super"},{106,"left_alt"},{41,"space"},
  {110,"right_alt"},{108,"right_ctrl"},{77,"left"},{78,"down"},{76,"right"},
}

local GPRO_TKL_EXTRA_KEYS = {
  { led_id = 150, cell = { col = 5.0, row = -1.5 } },
  { led_id = 155, cell = { col = 11.0, row = -1.5 } },
  { led_id = 152, cell = { col = 12.0, row = -1.5 } },
  { led_id = 154, cell = { col = 13.0, row = -1.5 } },
  { led_id = 153, cell = { col = 14.0, row = -1.5 } },
  { led_id = 111, cell = { col = 11.25, row = 5.5 } },
  { led_id = 98, cell = { col = 12.25, row = 5.5 } },
}

local function gpro_tkl_variant(iso)
  local keys = {}
  for _, mapping in ipairs(GPRO_TKL_KEYS) do
    local key = mapping[2]
    if not (iso and key == "backslash") and not (not iso and key == "iso_extra") then
      keys[#keys + 1] = { led_id = mapping[1], key = key }
    end
  end
  for _, key in ipairs(GPRO_TKL_EXTRA_KEYS) do keys[#keys + 1] = key end
  if iso then
    -- Logitech firmware zone 47 replaces the standard ISO home-row backslash.
    keys[#keys + 1] = { led_id = 47, cell = { col = 12.75, row = 3.5 } }
  end
  return { base = iso and "tkl_iso" or "tkl", keys = keys }
end

local function gpro_tkl_keyboard(layout)
  return {
    ansi = gpro_tkl_variant(false),
    iso = gpro_tkl_variant(true),
    detected_language = layout or "unknown",
    languages = { "u_s", "c_h", "i_t", "d_e", "f_r", "u_k" },
  }
end

return {
  device_profile = device_profile,
  gpro_tkl_keyboard = gpro_tkl_keyboard,
}
end
