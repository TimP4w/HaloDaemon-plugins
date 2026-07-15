-- SPDX-License-Identifier: GPL-2.0-or-later
-- Assemble the package-local protocol layers into the callback table exported
-- to HaloDaemon. Neither module can resolve outside this plugin's module index.
local hidpp1 = halod.require("lib.hidpp1")
local hidpp2 = halod.require("lib.hidpp2")

return hidpp2(hidpp1)
