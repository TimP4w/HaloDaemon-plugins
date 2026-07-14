# Plugin manifest reference

`plugin.yaml` is the only declarative manifest for a HaloDaemon plugin. It contains package
metadata, compatibility, permissions, device matching, transports, capabilities, controls,
configuration, and effects. The entry Lua file contains executable callbacks only; HaloDaemon does
not compile or execute it while loading the manifest.

See the [Lua API reference](lua-api.md) for callback signatures and runtime APIs.

## Package layout

```text
my_plugin/
├── plugin.yaml
├── main.lua                 # executable callbacks; configurable with `entry`
├── test.lua                 # optional hardware-free tests
└── assets/
    ├── logo.png             # selected automatically when present
    └── effect-preview.png
```

The package directory name and manifest `id` must match. `plugin.yaml` and the entry script must be
regular files rather than symlinks, and `entry` must be a relative path contained by the package.

## Minimal manifests

Device plugin:

```yaml
id: example_ring
compatibility:
  halod: ">=0.2.0"
  plugin_api: 1
name: Example Ring
version: 1.0.0
license: GPL-3.0-or-later

devices:
  - vendor: Example
    model: Ring 12
    device_type: led_strip
    transport: hid
    vid: 0x1234
    pid: 0x5678

transports:
  hid:
    report_size: 64
    timeout_ms: 1000
    feature_report: false

rgb:
  zones: []                 # initialize() reports the runtime zone
```

Integration plugin:

```yaml
id: example_bridge
compatibility:
  halod: ">=0.2.0"
  plugin_api: 1
type: integration
name: Example Bridge
version: 1.0.0
license: GPL-3.0-or-later
permissions: [network]

transports:
  tcp:
    host_key: host
    port_key: port
    timeout_ms: 5000
    allow_private: true

config:
  fields:
    - key: host
      label: Server host
      kind: text
      default: 127.0.0.1
    - key: port
      label: Server port
      kind: number
      default: "6742"
```

Effect plugin:

```yaml
id: example_effects
compatibility:
  halod: ">=0.2.0"
  plugin_api: 1
type: effect
name: Example Effects
version: 1.0.0
license: GPL-3.0-or-later

effects:
  - id: plasma
    name: Plasma
    kind: pixmap
    params: []
```

## Top-level fields

| Field | Type | Default | Meaning |
|---|---|---:|---|
| `id` | string | required | Stable package ID; must equal the directory name. |
| `compatibility` | table | required | Supported daemon versions and exact plugin API generation. |
| `type` | enum | `device` | `device`, `integration`, or `effect`. |
| `name` | string | `id` | Display name. |
| `author` | string | empty | Author shown in the Plugins screen. |
| `version` | string | empty | Display version; semantic versioning is recommended. |
| `license` | string | empty | SPDX identifier or license name. |
| `description` | string | empty | Human-readable package summary. |
| `entry` | path | `main.lua` | Relative runtime Lua entry file. |
| `permissions` | array | `[]` | Privileges requiring user consent. |
| `devices` | object or array | `[]` | Hardware declarations for a device plugin. |
| `transports` | object | `{}` | HID, TCP, or USB-control configuration. |
| `logo` | filename | auto | Bare filename under `assets/`; `logo.png` is auto-detected. |
| `effect_assets` | array | `[]` | Optional thumbnails keyed to declared effect IDs. |
| `rgb`, `fan`, ... | object | absent | Device capability declarations. |
| `poll` | object | absent | Background status polling. |
| `chain` | object | absent | Hosted accessory channels and models. |
| `config` | object | absent | User-editable integration configuration. |
| `effects` | array | `[]` | Executable RGB effect declarations. |

Unknown YAML fields are not part of the API and must not be used for forward compatibility.

## Compatibility

Every directory package declares both compatibility dimensions:

```yaml
compatibility:
  halod: ">=0.2.0, <0.3.0"
  plugin_api: 1
```

`halod` is a Cargo-style semantic-version requirement matched against the running daemon.
`plugin_api` is matched exactly against the Lua plugin API generation. A package is rejected when
either dimension is malformed or incompatible.

Compatibility describes what the package actually supports. Increase `plugin_api` only when the
plugin has been migrated to that API generation; use an upper daemon bound when future daemon
releases are not known to be compatible.

## Plugin types

### `device`

The default type. It must declare at least one device and may declare transports, capabilities,
polling, chains, configuration, and effects.

### `integration`

An integration is instantiated from configuration rather than local hardware discovery. It must
not declare `devices` or root capabilities. It normally declares TCP and returns remote controller
descriptions from `enumerate_controllers`; those controller descriptions carry their own runtime
capabilities.

### `effect`

An effect plugin must declare at least one `effects` entry and must not declare devices or
transports. Its Lua callbacks perform pure rendering.

## Permissions

```yaml
permissions:
  - network
  - secure_storage
```

| Permission | Grants |
|---|---|
| `network` | TCP connections. Required when `transports.tcp` is declared. |
| `os` | Only `os.time()` and `os.clock()`; all other OS APIs remain unavailable. |
| `secure_storage` | Decrypted values for this plugin's secure config fields. |
| `smbus` | SMBus scanning and register access. Required by an SMBus device. |
| `audio_routing` | Creation and control of host audio sinks through `dev.audio`. |

A plugin with ungranted permissions remains installed but inert. Consent is pinned to a content
hash of the exact `plugin.yaml` and entry-script bytes, so editing either requires consent again.

Declare only permissions the runtime code uses.

## Device declarations

`devices` accepts one object or an array. Every device requires non-empty `vendor`, `model`, and
`transport` values.

```yaml
devices:
  - vendor: Example
    model: Keyboard K1
    name: Example K1
    device_type: keyboard
    transport: hid
    vid: 0x1234
    pids: [0x0001, 0x0002]
    usage_page: 0xff00
    usage: 1
    interface: 2
```

### Common fields

| Field | Default | Meaning |
|---|---:|---|
| `vendor` | required | Stable vendor identity. |
| `model` | required | Stable model identity. |
| `name` | `model` | Display-name override. |
| `device_type` | `other` | UI/device category. |
| `transport` | required | Backend used to discover and communicate with the device. |

Valid `device_type` values are `other`, `fan`, `hub`, `dongle`, `keyboard`, `mouse`, `headset`,
`monitor`, `gpu`, `led_strip`, `motherboard`, `ram`, `sensor`, `a_i_o`, and `speaker`.

### HID matching

| Field | Meaning |
|---|---|
| `vid`, `pid` | USB vendor and product ID. |
| `pids` | Product-ID family. A non-empty list takes precedence over `pid`. |
| `usage_page`, `usage` | Optional HID usage filters. |
| `interface` | Optional HID interface-number filter. |

### SMBus matching and scan scope

```yaml
permissions: [smbus]
devices:
  - vendor: Example
    model: SMBus RGB
    device_type: ram
    transport: smbus
    bus: chipset
    addresses: [0x58, 0x59, 0x5a, 0x5b]
    extra_addresses: [0x77]
    max_bytes_per_sec: 6000
    pre_scan: true
    probe: quick
```

| Field | Meaning |
|---|---|
| `bus` | `chipset` or `gpu`. |
| `addresses` | Addresses the scanner may probe and normal callbacks may access. |
| `extra_addresses` | Additional addresses available only to `pre_scan`. |
| `max_bytes_per_sec` | Optional bus traffic ceiling. |
| `pre_scan` | Run `pre_scan(dev)` before probing a matching bus. |
| `probe` | `quick` (default), `read_byte`, or `none`. |
| `pci_match` | Required PCI filters for a GPU bus. |

GPU PCI filters may contain `vendor`, `device`, `sub_vendor`, `sub_device`, and `confirmed`.
Missing identity fields are wildcards:

```yaml
pci_match:
  - vendor: 0x10de
    sub_vendor: 0x1043
    sub_device: 0x8872
    confirmed: true
```

## Transports

### HID

```yaml
transports:
  hid:
    report_size: 64
    timeout_ms: 1000
    feature_report: false
```

`report_size` is `0` for raw reports or `1..1024`; `timeout_ms` must be `1..60000`.
`feature_report` selects feature-report behavior for the normal stream backend.

### TCP

```yaml
permissions: [network]
transports:
  tcp:
    host_key: host
    port_key: port
    timeout_ms: 5000
    allow_private: true
```

TCP is valid only for an integration. `host_key` and `port_key` default to `host` and `port`, must
differ, and must name declared non-secure config fields. `timeout_ms` must be `1..60000`.
`allow_private` opts into loopback, private, and link-local destinations and defaults to `false`.

### USB control

```yaml
transports:
  usb_control:
    interface: 0
    endpoints:
      - id: lighting
        vid: 0x0cf2
        pid: 0xb201
        interface: 0
```

The matched device is control endpoint `""`. Entries under `endpoints` open secondary devices and
are addressed by `id` from Lua. Endpoint IDs must be unique and VID/PID must be non-zero.

## Capabilities

A capability is advertised by the presence of its YAML section. Runtime callbacks alone do not
create capabilities. Declaring a capability without implementing the operations it requires causes
runtime failures when those operations are used.

Stable `id` and `key` values are persistence identifiers; changing them loses saved state. Control
keys under `choice`, `range`, `boolean`, and `action` share one namespace.

### `rgb`: lighting zones and firmware effects

```yaml
rgb:
  zones:
    - id: ring
      name: Pump Ring
      topology:
        type: ring
      leds:
        - { id: 0, x: 0.50, y: 0.05 }
        - { id: 1, x: 0.73, y: 0.11 }
  native_effects:
    - id: rainbow
      name: Hardware Rainbow
      params: []
```

Zone fields:

| Field | Meaning |
|---|---|
| `id` | Stable zone ID passed to RGB callbacks and stored states. |
| `name` | Display name. |
| `topology` | `{type: ring}`, `{type: linear}`, `{type: grid}`, or `{type: rings, count: N}`. |
| `leds` | Ordered `{id, x, y}` entries with normalized `0..1` coordinates. |

LED array order is wire order for `write_frame`; positions are used for canvas sampling, effects,
per-LED editing, and previews. LED IDs are normally zero-based.

When topology is discovered from hardware, declare `zones: []` and return shorthand zones from
`initialize`: `{id, name, topology, led_count, rings?}`. That return value is runtime data, not a
second manifest.

`native_effects` describes effects implemented by device firmware. Each entry has `id`, `name`,
and parameter descriptors. The runtime implements `apply` and `write_frame`; see
[RGB callbacks](lua-api.md#capability-callbacks).

### `fan`: one direct fan or pump channel

```yaml
fan:
  channel: 0
```

`channel` defaults to `0`. The runtime implements `get_duty` and `set_duty` using `0..255` duty;
`get_rpm` is optional. This represents a fan or pump belonging directly to the device. Detachable
accessory fans belong under `chain`.

### `sensor`: telemetry

```yaml
sensor: {}
```

The empty marker enables sensor reporting through `get_sensors`. Runtime records contain `id`,
`name`, numeric `value`, `unit`, and normally `sensor_type`.

Units: `celsius`, `fahrenheit`, `percent`, `megahertz`, `hours`, `rpm`.

Types: `temperature`, `load`, `memory`, `frequency`, `uptime`, `fan_speed`, `fan_duty`.

Optional visibility is `visible`, `hidden`, or `disabled`. Use `poll` to cache transport reads when
several status capabilities share one hardware report.

### `lcd`: image panel

```yaml
lcd:
  needs_rgb_restore: true
```

`needs_rgb_restore` defaults to `false`; enable it when LCD uploads reset lighting. Panel geometry
is reported by `initialize` because it may depend on the matched device variant. The runtime
descriptor contains shape, width, height, supported rotations and image types, latching/raw-stream
policy, current brightness, and rotation. Runtime operations are `lcd_stream_frame`, `set_image`,
`lcd_set_brightness`, `lcd_set_rotation`, and `lcd_reset`; see the
[Lua API reference](lua-api.md#lifecycle-and-dynamic-identity).

### `dpi`: pointer sensitivity

```yaml
dpi:
  min: 100
  max: 26000
  steps: [800, 1600, 3200]
  onboard: false
```

`steps` must be non-empty, strictly increasing, and inside `min..max`. With `onboard: true`, steps
belong to the active hardware profile; otherwise the host owns and cycles them. The runtime applies
the selected value through `set_dpi`.

### `choice`: discrete selectors

```yaml
choice:
  choices:
    - key: poll_rate
      label: Polling Rate
      category: Mouse
      display: list
      options:
        - { id: "1000", label: 1000 Hz }
        - { id: "500", label: 500 Hz }
      default: 0
```

| Field | Default | Meaning |
|---|---:|---|
| `key`, `label`, `options` | required | Stable key, display label, and selectable options. |
| `category` | empty | UI grouping. |
| `display` | `inline` | `inline`, `list`, or two-option `toggle`. |
| `default` | `0` | Zero-based selected option index. |

The host caches selections and calls `set_choice` with a zero-based index. `initialize` may return
live selections under `choices` to replace defaults.

### `range`: bounded integer controls

```yaml
range:
  ranges:
    - key: brightness
      label: Brightness
      category: Display
      min: 0
      max: 100
      step: 5
      default: 50
      read_only: false
      display: slider
      start_label: Off
      end_label: Max
```

`min`, `max`, and `default` are required. `step` defaults to `1` and must be positive; the default
must be an in-range step from `min`. `display` is `slider` or `stepper`. Writable entries use
`set_range`; `initialize` may return live values under `ranges`.

### `boolean`: live toggles

```yaml
boolean:
  booleans:
    - key: angle_snap
      label: Angle Snap
      category: Mouse
    - key: connected
      label: Connected
      read_only: true
```

Definitions require `key` and `label`; `category` is optional and `read_only` defaults to `false`.
`get_booleans` returns live `{key, value}` records. Writable entries use `set_boolean`.

### `action`: stateless commands

```yaml
action:
  actions:
    - key: calibrate
      label: Calibrate
      category: Sensor
```

An action has no stored value. Invoking it calls `trigger_action`. Use it for explicit operations
such as calibration, identification, reset, or pixel refresh.

### `battery`: battery state

```yaml
battery: {}
```

The marker enables `get_batteries`. Runtime records contain `key`, `label`, `level` (`0..100`), and
`status` (`charging`, `discharging`, or `unknown`). A device may report multiple batteries.

### `connection`: link type

```yaml
connection: {}
```

The marker enables `connection_status`, which reports `wired`, `wireless`, or unknown. This drives
the link indicator and is separate from device presence.

### `equalizer`: presets and bands

```yaml
equalizer: {}
```

Presets and bands are live device state, so the manifest is an empty marker. Runtime operations are
`get_equalizer`, `set_eq_preset`, and `set_eq_bands`. Each band reports its index, label, bounds,
step, and current value; presets report identity and optional firmware/custom band data.

### `pairing`: receiver slots

```yaml
pairing: {}
```

The marker enables `start_pairing`, `stop_pairing`, `unpair`, and `pairing_status`. Runtime status
contains state (`idle`, `listening`, `paired`, or `error`), optional error text, maximum slots, and
occupied slot records. Pairing state alone does not create or remove child devices.

### `onboard_profiles`: firmware profiles

```yaml
onboard_profiles: {}
```

The marker enables profile switching, restore, enable/disable, and status callbacks. Slots are
1-based; runtime `active_slot: 0` means host mode. Each slot reports whether it is enabled, active,
and backed by a factory ROM default.

### `key_remap`: physical button mappings

```yaml
key_remap:
  buttons:
    - cid: 80
      label: Left Button
      divertable: true
      group: 1
  requires_host_mode: true
  default_mappings:
    - cid: 80
      base: { type: native }
      shifted: { type: native }
```

Button descriptors are fixed hardware metadata. `cid` is the device control ID; `divertable`
indicates host handling support; `group` identifies buttons sharing a mutually exclusive hardware
slot. Default mappings seed first-run state and reset behavior.

Runtime operations set and reset mappings. When `requires_host_mode` is true,
`key_remap_host_mode` reports whether mappings are currently active. Button-action types and
payloads are documented in the [Lua API reference](lua-api.md#capability-callbacks).

## Polling

```yaml
poll:
  interval_ms: 500
```

The daemon calls `read_status` on the device worker every interval, assigns its result to
`dev.status`, and lets sensor/fan/battery/control callbacks reuse that cached state. The default is
1000 ms and the accepted range is `100..60000`. Poll errors are logged and the loop continues.
Polling pauses while chain accessories are detected to avoid racing transport replies.

## Hosted accessory chains

```yaml
chain:
  channels:
    - id: "0"
      name: Accessory
      max_leds: 40
  accessories:
    - id: 19
      name: F120 RGB
      led_count: 8
      topology: ring
      fan: true
    - id: 27
      name: F240 RGB Core
      led_count: 16
      topology: rings
      rings: 2
      fan: true
```

Channels define stable `id`, display `name`, and composed `max_leds`. Accessories define a numeric
protocol `id`, `name`, `led_count`, topology (`ring` by default, `linear`, `grid`, or `rings`),
`rings` for multi-ring devices, and optional fan capability.

`detect_accessories` reports numeric channels and declared accessory IDs. HaloDaemon creates locked
children and composes their RGB into `write_ext_frame`. Fan accessories additionally use
`fan_rpm`, `fan_duty`, `fan_controllable`, and `set_fan_duty`.

When channels are learned from hardware, declare `channels: []` and return runtime
`{id, name, max_leds}` channel descriptions from `initialize`.

## Configuration

```yaml
config:
  fields:
    - key: host
      label: Server host
      kind: text
      default: 127.0.0.1
      category: Connection
    - key: port
      label: Server port
      kind: number
      default: "6742"
      min: 1
      max: 65535
    - key: token
      label: API token
      kind: text
      default: ""
      secure: true
```

| Field | Default | Meaning |
|---|---:|---|
| `key`, `label` | required | Stable setting key and display label. |
| `kind` | `text` | `text` or `number`. Lua still receives a string. |
| `default` | empty | String used until the user saves a value. |
| `category` | empty | UI grouping. |
| `secure` | `false` | Encrypt and mask the value. Requires `secure_storage` to read. |
| `min`, `max` | absent | Inclusive finite bounds for a number field. |

Only integration settings are currently editable in the GUI. Values are available at runtime under
`halod.config`. An invalid stored non-secret falls back to its default; an invalid secret is omitted.
TCP host/port fields must not be secure.

## Effects

Effects are declared entirely in `plugin.yaml`; Lua supplies only render callbacks.

```yaml
effects:
  - id: plasma
    name: Plasma
    kind: pixmap
    params:
      - id: speed
        label: Speed
        kind:
          kind: range
          min: 0.1
          max: 3.0
          step: 0.1
        default: 0.8
```

Each effect has stable `id`, display `name`, `kind` (`pixmap` or `direct`), and optional `params`.
It is registered as `<plugin-id>:<effect-id>`.

### Parameter kinds

Every parameter has `id`, `label`, a tagged `kind` object, and a type-compatible `default`.

```yaml
params:
  - id: amount
    label: Amount
    kind: { kind: range, min: 0.0, max: 1.0, step: 0.05 }
    default: 0.5
  - id: count
    label: Count
    kind: { kind: number, min: 1.0, max: 100.0 }
    default: 10.0
  - id: direction
    label: Direction
    kind: { kind: enum, options: [left, right] }
    default: right
  - id: color
    label: Color
    kind: { kind: color }
    default: { r: 255, g: 80, b: 0 }
  - id: enabled
    label: Enabled
    kind: { kind: boolean }
    default: true
  - id: title
    label: Title
    kind: { kind: text }
    default: Halo
  - id: source
    label: Sensor
    kind: { kind: sensor }
    default: ""
  - id: thresholds
    label: Thresholds
    kind: { kind: steps }
    default:
      - { value: 40.0, color: { r: 0, g: 255, b: 0 } }
      - { value: 80.0, color: { r: 255, g: 0, b: 0 } }
  - id: image
    label: Image
    kind: { kind: image }
    default: ""
```

Supported kinds are `range`, `number`, `enum`, `color`, `boolean`, `text`, `sensor`, `steps`, and
`image`. Numeric bounds/defaults must be finite and valid; range steps must be positive; enum
defaults must name one of the options.

Pixmap effects use `render_<id>` and direct effects use `led_colors_<id>`. When exactly one effect
is declared, bare `render` or `led_colors` is also accepted.

## Display assets

```yaml
logo: custom-logo.png
effect_assets:
  - id: plasma
    thumbnail: plasma.png
```

Asset values are bare filenames under `assets/`. If `logo` is omitted, `assets/logo.png` is selected
when present. Each effect asset ID must reference a declared effect.

Served assets are limited to 256 KiB. Logos are additionally limited to 512×512 pixels and a 2:1
maximum long-to-short aspect ratio. Invalid optional assets are ignored without disabling the
plugin.

## Validation and limits

The daemon validates YAML without executing Lua. Important rules include:

- IDs and keys use only `A-Z`, `a-z`, `0-9`, `.`, `_`, and `-` and are unique in their scope.
- `compatibility` is mandatory and must accept the running daemon and plugin API generation.
- Device plugins require devices; integrations reject devices/root capabilities; effect plugins
  require effects and reject devices/transports.
- TCP requires `network`; SMBus requires `smbus`.
- Control keys are unique across choice, range, boolean, and action sections.
- Collection sizes, LED counts, zone counts, LCD dimensions, text, files, and native allocations
  are bounded. Oversized declarations are rejected rather than truncated.
- Numeric defaults and bounds must be finite and internally consistent.
- Entry paths and asset names may not escape the package.

Validate packages with the current daemon build:

```powershell
halod plugin-test .\my_plugin
```

The harness parses and validates `plugin.yaml` before running an optional `test.lua`.
