# Plugin manifest reference

`plugin.yaml` describes a plugin without running its Lua code. HaloDaemon reads
and validates this file before the plugin can be enabled.

Repository compatibility and package hashes belong in the root
[`repository.yaml`](../repository.yaml), not in a plugin manifest.

## Package layout

```text
my_plugin/
├── plugin.yaml
├── main.lua
├── test.lua              optional
├── lib/
│   └── protocol.lua      optional package-local modules
├── docs/
│   └── protocol.md
└── assets/               optional images
```

The directory name must equal the manifest `id`. Lua modules under `lib/` can
be loaded with `halod.require("lib.protocol")`. A module cannot load files from
outside its own package.

## Basic device plugin

```yaml
id: example_ring
name: Example Ring
version: 1.0.0
license: GPL-3.0-or-later
platforms: [linux, windows]
permissions: [hid]
capabilities: [rgb]

devices:
  - vendor: Example
    model: Ring 12
    type: led_strip
    match:
      hid: { vid: 0x1234, pid: 0x5678 }

transports:
  hid: { report_size: 64, timeout_ms: 1000 }
```

## Top-level fields

| Field | Meaning |
|---|---|
| `id` | Required package ID. It must match the directory name. |
| `type` | `device`, `integration`, or `effect`. Default: `device`. |
| `name` | Display name. |
| `author` | Plugin author. |
| `version` | Plugin version text. |
| `license` | License name or SPDX identifier. |
| `description` | Short description. |
| `entry` | Entry script. Default: `main.lua`. |
| `platforms` | Any of `linux`, `windows`, and `macos`. Empty means all platforms. |
| `permissions` | Privileges shown in the consent prompt. |
| `capabilities` | Everything this package may expose at runtime. |
| `devices` | Hardware entries for a device plugin. |
| `transports` | Transport settings and access limits. |
| `requirements` | Explicit command or Linux kernel-module dependencies that cannot be inferred. |
| `dynamic_children` | Allows `enumerate_controllers()` to create child devices. |
| `config` | User-editable settings. |
| `effects` | Effects provided by an effect plugin. |
| `effect_assets` | Optional effect thumbnails. |
| `logo` | Optional filename under `assets/`. |

Unknown fields are rejected. A plugin manifest does not have a `compatibility`
field or a flat device `transport` field.

## Linux device access

Plugins do not carry raw udev text. HaloDaemon derives safe `uaccess` rules
from the manifest's existing hardware authority: HID matches produce `hidraw`
rules, USB matches produce USB-device rules, and a declared USB transport also
produces USB-device rules for its primary HID match and companion devices.
SMBus matches produce no rule by default: `bus: chipset` scopes access to the
Intel/AMD chipset SMBus drivers, while `bus: gpu` produces PCI-vendor-scoped
rules from `pci_match`. This keeps discovery, runtime authority, and Linux
access in one declaration.

Print the daemon baseline plus all currently installed plugin rules at runtime:

```sh
halod udev-rules
```

## Capabilities

Supported names are:

```text
rgb, fan, sensors, battery, connection, dpi, report_rate,
key_remap, keyboard_layout, onboard_profiles, lcd, equalizer,
pairing, controls, chain
```

This list is the package's maximum capability set. `initialize()` may return a
smaller set for a specific model.

## Device entries and matches

Each device needs `vendor`, `model`, and exactly one nested `match` entry.
`name` and `type` are optional.

| Match | Main fields |
|---|---|
| `hid` | `vid`, `pid` or `pids`; optional `usage_page`, `usage`, `interface`, `max_bytes_per_sec` |
| `usb` | `vid` and `pid`; optional `interface` (default `0`) |
| `smbus` | `bus`, `addresses`; optional `extra_addresses`, `pre_scan`, `probe`, `pci_match`, `max_bytes_per_sec` |
| `command` | Exact executable name |
| `amd_smn` | `any: true` |
| `lpcio` | `chip_ids`, or `any: true` |

Use `hid: { any: true }` only when matching every HID device is intentional.
Do not combine `any: true` with VID/PID fields.

SMBus `bus` is `chipset` or `gpu`. `probe` is `quick`, `read_byte`, or `none`.
A GPU match also needs at least one `pci_match` entry.

USB discovery keeps the bus, port path, address, interface, and serial. This
keeps identical VID/PID devices separate.

## Permissions

| Permission | Grants |
|---|---|
| `hid` | Access to the matched HID device and its input reports. |
| `usb` | Access to declared USB devices, interfaces, and endpoints. |
| `smbus` | SMBus scanning and scoped register access. |
| `hwmon` | Access to the scoped Linux hwmon collection. |
| `lpcio` | Typed LPC/Super I/O operations on Windows. |
| `amd_smn` | Read-only AMD SMN access on Windows. |
| `command` | Running declared executable names without a shell. |
| `network` | Opening network connections. |
| `os` | The limited `os.time()` and `os.clock()` functions. |
| `secure_storage` | Reading this plugin's protected config values. |
| `audio_routing` | Creating and controlling host audio sinks. |

A hardware match must declare its matching permission. TCP requires `network`.
The command transport requires `command`. A new permission requires new user
consent.

## Host requirements

The host automatically checks command-transport executables, PawnIO for its
Windows hardware transports, Linux I2C access for SMBus matches, and hwmon
presence and permissions for the hwmon transport. Plugins must not repeat those
requirements.

An external command used by a non-command integration and a plugin-specific
Linux kernel module can be declared explicitly:

```yaml
requirements:
  - kind: kernel_module
    name: i2c-dev
    platforms: [linux]
  - kind: command
    name: pactl
    platforms: [linux]
```

Supported kinds are `command` and `kernel_module`. Kernel modules must declare
`platforms: [linux]`. Explicit requirements block activation when missing.

## Transport settings

### HID

```yaml
transports:
  hid:
    report_size: 64
    timeout_ms: 1000
    feature_report: false
    companion: { usage_page: 0xff00, usage: 2 }
```

`report_size: 0` means raw writes with no padding. A companion is a second HID
collection on the same physical device.

### USB

```yaml
permissions: [usb]
transports:
  usb:
    devices:
      - id: primary
        interface: 1
        alternate_setting: 0
        endpoints:
          - address: 0x02
            type: bulk
            max_transfer_size: 4194304
            max_timeout_ms: 10000
          - address: 0x81
            type: interrupt
            max_transfer_size: 64
            max_timeout_ms: 1000
        control:
          max_transfer_size: 64
          max_timeout_ms: 1000

      - id: companion
        vid: 0x1234
        pid: 0x5679
        interface: 0
        control:
          max_transfer_size: 256
          max_timeout_ms: 1000
```

There must be one device named `primary`. It uses the matched device's VID and
PID, so it must not declare its own. Other named devices are companions and
must declare a VID and PID.

`interface` may be omitted when an endpoint uniquely identifies the interface.
Set it explicitly when the device has several possible interfaces.

Every endpoint is an allowlist entry. Its address also sets its direction:
`0x01..0x0f` are OUT and `0x81..0x8f` are IN. The type is `bulk` or
`interrupt`. Calls that exceed the size or timeout limits fail. USB control
transfers are disabled unless the device has a `control` block.

### TCP

```yaml
permissions: [network]
transports:
  tcp:
    host_key: host
    port_key: port
    timeout_ms: 5000
    allow_private: false
```

`host_key` and `port_key` name fields under `config`. Set `allow_private: true`
only when the integration must connect to loopback, private, or link-local
addresses.

### Command

```yaml
permissions: [command]
transports:
  command:
    commands: [nvidia-smi]
```

Commands must be bare executable names. Paths and shell expressions are not
allowed. A `match.command` value must appear in this list. Every listed command
is checked automatically before activation.

### hwmon

Linux hwmon is an integration transport rather than a device match:

```yaml
type: integration
platforms: [linux]
permissions: [hwmon]
transports:
  hwmon: {}
```

The host enumerates the collection and exposes only typed, path-free attribute
operations. It automatically checks for readable sensors and, for fan-capable
plugins, writable PWM attributes. An integration declares exactly one root
transport, so `hwmon` and `tcp` cannot appear together.

### AMD SMN and LPCIO

These Windows transports use explicit empty settings:

```yaml
permissions: [amd_smn, lpcio]
transports:
  amd_smn: {}
  lpcio: {}
```

They expose typed operations only. Lua never receives a raw broker handle. On
Windows, PawnIO installation is checked automatically for these transports.

SMBus access is fully described by the device match and does not need a
separate transport block. The host automatically checks PawnIO on Windows and
Linux i2c-dev presence and permissions on Linux.

## Config fields

```yaml
config:
  fields:
    - key: host
      label: Server address
      kind: text
      default: 192.168.1.10
    - key: token
      label: API token
      kind: text
      default: ""
      secure: true
```

Config `kind` is `text` or `number`. Number fields may set `min` and `max`.
Every value is exposed to Lua as a string in `halod.config`. A secure value is
available only with `secure_storage` permission.

## Effect plugins

An effect plugin uses `type: effect`, declares no devices or transports, and
lists one or more effects:

```yaml
type: effect
effects:
  - id: pulse
    name: Pulse
    kind: direct
    params: []
```

`kind` is `pixmap` or `direct`. See the [Lua API](lua-api.md#effect-api) for
callback names and parameters.

## Runtime descriptors

Device details that may change by model or firmware come from `initialize()`,
not from YAML. This includes RGB zones, controls, DPI limits, LCD size, fan
details, keyboard layouts, and chain accessories.

Set `dynamic_children: true` only when `enumerate_controllers()` creates
separate devices, such as receiver slots or GPUs. Each child needs a stable
`id`. An optional `key` is returned later as `dev.match.key`.

## Validation

Run a package check and its optional `test.lua` with:

```powershell
halod plugin-test .\my_plugin
```
