-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: HaloDaemon
--
-- Nanoleaf integration: HTTP OpenAPI for setup/state, UDP v2 external control
-- for per-panel streaming (HTTP effect writes as fallback). See docs/protocol.md.

local function http_origin(host, port)
  return "http://" .. (host or "") .. ":" .. (port or "")
end

local function base()
  return http_origin(halod.config.host, halod.config.http_port)
end

local function api(suffix)
  -- An unset token yields an unauthenticated path the controller rejects.
  return "/api/v1/" .. (halod.config.token or "") .. suffix
end

local function get(path)
  return halod.http:request({ method = "GET", origin = base(), path = path })
end

local function rgb_to_hsv(color)
  local r, g, b = color.r / 255, color.g / 255, color.b / 255
  local hi, lo = math.max(r, g, b), math.min(r, g, b)
  local delta = hi - lo
  local hue = 0
  if delta ~= 0 then
    if hi == r then hue = 60 * (((g - b) / delta) % 6)
    elseif hi == g then hue = 60 * (((b - r) / delta) + 2)
    else hue = 60 * (((r - g) / delta) + 4) end
  end
  local saturation = hi == 0 and 0 or math.floor((delta / hi) * 100 + 0.5)
  return math.floor(hue + 0.5), saturation, math.floor(hi * 100 + 0.5)
end

local last_color, next_color_write_ms = nil, 0

local function set_color(color)
  local now = halod.monotonic_ms()
  local key = string.format("%d:%d:%d", color.r, color.g, color.b)
  if key == last_color or now < next_color_write_ms then return end
  next_color_write_ms = now + 100
  local hue, saturation, brightness = rgb_to_hsv(color)
  local response = halod.http:request({
    method = "PUT", origin = base(), path = api("/state"),
    headers = { ["Content-Type"] = "application/json" },
    body = string.format('{"on":{"value":true},"hue":{"value":%d},"sat":{"value":%d},"brightness":{"value":%d}}', hue, saturation, brightness),
  })
  if response.status >= 200 and response.status < 300 then last_color = key end
end

-- Firmware panel ids in declared LED order; empty on the single-LED fallback.
local panel_ids = {}
local last_frame, next_frame_write_ms = nil, 0

-- Nanoleaf panel y increases upward; flip it so geometry matches the UI axis.
local function panel_topology(layout)
  local panels = type(layout) == "table" and layout.positionData
  if type(panels) ~= "table" or #panels == 0 then return nil end
  local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(panels) do
    if type(p.panelId) ~= "number" then return nil end
    local x, y = p.x or 0, p.y or 0
    min_x, max_x = math.min(min_x, x), math.max(max_x, x)
    min_y, max_y = math.min(min_y, y), math.max(max_y, y)
  end
  local span_x, span_y = max_x - min_x, max_y - min_y
  local leds, ids = {}, {}
  for i, p in ipairs(panels) do
    local nx = span_x > 0 and ((p.x or 0) - min_x) / span_x or 0.5
    local ny = span_y > 0 and (max_y - (p.y or 0)) / span_y or 0.5
    leds[i] = { id = i - 1, x = nx, y = ny }
    ids[i] = p.panelId
  end
  return leds, ids
end

local function frame_key(colors)
  local parts = {}
  for i = 1, #panel_ids do
    local c = colors[i] or { r = 0, g = 0, b = 0 }
    parts[i] = string.format("%d:%d:%d", c.r or 0, c.g or 0, c.b or 0)
  end
  return table.concat(parts, "|")
end

-- HTTP fallback when UDP external control is unavailable.
local function push_http_static(colors)
  local anim = { tostring(#panel_ids) }
  for i = 1, #panel_ids do
    local c = colors[i] or { r = 0, g = 0, b = 0 }
    anim[#anim + 1] = string.format("%d 1 %d %d %d 0 1", panel_ids[i], c.r or 0, c.g or 0, c.b or 0)
  end
  halod.http:request({
    method = "PUT", origin = base(), path = api("/effects"),
    headers = { ["Content-Type"] = "application/json" },
    body = string.format(
      '{"write":{"command":"display","animType":"static","animData":"%s","loop":false,"palette":[]}}',
      table.concat(anim, " ")),
  })
end

-- Arm v2 external control once so the controller consumes UDP stream datagrams.
local ext_control_ready = false
local next_ext_control_ms = 0
local function ensure_ext_control()
  if ext_control_ready then return true end
  local now = halod.monotonic_ms()
  if now < next_ext_control_ms then return false end
  next_ext_control_ms = now + 1000
  local r = halod.http:request({
    method = "PUT", origin = base(), path = api("/effects"),
    headers = { ["Content-Type"] = "application/json" },
    body = '{"write":{"command":"display","animType":"extControl","extControlVersion":"v2"}}',
  })
  ext_control_ready = r.status >= 200 and r.status < 300
  return ext_control_ready
end

-- v2 stream datagram; see docs/protocol.md.
local function panel_datagram(colors)
  local parts = { string.pack(">I2", #panel_ids) }
  for i = 1, #panel_ids do
    local c = colors[i] or { r = 0, g = 0, b = 0 }
    parts[i + 1] = string.pack(">I2BBBBI2", panel_ids[i], c.r or 0, c.g or 0, c.b or 0, 0, 1)
  end
  return table.concat(parts)
end

-- Returns false when UDP or ext-control is unavailable, so callers fall back.
local function push_udp(colors)
  if not halod.udp or not ensure_ext_control() then return false end
  return pcall(function() halod.udp:send({ bytes = panel_datagram(colors) }) end)
end

-- One-shot apply: UDP, else HTTP.
local function push_panels(colors)
  if not push_udp(colors) then push_http_static(colors) end
end

-- Engine frames: UDP streams every distinct frame; HTTP fallback is rate-limited.
local function stream_panels(colors)
  local key = frame_key(colors)
  if key == last_frame then return end
  if halod.udp and push_udp(colors) then last_frame = key; return end
  local now = halod.monotonic_ms()
  if now < next_frame_write_ms then return end
  next_frame_write_ms = now + 100
  push_http_static(colors)
  last_frame = key
end

return {
  discover = function(context)
    local found = {}
    for _, service in ipairs(context.mdns or {}) do
      local address = service.addresses and service.addresses[1]
      if address then
        found[#found + 1] = {
          id = service.id,
          name = service.name or ("Nanoleaf at " .. address),
          values = { host = address, http_port = tostring(service.port or 16021) },
        }
      end
    end
    for _, service in ipairs(context.ssdp or {}) do
      local authority = (service.location or ""):match("^https?://([^/]+)")
      if authority then
        found[#found + 1] = {
          id = service.id,
          name = "Nanoleaf at " .. authority,
          values = { host = authority:match("^([^:]+)"), http_port = authority:match(":(%d+)") or "16021" },
        }
      end
    end
    return found
  end,

  pair = function(context)
    local config = context.config or {}
    local response = halod.http:request({
      method = "POST", origin = http_origin(config.host, config.http_port), path = "/api/v1/new",
    })
    if response.status < 200 or response.status >= 300 then
      return { ok = false, pending = true, reason = "The controller is not in pairing mode yet." }
    end
    local token = response.body:match('"auth_token"%s*:%s*"([^"]+)"')
    if not token or token == "" then
      return { ok = false, reason = "The controller returned no authentication token." }
    end
    return { ok = true, values = { token = token } }
  end,

  validate = function(context)
    local config = context.config or {}
    if not config.host or config.host == "" or not config.token or config.token == "" then
      return { ok = false, reason = "The device address or pairing token is missing." }
    end
    local response = halod.http:request({
      method = "GET",
      origin = http_origin(config.host, config.http_port),
      path = "/api/v1/" .. config.token .. "/",
    })
    if response.status ~= 200 then
      return { ok = false, reason = "Nanoleaf validation returned HTTP " .. tostring(response.status) }
    end
    return { ok = true }
  end,

  initialize = function(_dev)
    if _dev.match.index ~= nil then
      local leds, ids
      if halod.config.token and halod.config.token ~= "" then
        local info = get(api("/"))
        if info.status ~= 200 then
          error("nanoleaf: controller info request failed with status " .. tostring(info.status))
        end
        if info.status == 200 and info.json and info.json.panelLayout then
          leds, ids = panel_topology(info.json.panelLayout.layout)
        end
      end
      if leds then
        panel_ids = ids
        return {
          ok = true, capabilities = { "lighting" },
          channels = { { id = "panels", name = "Panels", topology = "grid", led_count = #leds, leds = leds } },
        }
      end
      -- No layout reported: one logical LED via the global /state path.
      panel_ids = {}
      return {
        ok = true, capabilities = { "lighting" },
        channels = { { id = "all", name = "All panels", led_count = 1 } },
      }
    end
    -- Pairing is host-owned. Stay idle until the Pair action stores a token,
    -- rather than treating the normal unauthenticated API response as a
    -- connection failure.
    if not halod.config.token or halod.config.token == "" then
      return true
    end
    local info = get(api("/"))
    if info.status ~= 200 then
      error("nanoleaf: controller info request failed with status " .. tostring(info.status))
    end
    -- Put the controller into a known state (on) so later frames take effect.
    halod.http:request({
      method = "PUT",
      origin = base(),
      path = api("/state"),
      headers = { ["Content-Type"] = "application/json" },
      body = '{"on":{"value":true}}',
    })
    return true
  end,

  enumerate_controllers = function(_dev)
    if not halod.config.token or halod.config.token == "" then
      return {}
    end
    -- A Nanoleaf controller is one physical lighting endpoint whose panels are
    -- individual LEDs of a single child device, not independent host devices.
    return {
      { index = 0, id = "nanoleaf", name = "Nanoleaf", device_type = "led_strip" },
    }
  end,

  apply = function(dev, state)
    if dev.match.index == nil then return end
    if #panel_ids == 0 then
      if state.mode == "static" and state.color then set_color(state.color) end
      return
    end
    if state.mode == "static" and state.color then
      local fill = {}
      for i = 1, #panel_ids do fill[i] = state.color end
      push_panels(fill)
    elseif state.mode == "per_led" then
      local map = (state.channels or {}).panels or {}
      local colors = {}
      for i = 0, #panel_ids - 1 do colors[i + 1] = map[tostring(i)] or { r = 0, g = 0, b = 0 } end
      push_panels(colors)
    end
  end,

  write_frame = function(dev, _zone_id, bytes)
    if dev.match.index == nil then return end
    local colors = {}
    for i = 1, #bytes, 3 do colors[#colors + 1] = { r = bytes[i] or 0, g = bytes[i + 1] or 0, b = bytes[i + 2] or 0 } end
    if #panel_ids > 0 then
      stream_panels(colors)
    elseif colors[1] then
      set_color(colors[1])
    end
  end,
}
