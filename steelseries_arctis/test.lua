-- Exercised via `halod plugin-test steelseries_arctis`. `initialize()` activates
-- the ChatMix display, then polls status + settings — we script one status and
-- one settings reply (indices are 1-based, so wire offset `o` is index `o + 1`).
--
-- The device also declares a 250 ms `poll`, whose background loop issues its own
-- `06 B0`/`06 20` status/settings requests that interleave with initialize's, so
-- assertions check for the presence of the init-specific writes rather than an
-- exact count/order.

return function(h)
  local function packet(overrides)
    local r = {}
    for i = 1, 64 do r[i] = 0 end
    for idx, val in pairs(overrides) do r[idx] = val end
    return r
  end

  local function contains(writes, wanted)
    for _, x in ipairs(writes) do
      if #x.data == #wanted then
        local same = true
        for i = 1, #wanted do
          if x.data[i] ~= wanted[i] then same = false break end
        end
        if same then return true end
      end
    end
    return false
  end

  -- Status reply 0x06 0xB0: headset battery raw 8 (→100%), power online.
  local status = packet({ [1] = 0x06, [2] = 0xB0, [7] = 8, [16] = 0x08 })
  -- Settings reply 0x06 0x20: gain high, Focus preset (2), sidetone high.
  local settings = packet({ [1] = 0x06, [2] = 0x20, [5] = 0x02, [7] = 2, [19] = 3 })

  local dev = h:open({ reads = { status, settings } })

  h:assert(dev:initialize(), "initialize succeeds")
  local w = dev:writes()
  h:assert(contains(w, { 0x06, 0x49, 0x01 }), "sends the ChatMix display activate (init only)")
  h:assert(contains(w, { 0x06, 0xB0 }), "sends a status poll request")
  h:assert(contains(w, { 0x06, 0x20 }), "sends a settings poll request")
end
