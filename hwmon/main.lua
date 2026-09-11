-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: Timucin Besken <beskent@gmail.com>

local function split_key(key)
  local route, stable = key:match("^([^:]+):(.*)$")
  return route, stable
end

local function trim(value)
  return value and value:match("^%s*(.-)%s*$") or nil
end

local function read(dev, attribute)
  local route = split_key(assert(dev.match.key, "hwmon route missing"))
  return trim(dev.transport:hwmon_read(route, attribute))
end

local function number(dev, attribute)
  return tonumber(read(dev, attribute))
end

local function has(attributes, name)
  for _, attribute in ipairs(attributes) do
    if attribute == name then return true end
  end
  return false
end

-- Every chip's temperatures land on one aggregate device, so a reading carries
-- its chip name; the bare `tempN_label` alone would not say which chip it came
-- from. Ids keep the per-chip form so saved fan curves still resolve.
local function temperature_indexes(attributes)
  local indexes = {}
  for _, attribute in ipairs(attributes) do
    local index = attribute:match("^temp(%d+)_input$")
    if index then indexes[#indexes + 1] = tonumber(index) end
  end
  table.sort(indexes)
  return indexes
end

-- A sensor can be unreadable while its chip stays listed (a sleeping device),
-- so one nil skips that reading instead of ending the chip's walk.
local function chip_sensors(dev, chip, out)
  for _, index in ipairs(temperature_indexes(chip.attributes)) do
    local raw = tonumber(trim(dev.transport:hwmon_read(chip.key, "temp" .. index .. "_input")))
    if raw ~= nil then
      local label = trim(dev.transport:hwmon_read(chip.key, "temp" .. index .. "_label")) or ""
      out[#out + 1] = {
        id = "hwmon_" .. chip.stable_id .. "_temp" .. index,
        name = chip.name .. " " .. (label ~= "" and label or ("temp" .. index)),
        value = raw / 1000,
        unit = "celsius",
        sensor_type = "temperature",
      }
    end
  end
end

return {
  -- Host requirement probing checks that a usable hwmon collection exists
  -- before this hook runs. No additional user configuration is required.
  validate = function(_context)
    return { ok = true }
  end,

  initialize = function(dev)
    if dev.match.index == nil then
      return { ok = true, capabilities = {} }
    end
    local fan = dev.match.fan_index or 0
    if fan == 0 then
      return { ok = true, capabilities = { "sensors" } }
    end
    return {
      ok = true,
      capabilities = { "cooling" },
      cooling = { channels = {
        { id = "fan", name = dev.match.name or ("Fan " .. fan), kind = "fan", controllable = true },
      } },
    }
  end,

  enumerate_controllers = function(dev)
    -- One device for every chip's temperatures, rather than a device per chip:
    -- a dozen single-reading entries would bury the real peripherals.
    local controllers = { {
      index = 0,
      id = "hwmon_sensors",
      key = "",
      name = "Linux Hardware Monitoring",
      device_type = "motherboard",
      extra = { fan_index = 0 },
    } }
    local index = 1
    for _, chip in ipairs(dev.transport:hwmon_list()) do
      local route = chip.key .. ":" .. chip.stable_id
      for fan = 1, 16 do
        local pwm = "pwm" .. fan
        local enable = pwm .. "_enable"
        if has(chip.attributes, "fan" .. fan .. "_input")
            and has(chip.attributes, pwm)
            and has(chip.writable_attributes or {}, pwm)
            and (not has(chip.attributes, enable)
              or has(chip.writable_attributes or {}, enable)) then
          local label = dev.transport:hwmon_read(chip.key, "fan" .. fan .. "_label")
          label = label and label:match("^%s*(.-)%s*$") or ""
          controllers[#controllers + 1] = {
            index = index,
            id = "hwmon_" .. chip.stable_id .. "_fan" .. fan,
            key = route,
            name = label ~= "" and label or ("Fan " .. fan),
            device_type = "fan",
            extra = { fan_index = fan },
          }
          index = index + 1
        end
      end
    end
    return controllers
  end,

  get_sensors = function(dev)
    local sensors = {}
    for _, chip in ipairs(dev.transport:hwmon_list()) do
      chip_sensors(dev, chip, sensors)
    end
    return sensors
  end,

  get_cooling_status = function(dev, channel_id)
    assert(channel_id == "fan", "unknown cooling channel: " .. tostring(channel_id))
    local fan = assert(dev.match.fan_index, "hwmon fan index missing")
    local rpm = number(dev, "fan" .. fan .. "_input") or 0
    local raw = math.min(number(dev, "pwm" .. fan) or 0, 255)
    local duty = math.floor((raw * 100 + 127) / 255)
    return { id = "fan", name = dev.match.name or ("Fan " .. fan), kind = "fan", controllable = true, rpm = rpm, duty = duty }
  end,

  set_cooling_duty = function(dev, channel_id, duty)
    assert(channel_id == "fan", "unknown cooling channel: " .. tostring(channel_id))
    local route = split_key(assert(dev.match.key, "hwmon route missing"))
    local fan = assert(dev.match.fan_index, "hwmon fan index missing")
    local enable = number(dev, "pwm" .. fan .. "_enable") or 1
    if enable ~= 1 then
      dev.transport:hwmon_write(route, "pwm" .. fan .. "_enable", "1")
    end
    local raw = math.min(math.floor(duty * 255 / 100), 255)
    dev.transport:hwmon_write(route, "pwm" .. fan, tostring(raw))
  end,
}
