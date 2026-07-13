# Plugin manifest reference

This reference describes the `plugin.yaml` format accepted by the current HaloDaemon source.
The YAML file owns package metadata, device matching, transport configuration, permissions, and
asset references. Runtime capabilities and callbacks are returned by the entry Lua file; see the
[Lua API reference](lua-api.md).

## Package layout

```text
my_plugin/
├── plugin.yaml
├── main.lua                 # or the file named by `entry`
├── test.lua                 # optional hardware-free test
└── assets/
    ├── logo.png             # automatically selected when present
    └── effect-preview.png
```

`id` must equal the package directory name. `plugin.yaml` and the entry script must be regular
files, not symlinks; `entry` must remain inside the package. The default entry is `main.lua`.

## Top-level fields

| Field | Type | Default | Meaning |
|---|---|---:|---|
| `id` | string | required | Stable ASCII identifier; must match the directory name. |
| `compatibility` | table | required | Supported HaloDaemon SemVer range and exact plugin API generation. |
| `type` | `device`, `effect`, `integration` | `device` | Discovery and execution model. |
| `name` | string | `id` | Display name. |
| `author` | string | empty | Author shown in the plugin UI. |
| `version` | string | empty | Display version; semantic versioning is recommended. |
| `license` | string | empty | SPDX identifier or license name. |
| `description` | string | empty | Human-readable summary. |
| `entry` | string | `main.lua` | Relative entry-script path. |
| `permissions` | string array | `[]` | Privileges requested from the user. |
| `devices` | device or device array | `[]` | Hardware declarations for a device plugin. |
| `transports` | table | `{}` | Transport-specific configuration. |
| `logo` | filename | auto | Bare filename under `assets/`; `logo.png` is auto-detected. |
| `effects` | array | `[]` | Display assets: `{ id, thumbnail }`, keyed to Lua effect IDs. |

The YAML values above override entry-script values with the same purpose. Put identity, devices,
permissions, and transport declarations in YAML so review and consent never require executing
untrusted Lua.

### Compatibility

Every package must declare both compatibility dimensions:

```yaml
compatibility:
  halod: ">=0.2.0"
  plugin_api: 1
```

`halod` is a Cargo-style SemVer requirement matched against the daemon release.
`plugin_api` is matched exactly against the Lua plugin API generation implemented
by that daemon. Both must match. Incompatible repository content is not offered
as an update, and an explicit update request cannot install it.

### Plugin kinds

- `device` requires at least one `devices` entry and may declare capabilities in Lua.
- `effect` requires at least one Lua `effects` entry and may not declare devices or transports.
- `integration` may not declare devices or root capabilities. It is instantiated from config,
  normally opens TCP, and reports child controllers dynamically.

## Permissions

| Value | Grants |
|---|---|
| `network` | TCP connections; required when `transports.tcp` is present. |
| `os` | Only `os.time()` and `os.clock()`; other OS functions remain unavailable. |
| `secure_storage` | Decrypted values of this plugin's `secure` config fields. |
| `smbus` | SMBus scanning and register operations; required by an SMBus device. |
| `audio_routing` | Creation and control of host audio sinks through `dev.audio`. |

A plugin with ungranted permissions remains installed but inert. Consent is tied to a content hash
of the exact YAML and entry-script bytes, so changing either requires consent again.

## Device declarations

Every device needs non-empty `vendor`, `model`, and `transport` values.

| Field | Applies to | Meaning |
|---|---|---|
| `vendor`, `model` | all | Stable identity strings. |
| `name` | all | Optional display-name override; defaults to `model`. |
| `device_type` | all | `other`, `fan`, `hub`, `dongle`, `keyboard`, `mouse`, `headset`, `monitor`, `gpu`, `led_strip`, `motherboard`, `ram`, `sensor`, `a_i_o`, or `speaker`. |
| `transport` | all | `hid`, `smbus`, or `usb_control`; `tcp` is integration-only. |
| `vid`, `pid` | HID/USB | USB vendor and product ID. |
| `pids` | HID | Product-ID family; a non-empty list takes precedence over `pid`. |
| `usage_page`, `usage`, `interface` | HID | Optional HID interface filters. |
| `bus` | SMBus | `chipset` or `gpu`. |
| `addresses` | SMBus | Addresses the scanner may probe and the worker may access. |
| `extra_addresses` | SMBus | Additional addresses available only during `pre_scan`. |
| `max_bytes_per_sec` | SMBus | Optional scan/write rate ceiling. |
| `pre_scan` | SMBus | Run Lua `pre_scan(dev)` before probing this bus. |
| `probe` | SMBus | `quick` (default), `read_byte`, or `none`. |
| `pci_match` | GPU SMBus | PCI filters with optional `vendor`, `device`, `sub_vendor`, `sub_device`, and `confirmed`. At least one is required for a GPU bus. |

Example:

```yaml
id: example_hid
compatibility:
  halod: ">=0.2.0"
  plugin_api: 1
name: Example HID Ring
author: Example Author
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
```

## Transport configuration

### HID

```yaml
transports:
  hid:
    report_size: 64       # 0 for raw; otherwise 1..1024
    timeout_ms: 1000      # 1..60000
    feature_report: false
```

`feature_report` selects feature-report behavior for the normal stream backend. The Lua API also
provides an explicit `feature_exchange` operation.

### TCP

TCP is valid only for an integration and requires `network` permission. `host_key` and `port_key`
must be different, non-secure config fields declared by the Lua manifest.

```yaml
type: integration
permissions: [network]
transports:
  tcp:
    host_key: host
    port_key: port
    timeout_ms: 5000
    allow_private: true
```

`allow_private` must be opted into for loopback, private, or link-local destinations.

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

The matched device is endpoint `""`; named secondary devices are selected by `id`. Endpoint IDs
must be unique and VID/PID must be non-zero.

## Lua-owned manifest sections

The entry file returns one table. These sections are intentionally defined there because they
describe runtime behavior implemented by callbacks.

| Section | Shape | Required callbacks |
|---|---|---|
| `rgb` | `{ zones, native_effects? }` | `apply`, `write_frame` as used by state/mode. |
| `fan` | `{ channel = 0 }` | `get_duty`, `set_duty`; `get_rpm` optional. |
| `sensor` | `{}` | `get_sensors`. |
| `lcd` | `{ needs_rgb_restore? }` | LCD callbacks matching advertised operations. |
| `dpi` | `{ min, max, steps, onboard? }` | `set_dpi`. |
| `choice` | `{ choices = {...} }` | `set_choice`. |
| `range` | `{ ranges = {...} }` | `set_range` unless read-only. |
| `boolean` | `{ booleans = {...} }` | `get_booleans`, `set_boolean` unless read-only. |
| `action` | `{ actions = {...} }` | `trigger_action`. |
| `battery` | `{}` | `get_batteries`. |
| `connection` | `{}` | `connection_status`. |
| `equalizer` | `{}` | `get_equalizer`, `set_eq_preset`, `set_eq_bands`. |
| `pairing` | `{}` | Pairing callbacks. |
| `onboard_profiles` | `{}` | Onboard-profile callbacks. |
| `key_remap` | `{ buttons, requires_host_mode?, default_mappings? }` | Key-remap callbacks. |
| `chain` | `{ channels, accessories? }` | `detect_accessories`, `write_ext_frame`, and fan-hub callbacks when applicable. |
| `poll` | `{ interval_ms = 1000 }` | `read_status`; interval must be 100..60000. |
| `config` | `{ fields = {...} }` | None; values appear in `halod.config`. |
| `effects` | effect array | `render_<id>` or `led_colors_<id>`. |

### RGB zones

Static `rgb.zones` use HaloDaemon's full `RgbZone` shape: `id`, `name`, `topology`, and `leds`
with normalized positions. For hardware whose LED count is learned at runtime, return shorthand
zones from `initialize`: `{ id, name, topology, led_count, rings? }`. Supported topologies are
`linear`, `ring`, `rings`, and `grid`.

### Controls

Choice entries contain `key`, `label`, `options = {{id, label}, ...}`, optional `category`,
`display` (`inline`, `list`, `toggle`), and zero-based `default`. Range entries contain `key`,
`label`, `min`, `max`, `default`, and optional `step`, `read_only`, `category`, `start_label`,
`end_label`, and `display` (`slider` or `stepper`). Boolean and action entries contain `key`,
`label`, and optional `category`; booleans may also be `read_only`.

Control keys share one namespace across choice, range, boolean, and action sections.

### Configuration fields

```lua
config = { fields = {
  { key = "host", label = "Server host", default = "127.0.0.1" },
  { key = "port", label = "Server port", kind = "number", default = "6742",
    min = 1, max = 65535 },
  { key = "token", label = "API token", secure = true },
} }
```

Fields support `key`, `label`, `kind` (`text` or `number`), string `default`, `category`, `secure`,
and numeric `min`/`max`. Values remain strings in Lua. Currently only integration settings are
editable in the GUI. Invalid stored values fall back to the default; invalid secrets are omitted.

## Effects and assets

Lua effect entries contain `kind` (`pixmap` or `direct`), `id`, `name`, and optional `params`.
Parameter kinds are `range`, `number`, `enum`, `color`, `boolean`, `text`, `sensor`, `steps`, and
`image`. Each parameter has `id`, `label`, `kind`, and a type-compatible `default`; numeric kinds
also define bounds (and `step` for a range), while enum defines `options`.

```lua
effects = {
  {
    kind = "pixmap", id = "plasma", name = "Plasma",
    params = {
      { id = "speed", label = "Speed",
        kind = { kind = "range", min = 0.1, max = 3.0, step = 0.1 },
        default = 0.8 },
    },
  },
}
```

Thumbnails are declared separately in YAML:

```yaml
effects:
  - id: plasma
    thumbnail: plasma.png
```

Asset references are bare filenames under `assets/`. Served assets are limited to 256 KiB. Logos
are additionally limited to 512×512 pixels and a 2:1 maximum aspect ratio; an invalid optional
asset is ignored without disabling the plugin.

## Validation checklist

- Use non-empty identifiers containing only `A-Z`, `a-z`, `0-9`, `.`, `_`, and `-`.
- Keep IDs unique within their section; control keys are unique across all control types.
- Declare `network` for TCP and `smbus` for SMBus.
- Keep HID sizes/timeouts and polling intervals inside the ranges documented above.
- Keep TCP host/port config non-secure; use `secure_storage` only for actual secrets.
- Ensure DPI steps are strictly increasing and inside `min`/`max`.
- Ensure defaults and effect parameters are finite and inside their declared bounds.
- Run `halod plugin-test <package-directory>` before committing.

The daemon enforces additional bounded collection and allocation limits. Treat validation errors as
authoritative rather than relying on permissive YAML parsing.
