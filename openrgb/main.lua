-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: Timucin Besken <beskent@gmail.com>
--
-- OpenRGB SDK network client — an integration plugin (no `match`, no hardware
-- bus). Connects to an OpenRGB server (default 127.0.0.1:6742) over TCP and
-- exposes each of its RGB controllers as a top-level HaloDaemon device.
--
-- One worker (VM + connection) multiplexes *every* controller: the root
-- performs the protocol handshake and enumeration, and each controller's frames are
-- routed through the ordinary capability callbacks; each child's persistent
-- `dev.match.index` contains its enumeration route. Keeping one connection avoids the
-- connect-storm that crashes the server when a client opens one socket per
-- controller, and keeps all protocol reads serialized on one connection.
--
-- Protocol: OpenRGB's published network wire format (see its
-- RGBController::GetDeviceDescriptionData/GetModeDescriptionData/
-- GetZoneDescriptionData and NetworkServer.cpp). This client speaks protocol
-- protocol version 3, deliberately negotiated for compatibility with
-- released OpenRGB servers. Its replies use controller indices and do not
-- carry per-request ACK packets.
--
-- Scope: enumerate controllers/channels and drive them via Direct/custom mode
-- (`SetCustomMode` + `UpdateZoneLEDs`). Mode switching, profiles and
-- plugin-to-plugin messages are out of scope.

local PKT_REQUEST_CONTROLLER_COUNT = 0
local PKT_REQUEST_CONTROLLER_DATA = 1
local PKT_REQUEST_PROTOCOL_VERSION = 40
local PKT_SET_CLIENT_NAME = 50
local PKT_RGBCONTROLLER_UPDATELEDS = 1050
local PKT_RGBCONTROLLER_SETCUSTOMMODE = 1100

-- Version 3 is supported by released OpenRGB servers and has a stable schema.
-- Version 6 is still unreleased on many installations; requesting it and then
-- waiting for its ACK semantics makes a successful connection time out on
-- older servers after they have already accepted SET_CLIENT_NAME.
local CLIENT_PROTOCOL_VERSION = 3
local MAX_CONTROLLERS = 256
local MAX_MODES = 256
local MAX_ZONES = 256
local MAX_ZONE_LEDS = 4096
local MAX_CONTROLLER_LEDS = 0xFFFF
local MAX_MODE_COLORS = 4096

-- Enumeration index → its channels ({ id = <zone index string>, led_count = n }).
-- The root and routed controller callbacks share one worker, so child
-- initialization can publish the topology discovered during enumeration.
local controller_zones = {}
-- Enumeration index → whether `SetCustomMode` was already sent this connection.
local custom_mode_sent = {}
-- Enumeration index → complete controller colour buffer. Controller workers
-- populate this lazily from their injected zone descriptors.
local controller_colors = {}

local BLACK = { r = 0, g = 0, b = 0 }

-- ── wire framing ──────────────────────────────────────────────────────────

local function send_packet(dev, dev_id, packet_id, payload)
  payload = payload or ""
  local header = string.pack("<c4I4I4I4", "ORGB", dev_id, packet_id, #payload)
  dev.transport:write(header .. payload)
end

-- Reads the next reply header, returning (dev_id, packet_id, payload_size).
local function recv_header(dev)
  local magic = dev.transport:read(4)
  if magic ~= "ORGB" then
    error("openrgb: bad magic in reply header: " .. tostring(magic))
  end
  return string.unpack("<I4I4I4", dev.transport:read(12))
end

-- Read the one reply packet expected for a protocol-v3 request.
local function recv_payload(dev, want_id)
  local _, pkt_id, size = recv_header(dev)
  if pkt_id ~= want_id then
    error("openrgb: unexpected reply " .. pkt_id .. ", wanted " .. want_id)
  end
  return (size > 0) and dev.transport:read(size) or ""
end

-- Several client->server payloads repeat their own byte length as a leading
-- u32 (equal to the packet header's size field). `rest` is everything after it.
local function with_data_size(rest)
  return string.pack("<I4", 4 + #rest) .. rest
end

-- ── binary readers over an already-received payload string (1-based pos) ──

local function read_u16(data, pos)
  return string.unpack("<I2", data, pos)
end

local function read_u32(data, pos)
  return string.unpack("<I4", data, pos)
end

local function check_count(what, value, limit)
  if value > limit then
    error(string.format("openrgb: %s count %d exceeds limit %d", what, value, limit))
  end
  return value
end

-- Server strings are length-prefixed (u16), the length including a trailing
-- '\0'; exactly `len` bytes are consumed regardless of contents.
local function read_str(data, pos)
  local len, p = read_u16(data, pos)
  if len == 0 then
    return "", p
  end
  local value = data:sub(p, p + len - 1)
  if value:sub(-1) == "\0" then
    value = value:sub(1, -2)
  end
  return value, p + len
end

-- Skip one ModeDescription at protocol v3: name, then 12 u32 fields (`value`
-- is present below v6; brightness_min/max/brightness are present at v3), then a
-- length-prefixed colour array.
local function skip_mode(data, pos)
  local _, p = read_str(data, pos)
  p = p + 4 * 12
  local num_colors
  num_colors, p = read_u16(data, p)
  check_count("mode color", num_colors, MAX_MODE_COLORS)
  return p + num_colors * 4
end

-- Skip a matrix-map block: [size u16][size bytes]. `size` is always >= 8 — the
-- height+width u32s are emitted even for an empty 0x0 matrix.
local function skip_matrix(data, pos)
  local size
  size, pos = read_u16(data, pos)
  return pos + size
end

-- Read one ZoneDescription at v3. `id` is the zone's 0-based ordinal as a string
-- (what `UpdateZoneLEDs` addresses); everything past `leds_count` is walked only
-- to advance `pos` to the next zone.
local function read_zone(data, pos, zero_based_index)
  local name, p = read_str(data, pos)
  p = p + 4 -- type
  p = p + 4 -- leds_min
  p = p + 4 -- leds_max
  local leds_count
  leds_count, p = read_u32(data, p)
  check_count("zone LED", leds_count, MAX_ZONE_LEDS)
  p = skip_matrix(data, p) -- zone matrix (unconditional)

  local zone = {
    id = tostring(zero_based_index),
    name = (name ~= "" and name) or ("Zone " .. (zero_based_index + 1)),
    topology = "linear",
    led_count = leds_count,
  }
  return zone, p
end

local function pack_colors(colors)
  local parts = {}
  for i, c in ipairs(colors) do
    parts[i] = string.char(c.r, c.g, c.b, 0)
  end
  return table.concat(parts)
end

-- Put the controller into Direct/Custom mode exactly once per connection, so
-- per-LED writes land on writable LEDs.
local function ensure_custom_mode(dev, index)
  if not custom_mode_sent[index] then
    send_packet(dev, index, PKT_RGBCONTROLLER_SETCUSTOMMODE)
    custom_mode_sent[index] = true
  end
end

-- Normalize enumeration channels and host-provided RgbZone descriptors:
-- enumeration channels carry led_count, while RgbZone carries a leds array.
local function zones_for(dev, index)
  local channels = controller_zones[index] or dev.channels or {}
  local normalized = {}
  for i, zone in ipairs(channels) do
    normalized[i] = {
      id = zone.id,
      led_count = zone.led_count or #(zone.leds or {}),
    }
  end
  return normalized
end

local function controller_buffer(dev, index)
  local channels = zones_for(dev, index)
  local cached = controller_colors[index]
  if not cached then
    cached = {}
    for _, zone in ipairs(channels) do
      cached[zone.id] = string.rep("\0\0\0\0", zone.led_count)
    end
    controller_colors[index] = cached
  end
  return channels, cached
end

local function send_controller(dev, index)
  local channels, cached = controller_buffer(dev, index)
  local packed = {}
  local color_count = 0
  for i, zone in ipairs(channels) do
    packed[i] = cached[zone.id]
    color_count = color_count + zone.led_count
  end
  local rest = string.pack("<I2", color_count) .. table.concat(packed)
  send_packet(dev, index, PKT_RGBCONTROLLER_UPDATELEDS, with_data_size(rest))
end

local function set_zone_colors(dev, index, zone_id, colors)
  local _, cached = controller_buffer(dev, index)
  cached[tostring(zone_id)] = pack_colors(colors)
end

return {
  initialize = function(dev)
    if dev.match.index ~= nil then
      return {
        ok = true,
        capabilities = { "lighting" },
        channels = controller_zones[dev.match.index] or {},
      }
    end
    -- SET_CLIENT_NAME has no response. Version negotiation returns exactly
    -- one REQUEST_PROTOCOL_VERSION response on released servers.
    send_packet(dev, 0, PKT_SET_CLIENT_NAME, "HaloDaemon\0")
    send_packet(dev, 0, PKT_REQUEST_PROTOCOL_VERSION, string.pack("<I4", CLIENT_PROTOCOL_VERSION))
    local version = read_u32(recv_payload(dev, PKT_REQUEST_PROTOCOL_VERSION), 1)
    if version < CLIENT_PROTOCOL_VERSION then
      error("openrgb: server protocol " .. version .. " is older than required version " .. CLIENT_PROTOCOL_VERSION)
    end
    return true
  end,

  enumerate_controllers = function(dev)
    send_packet(dev, 0, PKT_REQUEST_CONTROLLER_COUNT)
    local count = read_u32(recv_payload(dev, PKT_REQUEST_CONTROLLER_COUNT), 1)
    check_count("controller", count, MAX_CONTROLLERS)

    controller_zones = {}
    custom_mode_sent = {}
    controller_colors = {}
    local controllers = {}
    for index = 0, count - 1 do
      send_packet(dev, index, PKT_REQUEST_CONTROLLER_DATA, string.pack("<I4", CLIENT_PROTOCOL_VERSION))
      local data = recv_payload(dev, PKT_REQUEST_CONTROLLER_DATA)

      -- Leading duplicate reply_size (u32), then DeviceDescription.
      local pos = 5
      pos = pos + 4 -- type
      local name
      name, pos = read_str(data, pos)
      local _vendor
      _vendor, pos = read_str(data, pos)
      local _description
      _description, pos = read_str(data, pos)
      local _version
      _version, pos = read_str(data, pos)
      local _serial
      _serial, pos = read_str(data, pos)
      local _location
      _location, pos = read_str(data, pos)

      local num_modes
      num_modes, pos = read_u16(data, pos)
      check_count("mode", num_modes, MAX_MODES)
      pos = pos + 4 -- active_mode
      for _ = 1, num_modes do
        pos = skip_mode(data, pos)
      end

      local num_zones
      num_zones, pos = read_u16(data, pos)
      check_count("zone", num_zones, MAX_ZONES)
      local channels = {}
      local total_leds = 0
      for z = 1, num_zones do
        channels[z], pos = read_zone(data, pos, z - 1)
        total_leds = total_leds + channels[z].led_count
        check_count("controller LED", total_leds, MAX_CONTROLLER_LEDS)
      end
      -- LEDs/colours follow but aren't needed; the
      -- whole message was already consumed via the packet size.

      controller_zones[index] = channels
      controllers[#controllers + 1] = {
        index = index,
        name = (name ~= "" and name) or ("Controller " .. index),
        serial = (_serial ~= "" and _serial) or nil,
        location = (_location ~= "" and _location) or nil,
        channels = channels,
      }
    end
    return controllers
  end,

  -- One worker owns every controller. Each routed child has a persistent dev
  -- table whose match index is the enumeration route.
  write_frame = function(dev, zone_id, bytes)
  local colors = {}
  for i = 1, #bytes, 3 do colors[#colors + 1] = { r = bytes[i] or 0, g = bytes[i + 1] or 0, b = bytes[i + 2] or 0 } end
    local index = assert(dev.match.index, "OpenRGB controller route missing")
    ensure_custom_mode(dev, index)
    set_zone_colors(dev, index, zone_id, colors)
    send_controller(dev, index)
  end,

  apply = function(dev, state)
    local index = assert(dev.match.index, "OpenRGB controller route missing")
    local channels = zones_for(dev, index)
    if not channels then
      return
    end

    if state.mode == "static" then
      local color = state.color
      if not color then
        return
      end
      ensure_custom_mode(dev, index)
      local _, cached = controller_buffer(dev, index)
      for _, zone in ipairs(channels) do
        local colors = {}
        for i = 1, zone.led_count do
          colors[i] = color
        end
        cached[zone.id] = pack_colors(colors)
      end
      send_controller(dev, index)
    elseif state.mode == "per_led" then
      local zmap = state.channels
      if not zmap then
        return
      end
      ensure_custom_mode(dev, index)
      local _, cached = controller_buffer(dev, index)
      for _, zone in ipairs(channels) do
        -- Sparse map keyed by the LED's 0-based id; unpainted LEDs fall back to
        -- black, matching `per_led_frame` on the native-driver side.
        local led_map = zmap[zone.id]
        local colors = {}
        for i = 1, zone.led_count do
          colors[i] = (led_map and led_map[tostring(i - 1)]) or BLACK
        end
        cached[zone.id] = pack_colors(colors)
      end
      send_controller(dev, index)
    end
  end,
}
