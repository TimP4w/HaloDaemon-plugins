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
| `type` | `device`, `integration`, `effect`, or `lcd`. Default: `device`. |
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
| `widgets` | LCD widget declarations for an `lcd` package. |
| `presets` | Declarative LCD template JSON files for an `lcd` package. |
| `logo` | Optional filename under `assets/`. |
| `provides` | Namespaced latest-value records published by this package. |
| `consumes` | Records this package may read; `host.sensors.*` is the only wildcard. |

Unknown fields are rejected. A plugin manifest does not have a `compatibility`
field or a flat device `transport` field.

## Shared snapshot data

```yaml
provides:
  - key: weather.current
    stale_after_ms: 900000
    min_notify_interval_ms: 1000
consumes: [weather.current, host.sensors.*, host.media.playback, host.environment]
```

Provided keys must begin with the package id. Cross-plugin and `host.*` reads
are shown as user-approved authority. Host sensors are individual records plus
`host.sensors.catalog`. Audio remains a dedicated sampled stream.

### Widget fields

`widgets` is valid for `type: lcd`. Widget IDs become `<plugin-id>:<id>` in the
daemon catalog.

| Field | Meaning |
|---|---|
| `id` | Widget ID within the package. |
| `name` | Display name shown in the widget library. |
| `icon` | Required SVG filename under `assets/`; also available to `draw_asset`. |
| `assets` | Additional SVG filenames under `assets/` available only to this widget through `draw_asset`. |
| `params` | Editor parameters passed to the widget callbacks. |
| `resize` | `uniform` or `box`. |
| `default_scale` | Initial editor scale. |
| `min_scale` | Smallest editor scale. |
| `default_aspect` | Initial height-to-width ratio for a `box` widget. |
| `auto_width_param` | Text parameter that grows the widget horizontally. |
| `param_visibility` | Conditional visibility rules for editor parameters. |
| `uses_color` | Adds the shared widget color control. |
| `uses_font` | Enables host-rendered text and its style parameters. |
| `font_controls` | Whether the shared font and style controls are editable. Default: `true`. |
| `default_font` | Initial installed system font family. Requires `uses_font`. |
| `fixed_text_weight` | Host-enforced `normal`, `semibold`, or `bold` weight. Requires `font_controls: false`. |
| `updates` | Update interval and live-data dependencies. |

An `updates` map accepts `interval_ms`, `sensors`, `audio`, and `media`.
`sensors_when` and `audio_when` can gate those dependencies with the same enum
condition syntax as parameter visibility. A visibility rule maps a target
parameter to an enum source and required value, for example
`fill: { param: variant, equals: bar }`.

Widget asset names must be bare `.svg` filenames. Every file is parsed during
manifest validation and subject to per-file, per-widget, and package limits.
The renderer rasterizes declared assets into bounded resize buckets; an
undeclared name passed to `draw_asset` returns `false`.

### Preset fields

`presets` is valid for `type: lcd`. Each entry declares `id`, `name`, and a JSON
`file` under `assets/`. Preset IDs become `<plugin-id>:<id>` in the daemon
catalog, and every referenced layout is validated before it is offered.

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
rgb, fan, sensors, battery, connection, dpi,
key_remap, keyboard_layout, onboard_profiles, lcd, equalizer,
pairing, controls, chain
```

This list is the package's maximum capability set. `initialize()` may return a
smaller set for a specific model.

Device settings such as report rate, sleep timeout, debounce, sidetone, and
similar controls use the generic `controls` capability. Model them as choice,
range, boolean, or action descriptors instead of adding standalone capability
names.

## Device entries and matches

Each device needs `vendor`, `model`, and exactly one nested `match` entry.
`name`, `type`, and `control_layout` are optional.

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

### Control layout

`control_layout` places the Controls tab's category cards on a grid. Omit it and
every category gets its own full-width row, alphabetically.

```yaml
devices:
  - vendor: SteelSeries
    model: Arctis Nova Pro Wireless
    control_layout:
      - { category: Microphone, order: 0, column: 0 }
      - { category: Noise Cancelling, order: 1, column: 1 }
```

| Field | Meaning |
|---|---|
| `category` | Matches a control's `category` (`""` ⇒ `Settings`). |
| `order` | Placement order across categories. Default: `0`. |
| `column` | 0-based start column. Default: `0`. |
| `span` | Width in columns. Default: `1`. |

The grid is as wide as the furthest `column + span`. Entries are placed in
`order`; one that would overlap or overflow the current row starts a new one. A
category with no entry — or one whose controls the device does not report — is
appended as its own full-width row, so a layout may name fewer categories than
the plugin declares.

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
      kind: host
      default: 192.168.1.10
      placeholder: openrgb.local
      help: Hostname or IP address of the server.
    - key: port
      label: Server port
      kind: port
      default: 6742
    - key: tls
      label: Use TLS
      kind: boolean
      default: false
    - key: mode
      label: Connection mode
      kind: enum
      options: [direct, proxy]
      default: direct
    - key: proxy_url
      label: Proxy URL
      kind: url
      default: ""
      visible_when: { field: mode, equals: proxy }
    - key: timeout
      label: Timeout
      kind: duration_ms
      default: 5000
      min: 100
      max: 30000
    - key: token
      label: API token
      kind: text
      default: ""
      secure: true
```

Config `kind` is `text`, `number`, `boolean`, `enum`, `host`, `port`, `url`, or
`duration_ms`. Enum fields require a non-empty `options` list. Number, port,
and duration fields may set `min` and `max`; ports are always restricted to
1–65535. URLs must be absolute HTTP(S) URLs.

`visible_when` uses sibling equality, matching widget parameter visibility.
`help` and `placeholder` are optional display text.

Lua receives booleans as booleans, numbers, ports, and durations as numbers,
and text, enum, host, and URL values as strings. Secure fields are masked in
the GUI, never cross IPC in plaintext, and require the manifest to declare the
`secure_storage` permission before the package validates.

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
