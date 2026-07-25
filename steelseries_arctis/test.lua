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

  local function control_value(dev, kind, key, field)
    local wire = dev:serialize()
    for _, cap in ipairs(wire.capabilities or {}) do
      if cap.kind == kind then
        for _, control in ipairs(cap.data or {}) do
          if control.key == key then return control[field] end
        end
      end
    end
    return nil
  end

  -- Status reply 0x06 0xB0: headset battery raw 8 (→100%), power online.
  local status = packet({ [1] = 0x06, [2] = 0xB0, [7] = 8, [8] = 4, [16] = 0x08 })
  -- Settings reply 0x06 0x20: gain high, Focus preset (2), sidetone high.
  local settings = packet({ [1] = 0x06, [2] = 0x20, [5] = 0x02, [7] = 2, [19] = 3 })

  local dev = h:open({ reads = { status, settings } })

  h:assert(dev:initialize(), "initialize succeeds")
  local w = dev:writes()
  h:assert(contains(w, { 0x06, 0x49, 0x01 }), "sends the ChatMix display activate (init only)")
  h:assert(contains(w, { 0x06, 0xB0 }), "sends a status poll request")
  h:assert(contains(w, { 0x06, 0x20 }), "sends a settings poll request")
  local batteries = dev:get_batteries()
  h:assert_eq(batteries[2].status, "charging", "charging-slot battery reports charging")

  h:assert_eq(control_value(dev, "range", "volume", "read_only"), true, "station volume is read-only")
  h:assert_eq(control_value(dev, "range", "chatmix", "read_only"), true, "ChatMix is read-only")

  dev:clear()
  dev:set_range("mic_volume", 7)
  dev:set_range("mic_led_brightness", 0)
  w = dev:writes()
  h:assert(contains(w, { 0x06, 0x37, 7 }), "microphone volume uses its dedicated command")
  h:assert(contains(w, { 0x06, 0xBF, 0 }), "microphone LED supports fully off")

  dev:set_choice("sonar_eq", 1)
  dev:set_choice("wireless_mode", 1)
  dev:set_choice("auto_off", 4)
  dev:set_choice("screen_mode", 1)
  w = dev:writes()
  h:assert(contains(w, { 0x06, 0x8D, 1 }), "Sonar EQ command")
  h:assert(contains(w, { 0x06, 0xC3, 1 }), "wireless mode command")
  h:assert(contains(w, { 0x06, 0xC1, 4 }), "auto-off command")
  h:assert(contains(w, { 0x06, 0x89, 1 }), "screen mode command")

  -- Physical base-station changes arrive as dedicated 0x07 notifications and
  -- must update the same typed caches that back GUI controls.
  dev:queue_read({ 0x07, 0x37, 4 })       -- microphone volume
  dev:queue_read({ 0x07, 0xBF, 3 })       -- microphone LED = 30%
  dev:queue_read({ 0x07, 0x8D, 0 })       -- Sonar EQ off
  dev:queue_read({ 0x07, 0xC3, 0 })       -- maximum speed
  dev:queue_read({ 0x07, 0xC1, 6 })       -- 60 minutes
  dev:queue_read({ 0x07, 0x89, 0 })       -- detailed screen
  dev:queue_read({ 0x07, 0x25, 0x38 })    -- station volume floor (56 steps down)
  dev:queue_read({ 0x07, 0x45, 25, 100 }) -- ChatMix favors chat
  dev:poll_sensors()
  h:assert_eq(control_value(dev, "range", "mic_volume", "value"), 4, "mic dial updates GUI cache")
  h:assert_eq(control_value(dev, "range", "mic_led_brightness", "value"), 30, "LED dial updates GUI cache")
  h:assert_eq(control_value(dev, "choice", "sonar_eq", "selected"), 0, "Sonar EQ notification updates GUI cache")
  h:assert_eq(control_value(dev, "choice", "wireless_mode", "selected"), 0, "wireless notification updates GUI cache")
  h:assert_eq(control_value(dev, "choice", "auto_off", "selected"), 6, "timeout notification updates GUI cache")
  h:assert_eq(control_value(dev, "choice", "screen_mode", "selected"), 0, "screen notification updates GUI cache")
  h:assert_eq(control_value(dev, "range", "volume", "value"), 0, "volume dial updates GUI cache")
  h:assert_eq(control_value(dev, "range", "chatmix", "value"), -75, "ChatMix dial updates GUI cache")

  -- 0 attenuation steps is full volume, not silence.
  dev:queue_read({ 0x07, 0x25, 0x00 })
  dev:poll_sensors()
  h:assert_eq(control_value(dev, "range", "volume", "value"), 100, "no attenuation reads as full volume")
  dev:queue_read({ 0x07, 0x25, 0x1C })
  dev:poll_sensors()
  h:assert_eq(control_value(dev, "range", "volume", "value"), 50, "half the dial range reads as 50%")
end
