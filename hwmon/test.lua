-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: Timucin Besken <beskent@gmail.com>

return function(h)
  local root = h:open_integration({
    hwmon = {
      {
        stable_id = "pci0000_00_0000_00_18_3",
        name = "nct6798",
        attributes = {
          temp1_input = "42000\n",
          temp1_label = "CPU\n",
          fan1_input = "1200\n",
          fan1_label = "CPU Fan\n",
          pwm1 = "128\n",
          pwm1_enable = "2\n",
        },
      },
    },
  })
  h:assert(root:initialize(), "integration root initializes")

  local controllers = root:enumerate_controllers()
  h:assert_eq(#controllers, 2, "one chip and one controllable fan")
  h:assert_eq(controllers[1].id, "hwmon_pci0000_00_0000_00_18_3", "stable chip id")
  h:assert_eq(controllers[2].id, "hwmon_pci0000_00_0000_00_18_3_fan1", "stable fan id")
  h:assert_eq(controllers[2].name, "CPU Fan", "fan label")

  local sensor = root:open_controller(controllers[1].index)
  h:assert(sensor:initialize(), "sensor child initializes")
  local sensors = sensor:get_sensors()
  h:assert_eq(#sensors, 1, "missing temp2 ends enumeration")
  h:assert_eq(sensors[1].id, "hwmon_pci0000_00_0000_00_18_3_temp1", "stable sensor id")
  h:assert_eq(sensors[1].name, "CPU", "temperature label")
  h:assert(sensors[1].value == 42, "millidegrees converted to Celsius")

  local fan = root:open_controller(controllers[2].index)
  h:assert(fan:initialize(), "fan child initializes")
  h:assert_eq(fan:get_rpm(), 1200, "fan RPM")
  h:assert_eq(fan:get_duty(), 50, "raw PWM rounds to percent")
  fan:set_duty(75)
  h:assert_eq(root:hwmon_read("0", "pwm1_enable"), "1", "fan switched to manual mode")
  h:assert_eq(root:hwmon_read("0", "pwm1"), "191", "percent converted to raw PWM")
end
