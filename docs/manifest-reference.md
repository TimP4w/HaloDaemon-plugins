# Plugin manifest reference

`plugin.yaml` is a plugin's inert catalog. HaloDaemon reads and validates it
without executing Lua. Repository compatibility and package hashes live only in
the repository-root `repository.yaml`.

```text
my_plugin/
├── plugin.yaml
├── main.lua
└── assets/
```

The directory name and `id` must match. Package files, including `plugin.yaml`
and `main.lua`, must be regular files inside the package.

## Device plugin

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
      hid:
        vid: 0x1234
        pid: 0x5678

transports:
  hid:
    report_size: 64
    timeout_ms: 1000
```

Lua implements `discover(host)`, `initialize(device)`, capability operations,
`children()`, `on_event(event)`, and `close()`. `initialize` returns runtime
identity, descriptors, and initial values. A package may only return
capabilities listed in `capabilities`; malformed runtime descriptors are
discarded individually rather than disabling valid siblings.

## Catalog fields

| Field | Meaning |
|---|---|
| `id` | Required stable package ID, equal to the package directory name. |
| `type` | `device` (default), `integration`, or `effect`. |
| `name`, `author`, `version`, `license`, `description` | Display metadata. |
| `entry` | Relative Lua entry path; defaults to `main.lua`. |
| `platforms` | Optional supported platforms: `linux`, `windows`, `macos`. Unsupported packages stay visible and inert. |
| `permissions` | Consent-gated host privileges. |
| `capabilities` | Union of runtime capability identifiers the package may expose. |
| `devices` | Device catalog entries for a device plugin. |
| `transports` | Scoped transport configuration. |
| `config` | User configuration and secret metadata. |
| `effects`, `effect_assets`, `logo` | Effect and display metadata. |

There is no `compatibility` field, no flat `transport` device field, no static
capability sections, no polling declaration, and no command templates or
argument schemas.

## Device matches

Every device has exactly one nested `match` key. Concrete identifiers are
unique across the package. Generic matching is always explicit.

```yaml
devices:
  - vendor: Example
    model: RGB DRAM
    type: ram
    match:
      smbus:
        bus: chipset
        addresses: [0x58, 0x59]
        extra_addresses: [0x77]
        pre_scan: true
        probe: quick
```

Supported match kinds are:

- `hid`: `vid`, `pid` or `pids`, plus optional `usage_page`, `usage`, and
  `interface`. Use `hid: { any: true }` only for intentional generic support.
- `smbus`: `bus`, concrete `addresses`, and optional scan limits. GPU matches
  additionally use explicit `pci_match` entries.
- `hwmon`: only the explicit generic form `hwmon: { any: true }`.
- `command`: an exact executable name, for example `command: nvidia-smi`.
- `amd_smn`: only the explicit generic form `amd_smn: { any: true }`.
- `lpcio`: concrete `chip_ids`, or the explicit generic form `lpcio: { any: true }`.

## Permissions and transports

Permissions form the consent request: `hid`, `smbus`, `hwmon`, `lpcio`,
`amd_smn`, `command`, `network`, `secure_storage`, and `audio_routing`.
Hardware matches require their corresponding privileged permission. TCP requires
`network` and command transport requires `command`.

```yaml
permissions: [command]
capabilities: [sensors]
devices:
  - vendor: NVIDIA
    model: Any GPU reported by nvidia-smi
    type: gpu
    match:
      command: nvidia-smi
transports:
  command:
    commands: [nvidia-smi]
```

Executable names are bare names, not paths or shell expressions. Each command
match must be listed in `transports.command.commands`. The daemon executes them
directly with bounded argv, timeout, and output; Lua never gets a shell.

HID, TCP, and USB-control use the existing scoped configuration:

```yaml
transports:
  hid: { report_size: 64, timeout_ms: 1000 }
  # tcp: { host_key: host, port_key: port, timeout_ms: 5000 }
```

## Consent and updates

Disabling is immediate. Every later enable opens the consent modal and submits
the authority snapshot displayed there. HaloDaemon compares that snapshot with
the current manifest before atomically enabling the package. A repository update
only disables enabled packages whose requested authority expands beyond the
last accepted authority.

Repository updates and repair are repository-wide actions. An active revision
is immutable; package content hashes are update/dirty detection data, not a
consent mechanism.

## Effects and configuration

Effect metadata and configuration are declarative and remain safe to load
without Lua execution. Effect entries have stable IDs, names, kinds, and typed
parameters. Configuration fields have stable keys, display labels, optional
numeric bounds, categories, and `secure: true` for values protected by the
secret store.

Use `halod plugin-test <package-directory>` to validate a package and run its
optional hardware-free test script.
