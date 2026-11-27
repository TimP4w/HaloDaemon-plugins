-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: HaloDaemon
--
-- Philips Hue integration: controls lights through a local bridge over the
-- CLIP v2 API. The bridge address is the user-/discovery-supplied `host`; the
-- application key (and Entertainment client key, for later streaming) live in
-- secure config. The manifest declares its CA and certificate identity policy;
-- the host applies those generic TLS constraints.

local gamut=halod.require("lib.gamut")
local light_gamuts={}

local function authority(host)
  host = host or ""
  if host:sub(1, 1) ~= "[" and select(2, host:gsub(":", "")) >= 2 then
    return "[" .. host .. "]"
  end
  return host
end

local function base_for(config)
  return "https://" .. authority(config.host) .. ":" .. tostring(config.port or "443")
end

local function base()
  return base_for(halod.config)
end

local function discovered_address(addresses)
  -- The host scanner already orders these, but keep the plugin deterministic
  -- when fed discovery data by an older daemon. Never mistake the bridge id or
  -- mDNS hostname for a connect address.
  for _, address in ipairs(addresses or {}) do
    if address:match("^%d+%.%d+%.%d+%.%d+$") then return address end
  end
  for _, address in ipairs(addresses or {}) do
    if address:find(":", 1, true) then return address end
  end
  return nil
end

local function check_response(response)
  if response.status < 200 or response.status >= 300 then
    error("hue: request failed with HTTP " .. tostring(response.status))
  end
  local errors = response.json and response.json.errors or {}
  if #errors > 0 then
    error("hue: " .. tostring(errors[1].description or "bridge rejected the request"))
  end
  return response
end

local function clip(method, path, body)
  local headers = { ["hue-application-key"] = halod.config.app_key or "" }
  if body then headers["Content-Type"] = "application/json" end
  return check_response(halod.http:request({
    method = method,
    origin = base(),
    path = "/clip/v2/resource" .. path,
    headers = headers,
    body = body,
  }))
end

local function srgb_channel(value)
  value = value / 255
  if value <= 0.04045 then return value / 12.92 end
  return ((value + 0.055) / 1.055) ^ 2.4
end

local function rgb_to_xy(color)
  local r = srgb_channel(color.r or 0)
  local g = srgb_channel(color.g or 0)
  local b = srgb_channel(color.b or 0)
  local x = r * 0.664511 + g * 0.154324 + b * 0.162028
  local y = r * 0.283881 + g * 0.668433 + b * 0.047685
  local z = r * 0.000088 + g * 0.072310 + b * 0.986039
  local total = x + y + z
  if total == 0 then return 0, 0 end
  return x / total, y / total
end

local last_colors, next_color_writes = {}, {}

local function set_light_color(id, color)
  local key = string.format("%d:%d:%d", color.r or 0, color.g or 0, color.b or 0)
  local now = halod.monotonic_ms()
  if last_colors[id] == key or now < (next_color_writes[id] or 0) then return end
  local peak = math.max(color.r or 0, color.g or 0, color.b or 0)
  local body
  if peak == 0 then
    body = '{"on":{"on":false}}'
  else
    local x, y = rgb_to_xy(color)
    x,y=gamut.clip(x,y,light_gamuts[id])
    body = string.format(
      '{"on":{"on":true},"dimming":{"brightness":%.3f},"color":{"xy":{"x":%.6f,"y":%.6f}}}',
      math.max(1, peak / 255 * 100), x, y)
  end
  local response = clip("PUT", "/light/" .. id, body)
  if response.status < 200 or response.status >= 300 then
    error("hue: light update failed with status " .. tostring(response.status))
  end
  next_color_writes[id] = now + 100
  last_colors[id] = key
end

return {
  discover = function(context)
    local found = {}
    for _, service in ipairs(context.mdns or {}) do
      local address = discovered_address(service.addresses)
      if address then
        local bridge_id = service.txt and (service.txt.bridgeid or service.txt.bridgeId)
        found[#found + 1] = {
          id = bridge_id or service.id,
          name = bridge_id and ("Hue Bridge " .. bridge_id) or ("Hue Bridge at " .. address),
          values = { host = address, bridge_id = bridge_id or service.id },
        }
      end
    end
    return found
  end,

  pair = function(context)
    local host = context.config and context.config.host or ""
    local response = halod.http:request({
      method = "POST",
      origin = "https://" .. authority(host) .. ":" .. tostring((context.config and context.config.port) or "443"),
      path = "/api",
      headers = { ["Content-Type"] = "application/json" },
      body = '{"devicetype":"halod#desktop","generateclientkey":true}',
    })
    local app_key = response.body:match('"username"%s*:%s*"([^"]+)"')
    local client_key = response.body:match('"clientkey"%s*:%s*"([^"]+)"')
    if not app_key then
      return { ok = false, pending = true, reason = "Press the bridge link button, then try again." }
    end
    local values = { app_key = app_key }
    if client_key and client_key ~= "" then values.client_key = client_key end
    return { ok = true, values = values }
  end,

  validate = function(context)
    local config = context.config or {}
    if not config.host or not config.app_key then
      return { ok = false, reason = "The bridge address or application key is missing." }
    end
    local response = halod.http:request({
      method = "GET",
      origin = base_for(config),
      path = "/clip/v2/resource/bridge",
      headers = { ["hue-application-key"] = config.app_key },
    })
    local ok, err = pcall(check_response, response)
    return { ok = ok, reason = not ok and tostring(err) or nil }
  end,

  initialize = function(dev)
    if dev.match.key then
      return {
        ok = true,
        capabilities = { "lighting" },
        channels = { { id = "light", name = "Light", led_count = 1 } },
      }
    end
    -- Pairing and bridge enumeration perform the actual connectivity probes;
    -- the host root itself has no hardware state to initialize.
    return true
  end,

  enumerate_controllers = function(dev)
    if dev.match.key or not halod.config.app_key or halod.config.app_key == "" then return {} end
    local response = clip("GET", "/light")
    if response.status ~= 200 then
      error("hue: light list request failed with status " .. tostring(response.status))
    end
    local controllers = {}
    for _, light in ipairs((response.json and response.json.data) or {}) do
      -- Expose independently addressable color lights. Dimmable-only and
      -- color-temperature-only resources do not satisfy Halo's RGB contract.
      if light.id and light.color then
        light_gamuts[light.id]=light.color.gamut
        local metadata = light.metadata or {}
        controllers[#controllers + 1] = {
          index = #controllers,
          id = "hue_light_" .. light.id,
          key = light.id,
          name = metadata.name or ("Hue light " .. light.id),
          device_type = "led_strip",
          channels = { { id = "light", name = "Light", led_count = 1 } },
        }
      end
    end
    return controllers
  end,

  apply = function(dev, state)
    if not dev.match.key or state.mode ~= "static" or not state.color then return end
    set_light_color(dev.match.key, state.color)
  end,

  write_frame = function(dev, _zone_id, bytes)
    if not dev.match.key or #bytes < 3 then return end
    set_light_color(dev.match.key, { r = bytes[1], g = bytes[2], b = bytes[3] })
  end,
}
