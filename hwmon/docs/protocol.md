<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- SPDX-FileCopyrightText: Timucin Besken <beskent@gmail.com> -->

# Linux hwmon integration

Sysfs attribute contract between this integration and the Linux kernel's `/sys/class/hwmon` devices, accessed through HaloDaemon's scoped [hwmon transport](https://github.com/TimP4w/HaloDaemon/blob/main/docs/transports/hwmon.md).

---

## Overview

This is not a wire protocol: the data unit is a named sysfs attribute on an allowlisted hwmon chip. Lua receives opaque chip keys and supported attribute names; it never receives sysfs paths. Reads are limited to supported sensor, fan, and PWM attributes; writes are limited to PWM and PWM-mode attributes.

Each chip becomes a sensor device. Fan headers that are both readable and PWM-controllable become separate fan child devices. All access is host-initiated: the kernel never pushes data.

---

## 1. Packet layout

The natural data unit is one attribute access, addressed by an opaque route key plus an attribute name.

### Route key

The controller `key` handed to Lua is `"<transport-key>:<stable-id>"`. The transport key part addresses the chip in `hwmon_read` / `hwmon_write`; the stable id part builds device identifiers.

### Attribute names

```text
tempN_input    temperature, millidegrees Celsius (read)
tempN_label    optional temperature display name (read)
fanN_input     fan speed, RPM (read)
fanN_label     optional fan display name (read)
pwmN           duty, kernel 0-255 range (read/write)
pwmN_enable    fan-control mode; 1 = manual (read/write)
```

Values are ASCII text, typically newline-terminated; the integration trims surrounding whitespace.

### Unit conversions

- `tempN_input` millidegrees are divided by 1000 to Celsius.
- PWM reads convert 0-255 to percent with round-half-up: `floor((raw * 100 + 127) / 255)`.
- PWM writes convert percent to 0-255 with truncation: `min(floor(duty * 255 / 100), 255)`.

---

## 2. Functions

| Function | Access | Behavior |
| --- | --- | --- |
| Chip enumeration | `hwmon_list()` | Lists scoped chips with key, stable id, name, attributes, writable attributes |
| Fan detection | attribute presence | Indexes 1 through 16: requires `fanN_input` present and `pwmN` writable; if `pwmN_enable` exists it must also be writable |
| Temperature read | `tempN_input`, `tempN_label` | Enumeration stops at the first missing temperature index, matching the former built-in driver |
| Fan status read | `fanN_input`, `pwmN` | RPM from `fanN_input`; duty from `pwmN` converted to percent |
| Duty write | `pwmN_enable`, `pwmN` | Switches `pwmN_enable` to manual mode (`1`) first when necessary, then writes the raw duty |

The host records and restores the original `pwmN_enable` value independently of Lua shutdown, including after plugin failure.

---

## 3. Parameters

| Parameter | Value | Meaning |
| --- | --- | --- |
| Temperature unit | millidegrees Celsius | Kernel convention; divided by 1000 |
| PWM range | 0-255 | Kernel convention; mapped to 0-100 percent |
| Manual fan mode | `pwmN_enable = 1` | Required before duty writes take effect |
| Fan index range | 1-16 | Only these indexes are probed for fan children |
| Device id | `hwmon_<stable-path>` | Chip sensor device, retains the former built-in form |
| Fan id | `hwmon_<stable-path>_fanN` | Fan child device |
| Sensor id | `hwmon_<stable-path>_tempN` | Temperature sensor |

Display names: `tempN_label` supplies the optional temperature name; `fanN_label` supplies the fan name, falling back to `Fan N`.

---

## 4. Responses

Reads return the attribute's text content; the integration trims whitespace and parses numbers with `tonumber`. A missing or unreadable attribute yields nil, which ends temperature enumeration or falls back to defaults (RPM and duty read as 0, enable defaults to manual). Writes have no response; failures surface as transport errors.

---

## 5. Polling & notifications

None at this layer: the kernel exposes current values on every read and the host polls sensors and fan status on its own schedule. There are no notifications or unsolicited events.

---

## Notes

- Attributes and chips outside the host-supplied scoped collection cannot be accessed; missing kernel drivers produce missing chips, not errors.
- Enable restoration is a host guarantee, not Lua logic: the transport restores fan-control modes when it closes.
