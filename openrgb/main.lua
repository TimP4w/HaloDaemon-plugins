-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: Timucin Besken <beskent@gmail.com>
--
-- OpenRGB SDK network client — an integration plugin (no `match`, no hardware
-- bus). Connects to an OpenRGB server (default 127.0.0.1:6742) over TCP and
-- exposes each of its RGB controllers as a top-level HaloDaemon device.
--
-- One worker (VM + connection) multiplexes *every* controller: `initialize`
-- and `enumerate_controllers` run once on it, and each controller's frames are
-- routed back to it via `write_controller_frame`/`apply_controller` with the
-- controller's enumeration `index`. Keeping a single connection avoids the
-- connect-storm that crashes the server when a client opens one socket per
-- controller, and lets one reader safely consume ACKs.
--
-- Protocol: OpenRGB's published network wire format (see its
-- RGBController::GetDeviceDescriptionData/GetModeDescriptionData/
-- GetZoneDescriptionData and NetworkServer.cpp). This client speaks protocol
-- version 6, chosen for its per-packet ACK: the server ACKs a queued
-- `UpdateZoneLEDs` only once the controller's own worker thread has actually
-- applied the frame to hardware. Blocking on that ACK before returning turns
-- each write into a real completion, so a controller can never outrun its
-- device — no unbounded server-side backlog, no lag, and sibling controllers
-- (e.g. the sticks of a DRAM kit) stay in phase instead of drifting.
--
-- Version 6 also changes the wire in ways this parser must honour: controllers
-- are addressed by an opaque *id* (from the controller-count reply) rather than
-- their index; mode/LED descriptions drop their `value` field; and zone
-- descriptions gain segments, flags and nested zone-modes.
--
-- Scope: enumerate controllers/zones and drive them via Direct/custom mode
-- (`SetCustomMode` + `UpdateZoneLEDs`). Mode switching, profiles and
-- plugin-to-plugin messages are out of scope.

local PKT_REQUEST_CONTROLLER_COUNT = 0
local PKT_REQUEST_CONTROLLER_DATA = 1
local PKT_ACK = 10
local PKT_REQUEST_PROTOCOL_VERSION = 40
local PKT_SET_CLIENT_NAME = 50
local PKT_RGBCONTROLLER_UPDATEZONELEDS = 1051
local PKT_RGBCONTROLLER_SETCUSTOMMODE = 1100

-- Protocol version this client negotiates. ACKs (and the id-based addressing +
-- v6 description layout this file parses) exist only at >= 6.
local CLIENT_PROTOCOL_VERSION = 6

-- Enumeration index → opaque server controller id (v6 addresses writes by id).
local controller_ids = {}
-- Enumeration index → its zones ({ id = <zone index string>, led_count = n }),
-- cached at enumeration so apply/per-LED can size each zone without a live
-- descriptor. One shared VM serves every controller, hence the index keying.
local controller_zones = {}
-- Enumeration index → whether `SetCustomMode` was already sent this connection.
local custom_mode_sent = {}

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

-- Read server messages until (and including) the trailing ACK, returning the
-- payload of the first message whose id is `want_id` (nil if none/omitted). At
-- v6 the server ACKs almost every request after any reply it sends, and a
-- queued LED write is ACKed by the controller's worker thread once the frame is
-- applied — so draining to the ACK is exactly the backpressure point. Any
-- unrelated broadcast that arrives in between is read and discarded.
local function recv_until_ack(dev, want_id)
  local captured
  while true do
    local _, pkt_id, size = recv_header(dev)
    local payload = (size > 0) and dev.transport:read(size) or ""
    if want_id and pkt_id == want_id and not captured then
      captured = payload
    end
    if pkt_id == PKT_ACK then
      return captured
    end
  end
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

-- Server strings are length-prefixed (u16), the length including a trailing
-- '\0'; exactly `len` bytes are consumed regardless of contents.
local function read_str(data, pos)
  local len, p = read_u16(data, pos)
  if len == 0 then
    return "", p
  end
  return data:sub(p, p + len - 1), p + len
end

-- Skip one ModeDescription at protocol v6: name, then 11 u32 fields (the v3
-- `value` is dropped at >= 6; brightness_min/max/brightness stay), then a
-- length-prefixed colour array.
local function skip_mode(data, pos)
  local _, p = read_str(data, pos)
  p = p + 4 * 11
  local num_colors
  num_colors, p = read_u16(data, p)
  return p + num_colors * 4
end

-- Skip a matrix-map block: [size u16][size bytes]. `size` is always >= 8 — the
-- height+width u32s are emitted even for an empty 0x0 matrix.
local function skip_matrix(data, pos)
  local size
  size, pos = read_u16(data, pos)
  return pos + size
end

-- Skip one SegmentDescription at v6: name, type, start_idx, leds_count, then a
-- per-segment matrix block and flags (both v6 additions).
local function skip_segment(data, pos)
  local _, p = read_str(data, pos)
  p = p + 4 -- type
  p = p + 4 -- start_idx
  p = p + 4 -- leds_count
  p = skip_matrix(data, p)
  p = p + 4 -- flags
  return p
end

-- Read one ZoneDescription at v6. `id` is the zone's 0-based ordinal as a string
-- (what `UpdateZoneLEDs` addresses); everything past `leds_count` is walked only
-- to advance `pos` to the next zone.
local function read_zone(data, pos, zero_based_index)
  local name, p = read_str(data, pos)
  p = p + 4 -- type
  p = p + 4 -- leds_min
  p = p + 4 -- leds_max
  local leds_count
  leds_count, p = read_u32(data, p)
  p = skip_matrix(data, p) -- zone matrix (unconditional)

  local num_segments
  num_segments, p = read_u16(data, p) -- segments (>= 4)
  for _ = 1, num_segments do
    p = skip_segment(data, p)
  end

  p = p + 4 -- zone flags (>= 5)

  local num_modes
  num_modes, p = read_u16(data, p) -- zone modes (>= 6)
  p = p + 4 -- zone active_mode
  for _ = 1, num_modes do
    p = skip_mode(data, p)
  end
  local _display_name
  _display_name, p = read_str(data, p)

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

local function controller_id(index)
  return controller_ids[index] or index
end

-- Put the controller into Direct/Custom mode exactly once per connection, so
-- per-LED writes land on writable LEDs. Inline-processed, but still ACKed at v6.
local function ensure_custom_mode(dev, index)
  if not custom_mode_sent[index] then
    send_packet(dev, controller_id(index), PKT_RGBCONTROLLER_SETCUSTOMMODE)
    recv_until_ack(dev)
    custom_mode_sent[index] = true
  end
end

-- Push one zone's contiguous colour array and block until the server ACKs that
-- the frame was applied — the backpressure that keeps us from outrunning the
-- device (and its siblings in phase).
local function send_zone(dev, index, zone_idx, colors)
  local rest = string.pack("<I4", zone_idx) .. string.pack("<I2", #colors) .. pack_colors(colors)
  send_packet(dev, controller_id(index), PKT_RGBCONTROLLER_UPDATEZONELEDS, with_data_size(rest))
  recv_until_ack(dev)
end

return {
  config = {
    fields = {
      { key = "host", label = "Server host", kind = "text", default = "127.0.0.1" },
      { key = "port", label = "Server port", kind = "number", default = "6742" },
    },
  },

  initialize = function(dev)
    -- One handshake on the single shared connection. SET_CLIENT_NAME is sent
    -- before the version is negotiated, so it is not yet ACKed; the version
    -- request negotiates v6 and its ACK (plus the version/server-string
    -- replies) is drained here.
    send_packet(dev, 0, PKT_SET_CLIENT_NAME, "HaloDaemon\0")
    send_packet(dev, 0, PKT_REQUEST_PROTOCOL_VERSION, string.pack("<I4", CLIENT_PROTOCOL_VERSION))
    recv_until_ack(dev)
    return true
  end,

  enumerate_controllers = function(dev)
    send_packet(dev, 0, PKT_REQUEST_CONTROLLER_COUNT)
    local cpayload = recv_until_ack(dev, PKT_REQUEST_CONTROLLER_COUNT)
    local count, cp = read_u32(cpayload, 1)
    -- v6: the count is followed by `count` controller ids, in enumeration order.
    controller_ids = {}
    for index = 0, count - 1 do
      controller_ids[index], cp = read_u32(cpayload, cp)
    end

    controller_zones = {}
    custom_mode_sent = {}
    local controllers = {}
    for index = 0, count - 1 do
      send_packet(dev, controller_id(index), PKT_REQUEST_CONTROLLER_DATA)
      local data = recv_until_ack(dev, PKT_REQUEST_CONTROLLER_DATA)

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
      pos = pos + 4 -- active_mode
      for _ = 1, num_modes do
        pos = skip_mode(data, pos)
      end

      local num_zones
      num_zones, pos = read_u16(data, pos)
      local zones = {}
      for z = 1, num_zones do
        zones[z], pos = read_zone(data, pos, z - 1)
      end
      -- LEDs/colours and the v6 trailing fields follow but aren't needed; the
      -- whole message was already consumed via the packet size.

      controller_zones[index] = zones
      controllers[#controllers + 1] = {
        index = index,
        name = (name ~= "" and name) or ("Controller " .. index),
        zones = zones,
      }
    end
    return controllers
  end,

  -- One worker multiplexes every controller, so route by the explicit `index`
  -- (enumeration order) rather than any per-device identity.
  write_controller_frame = function(dev, index, zone_id, colors)
    ensure_custom_mode(dev, index)
    send_zone(dev, index, tonumber(zone_id) or 0, colors)
  end,

  apply_controller = function(dev, index, state)
    local zones = controller_zones[index]
    if not zones then
      return
    end

    if state.mode == "static" then
      local color = state.color
      if not color then
        return
      end
      ensure_custom_mode(dev, index)
      for _, zone in ipairs(zones) do
        local colors = {}
        for i = 1, zone.led_count do
          colors[i] = color
        end
        send_zone(dev, index, tonumber(zone.id) or 0, colors)
      end
    elseif state.mode == "per_led" then
      local zmap = state.zones
      if not zmap then
        return
      end
      ensure_custom_mode(dev, index)
      for _, zone in ipairs(zones) do
        -- Sparse map keyed by the LED's 0-based id; unpainted LEDs fall back to
        -- black, matching `per_led_frame` on the native-driver side.
        local led_map = zmap[zone.id]
        local colors = {}
        for i = 1, zone.led_count do
          colors[i] = (led_map and led_map[tostring(i - 1)]) or BLACK
        end
        send_zone(dev, index, tonumber(zone.id) or 0, colors)
      end
    end
  end,
}
