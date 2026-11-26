-- SPDX-License-Identifier: GPL-2.0-or-later
-- Device-specific profiles and physical keyboard layouts for HID++2.

return function()

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
    return {
      led_order = G502X_LED_ORDER, buttons = G502X_BUTTONS, signature_name = "Pulsar Point",
      defaults = {
        { cid = 2, base = { type = "dpi_cycle", direction = "up" }, shifted = { type = "native" } },
        { cid = 3, base = { type = "dpi_cycle", direction = "down" }, shifted = { type = "native" } },
        { cid = 13, base = { type = "momentary_dpi", dpi = 400 }, shifted = { type = "native" } },
      } }
  elseif pid == 0xc08b then
    return { buttons = G502_HERO_BUTTONS,
      defaults = {
        { cid = 16, base = { type = "dpi_cycle", direction = "up" }, shifted = { type = "native" } },
        { cid = 15, base = { type = "dpi_cycle", direction = "down" }, shifted = { type = "native" } },
        { cid = 14, base = { type = "momentary_dpi", dpi = 400 }, shifted = { type = "native" } },
      } }
  elseif pid == 0xc352 or wpid == 0x40b0 then
    return { gkeys_on_function_row = true,
      extra_key_cells = {
        [150] = { col = 5.0, row = -1.5 }, [155] = { col = 11.0, row = -1.5 },
        [152] = { col = 12.0, row = -1.5 }, [154] = { col = 13.0, row = -1.5 },
        [153] = { col = 14.0, row = -1.5 },
      } }
  elseif pid == 0x0a78 then
    return {
      zone_names = { [0] = "Left Secondary", [1] = "Right Secondary", [2] = "Left Primary", [3] = "Right Primary" },
      bass_key = "subwoofer_volume", bass_label = "Subwoofer Volume",
      brightness_levels = { 0, 25, 50, 100 },
      eq_presets = {
        { id = "flat", label = "Flat", bands = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
        { id = "fps", label = "FPS", bands = { 0, 0, -6, -5, -3, -2, -3, -3, -5, -6 } },
        { id = "moba", label = "MOBA", bands = { 0, -10, -11, 0, -2, -5, -3, -17, -3, 0 } },
        { id = "bass_boost", label = "Bass Boost", bands = { 0, 0, 0, 0, 0, -3, -4, -5, -6, -6 } },
        { id = "cinematic", label = "Cinematic", bands = { -3, -4, -5, -6, -6, -5, -6, 0, 0, 0 } },
        { id = "communications", label = "Communications", bands = { 0, -1, -1, 2, 4, 4, 4, 4, 2, 1 } },
      } }
  end
  return {}
end

local USAGE_ORDER_KEYS = {
  "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
  "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
  "digit1", "digit2", "digit3", "digit4", "digit5", "digit6", "digit7", "digit8",
  "digit9", "digit0", "enter", "escape", "backspace", "tab", "space", "minus",
  "equals", "left_bracket", "right_bracket", "backslash", false, "semicolon",
  "quote", "backtick", "comma", "period", "slash", "caps_lock",
  "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
  "print_screen", "scroll_lock", "pause", "insert", "home", "page_up", "delete",
  "end", "page_down", "right", "left", "down", "up",
  "num_lock", "num_div", "num_mul", "num_sub", "num_add", "num_enter",
  "num1", "num2", "num3", "num4", "num5", "num6", "num7", "num8", "num9",
  "num0", "num_dot", "iso_extra", "menu",
}
local MODIFIER_KEYS = {
  [104] = "left_ctrl", [105] = "left_shift", [106] = "left_alt", [107] = "left_super",
  [108] = "right_ctrl", [109] = "right_shift", [110] = "right_alt", [111] = "right_super",
}
local ISO_HASH_LED, LAST_USAGE_LED = 47, 111
local FIRST_NUMPAD_LED, LAST_NUMPAD_LED = 80, 96
local TKL_BOTTOM_ROW_CELLS = {
  right_super = { col = 11.25, row = 5.5, w = 1.25 },
  menu = { col = 12.5, row = 5.5, w = 1.25 },
}

local function usage_key(led_id)
  return USAGE_ORDER_KEYS[led_id] or MODIFIER_KEYS[led_id] or nil
end

local function discovered_variant(led_ids, iso, full_size, extra_cells)
  local keys, next_extra_col = {}, 0
  for _, id in ipairs(led_ids) do
    local key = usage_key(id)
    if iso and id == ISO_HASH_LED then key = "backslash"
    elseif iso and key == "backslash" then key = nil
    elseif not iso and key == "iso_extra" then key = nil
    elseif not full_size and id >= FIRST_NUMPAD_LED and id <= LAST_NUMPAD_LED then key = nil end
    if key then
      keys[#keys + 1] = { led_id = id, key = key,
        cell = not full_size and TKL_BOTTOM_ROW_CELLS[key] or nil }
    elseif id > LAST_USAGE_LED then
      local cell = extra_cells[id]
      if not cell then
        cell = { col = next_extra_col, row = -1.5 }
        next_extra_col = next_extra_col + 1
      end
      keys[#keys + 1] = { led_id = id, cell = cell }
    end
  end
  local base = full_size and "full_size" or "tkl"
  return { base = iso and (base .. "_iso") or base, keys = keys }
end

local function discovered_keyboard(led_ids, profile)
  profile = profile or {}
  local present, full_size = {}, false
  for _, id in ipairs(led_ids) do
    present[id] = true
    if id >= FIRST_NUMPAD_LED and id <= LAST_NUMPAD_LED then full_size = true end
  end
  for id = 1, 26 do if not present[id] then return nil end end
  local extra_cells = profile.extra_key_cells or {}
  return {
    ansi = discovered_variant(led_ids, false, full_size, extra_cells),
    iso = discovered_variant(led_ids, true, full_size, extra_cells),
    detected_language = "unknown",
    languages = { "u_s", "c_h", "i_t", "d_e", "f_r", "u_k" },
  }, full_size and "full_size" or "t_k_l"
end

local function bind_gkeys_to_function_row(keyboard, gkey_count)
  for _, variant in pairs({ keyboard.ansi, keyboard.iso }) do
    for _, mapping in ipairs(variant.keys) do
      local n = mapping.key and tonumber(mapping.key:match("^f(%d+)$"))
      if n and n <= gkey_count then mapping.remap_cid = n end
    end
  end
end

local function keyboard_with_remap(keyboard, remap_backend, buttons)
  if keyboard and remap_backend == "gkey" then
    bind_gkeys_to_function_row(keyboard, #buttons)
  end
  return keyboard
end

return {
  device_profile = device_profile,
  bind_gkeys_to_function_row = bind_gkeys_to_function_row,
  keyboard_with_remap = keyboard_with_remap,
  discovered_keyboard = discovered_keyboard,
}
end
