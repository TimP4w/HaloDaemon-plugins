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
  h:assert_eq(#controllers, 2, "one aggregate sensor device and one controllable fan")
  h:assert_eq(controllers[1].id, "hwmon_sensors", "aggregate sensor device id")
  h:assert_eq(controllers[2].id, "hwmon_pci0000_00_0000_00_18_3_fan1", "stable fan id")
  h:assert_eq(controllers[2].name, "CPU Fan", "fan label")

  local sensor = root:open_controller(controllers[1].index)
  h:assert(sensor:initialize(), "sensor child initializes")
  local sensors = sensor:get_sensors()
  h:assert_eq(#sensors, 1, "missing temp2 ends enumeration")
  h:assert_eq(sensors[1].id, "hwmon_pci0000_00_0000_00_18_3_temp1", "stable sensor id")
  h:assert_eq(sensors[1].name, "nct6798 CPU", "reading is qualified by its chip")
  h:assert(sensors[1].value == 42, "millidegrees converted to Celsius")

  local fan = root:open_controller(controllers[2].index)
  h:assert(fan:initialize(), "fan child initializes")
  local cooling = fan:get_cooling_status("fan")
  h:assert_eq(cooling.rpm, 1200, "fan RPM")
  h:assert_eq(cooling.duty, 50, "raw PWM rounds to percent")
  fan:set_cooling_duty("fan", 75)
  h:assert_eq(root:hwmon_read("0", "pwm1_enable"), "1", "fan switched to manual mode")
  h:assert_eq(root:hwmon_read("0", "pwm1"), "191", "percent converted to raw PWM")

  local read_only = h:open_integration({
    hwmon = {
      {
        stable_id = "read_only_chip",
        name = "read-only hwmon",
        attributes = {
          temp1_input = "39000\n",
          fan1_input = "900\n",
          pwm1 = "128\n",
          pwm1_enable = "2\n",
        },
        writable_attributes = {},
      },
    },
  })
  h:assert(read_only:initialize(), "read-only integration initializes")
  local read_only_controllers = read_only:enumerate_controllers()
  h:assert_eq(#read_only_controllers, 1, "a read-only chip contributes no fan device")
  local read_only_sensors = read_only:open_controller(0)
  h:assert(read_only_sensors:initialize(), "aggregate device initializes")
  h:assert_eq(read_only_sensors:get_sensors()[1].name, "read-only hwmon temp1",
    "an unlabeled reading falls back to its index")

  local two_chips = h:open_integration({
    hwmon = {
      { stable_id = "chip_a", name = "k10temp", attributes = { temp1_input = "51000\n", temp1_label = "Tctl\n" } },
      { stable_id = "chip_b", name = "nvme", attributes = { temp1_input = "38000\n", temp2_input = "45000\n" } },
    },
  })
  h:assert(two_chips:initialize(), "multi-chip integration initializes")
  h:assert_eq(#two_chips:enumerate_controllers(), 1, "every chip folds into one sensor device")
  local aggregate = two_chips:open_controller(0)
  h:assert(aggregate:initialize(), "aggregate device initializes")
  local all = aggregate:get_sensors()
  h:assert_eq(#all, 3, "readings from every chip land on one device")
  h:assert_eq(all[1].id, "hwmon_chip_a_temp1", "first chip keeps its per-chip sensor id")
  h:assert_eq(all[1].name, "k10temp Tctl", "labeled reading")
  h:assert_eq(all[3].id, "hwmon_chip_b_temp2", "second chip's second reading")
end
