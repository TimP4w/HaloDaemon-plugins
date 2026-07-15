<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- SPDX-FileCopyrightText: Timucin Besken <beskent@gmail.com> -->

# Linux hwmon integration

This integration enumerates the Linux kernel's `/sys/class/hwmon` devices
through HaloDaemon's scoped [hwmon transport](https://github.com/TimP4w/HaloDaemon/blob/main/docs/transports/hwmon.md).
Lua receives opaque chip keys and supported attribute names; it never receives
sysfs paths.

Each chip becomes a sensor device. `tempN_input` is reported in millidegrees
Celsius and converted to Celsius; `tempN_label` supplies the optional display
name. Enumeration stops at the first missing temperature index, matching the
former built-in driver.

A fan child is created for indexes 1 through 16 when both `fanN_input` and
`pwmN` exist. RPM comes from `fanN_input`. PWM values use the kernel's 0–255
range and are converted to percentages with round-half-up reads and truncating
writes. Before changing duty, the integration switches `pwmN_enable` to manual
mode (`1`) when necessary. The host records and restores the original enable
value independently of Lua shutdown.

Device and sensor identifiers retain the former built-in forms:
`hwmon_<stable-path>`, `hwmon_<stable-path>_fanN`, and
`hwmon_<stable-path>_tempN`.
