-- SPDX-License-Identifier: GPL-2.0-or-later
-- REPROG_CONTROLS control id -> keyboard key id (the names used by the
-- runtime keyboard layout), read from full-size keyboards' key positions:
-- `iso` holds the two keys only ISO boards have: the hash key next to Enter
-- (drawn as the backslash key) and the key between left shift and Z.

local keys = {
  [0x004c] = "print_screen", [0x004d] = "pause", [0x004e] = "scroll_lock", [0x004f] = "menu",
  [0x00eb] = "right", [0x00ec] = "left",
  [0x00ef] = "f2", [0x00f0] = "f3", [0x00f1] = "f4", [0x00f2] = "f5", [0x00f3] = "f6",
  [0x00f4] = "f7", [0x00f5] = "f8", [0x00f6] = "f1",
  [0x010b] = "backtick",
  [0x010c] = "tab", [0x010d] = "caps_lock", [0x010e] = "left_shift", [0x010f] = "left_ctrl",
  [0x0110] = "left_super", [0x0111] = "left_alt", [0x0112] = "right_alt", [0x0113] = "right_super",
  [0x0114] = "right_ctrl", [0x0115] = "right_shift", [0x0116] = "insert", [0x0117] = "delete",
  [0x0118] = "home", [0x0119] = "end", [0x011a] = "page_up", [0x011b] = "page_down",
  [0x011e] = "backslash",
  [0x0142] = "digit0", [0x0143] = "digit1", [0x0144] = "digit2", [0x0145] = "digit3",
  [0x0146] = "digit4", [0x0147] = "digit5", [0x0148] = "digit6", [0x0149] = "digit7",
  [0x014a] = "digit8", [0x014b] = "digit9",
  [0x014c] = "escape", [0x014d] = "f9", [0x014e] = "f10", [0x014f] = "f11", [0x0150] = "f12",
  [0x0151] = "up", [0x0152] = "down", [0x0153] = "equals", [0x0155] = "enter",
  [0x0156] = "backspace", [0x0158] = "minus", [0x015a] = "left_bracket",
  [0x015b] = "right_bracket", [0x015c] = "semicolon", [0x015d] = "quote", [0x015e] = "slash",
  [0x015f] = "period", [0x0160] = "comma", [0x0161] = "space",
  [0x016b] = "num_lock", [0x016c] = "num_div", [0x016d] = "num_mul", [0x016e] = "num_sub",
  [0x016f] = "num_add", [0x0170] = "num_enter", [0x0171] = "num1", [0x0172] = "num2",
  [0x0173] = "num3", [0x0174] = "num4", [0x0175] = "num5", [0x0176] = "num6", [0x0177] = "num7",
  [0x0178] = "num8", [0x0179] = "num9", [0x017a] = "num0", [0x017b] = "num_dot",
  [0x018b] = "left_alt", [0x018c] = "left_super", [0x018d] = "right_alt",
}
for i = 0, 25 do keys[0x0122 + i] = string.char(string.byte("a") + i) end

return { keys = keys, iso = { [0x0169] = "backslash", [0x016a] = "iso_extra" } }
