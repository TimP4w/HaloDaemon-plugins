-- SPDX-License-Identifier: GPL-3.0-or-later
return function(h)
  local dev = h:open({ command_results = {{
    success = true, exit_code = 0,
    stdout = "GPU-123, Test GPU\n", stderr = "", timed_out = false,
  }} })
  h:assert(dev:initialize(), "command device initializes")
  local controllers = dev:enumerate_controllers()
  h:assert_eq(#controllers, 1, "one structured command row enumerates")
  h:assert_eq(controllers[1].id, "nvidia_gpu_GPU-123", "GPU UUID is preserved")
  h:assert_eq(controllers[1].name, "Test GPU", "GPU name is preserved")

  local child = h:open({ key = "GPU-123", command_results = {{
    success = true, exit_code = 0,
    stdout = "54, 67\n", stderr = "warning\n", timed_out = false,
  }} })
  h:assert(child:initialize(), "GPU child initializes")
  local sensors = child:poll_sensors()
  h:assert_eq(#sensors, 2, "structured stdout produces both sensors")
  h:assert_eq(sensors[1].value, 54.0, "core temperature is parsed")
  h:assert_eq(sensors[2].value, 67.0, "memory temperature is parsed")

  local failed = h:open({ command_results = {{
    success = false, exit_code = 9, stdout = "ignored", stderr = "driver error",
    timed_out = false,
  }} })
  h:assert(failed:initialize(), "non-zero fixture initializes")
  local failed_controllers = failed:enumerate_controllers()
  h:assert_eq(#failed_controllers, 0, "non-zero command result is handled")

  local timed_out = h:open({ command_results = {{
    success = false, exit_code = -1, stdout = "", stderr = "", timed_out = true,
  }} })
  h:assert(timed_out:initialize(), "timeout fixture initializes")
  local timed_out_controllers = timed_out:enumerate_controllers()
  h:assert_eq(#timed_out_controllers, 0, "timed-out command result is handled")
end
