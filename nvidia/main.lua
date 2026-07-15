-- SPDX-License-Identifier: GPL-3.0-or-later
-- One child per UUID, matching the former nvidia-smi driver's identity and
-- temperature semantics. The command transport invokes the executable directly.
local function lines(value)
  local out = {}
  for line in value:gmatch("[^\r\n]+") do out[#out + 1] = line end
  return out
end

local function gpu_rows()
  -- Absence of nvidia-smi/a transient driver restart is not a device failure.
  -- The former native source simply yielded no readings in that case.
  local ok, out = pcall(command.run, "nvidia-smi", { "--query-gpu=uuid,name", "--format=csv,noheader,nounits" })
  if not ok then return {} end
  local rows = {}
  for _, line in ipairs(lines(out)) do
    local uuid, name = line:match("^%s*([^,]+),%s*(.-)%s*$")
    if uuid and uuid ~= "" and name and name ~= "" then rows[#rows + 1] = { uuid = uuid, name = name } end
  end
  return rows
end

local function stable_id(uuid) return "nvidia_gpu_" .. uuid end

return {
  enumerate_controllers = function(_dev)
    local controllers = {}
    for index, gpu in ipairs(gpu_rows()) do
      controllers[#controllers + 1] = {
        index = index - 1, id = stable_id(gpu.uuid), key = gpu.uuid,
        serial = gpu.uuid, name = gpu.name, device_type = "gpu", sensor = {},
      }
    end
    return controllers
  end,
  initialize = function(dev)
    if not dev.match.key then return { ok = true } end
    return { ok = true, model = dev.match.name or dev.match.key }
  end,
  get_sensors = function(dev)
    local uuid = dev.match.key
    if not uuid then return {} end
    -- Preserve the native driver's one-second poll cadence: several GUI and
    -- engine consumers may ask for the same snapshot in one frame.
    local now = halod.monotonic_ms()
    if dev.sensor_cache and now < (dev.sensor_cache_until or 0) then
      return dev.sensor_cache
    end
    local ok, out = pcall(command.run, "nvidia-smi", {
      "-i", uuid, "--query-gpu=temperature.gpu,temperature.memory", "--format=csv,noheader,nounits"
    })
    if not ok then
      dev.sensor_cache, dev.sensor_cache_until = {}, now + 1000
      return dev.sensor_cache
    end
    local row = lines(out)[1] or ""
    local core, memory = row:match("^%s*([^,]+),%s*(.-)%s*$")
    local sensors = {}
    local value = tonumber(core)
    if value then sensors[#sensors + 1] = { id = stable_id(uuid) .. "_temp1", name = "GPU Core", value = value, unit = "celsius", sensor_type = "temperature" } end
    value = tonumber(memory)
    if value then sensors[#sensors + 1] = { id = stable_id(uuid) .. "_temp2", name = "Memory", value = value, unit = "celsius", sensor_type = "temperature" } end
    dev.sensor_cache, dev.sensor_cache_until = sensors, now + 1000
    return sensors
  end,
}
