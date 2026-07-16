# HaloDaemon official plugins

This repository contains the official device, integration, and effect packages
for [HaloDaemon](https://github.com/TimP4w/HaloDaemon). Plugins are data and Lua
packages loaded by the daemon; they are released independently from the core
source tree but are validated against one repository index.

[![Test plugins](https://github.com/TimP4w/HaloDaemon-plugins/actions/workflows/test-plugins.yml/badge.svg)](https://github.com/TimP4w/HaloDaemon-plugins/actions/workflows/test-plugins.yml)

## Plugin catalog

Each hardware protocol is documented by the package that implements it. The
manifest remains the authoritative device, platform, permission, and transport
catalog.

| Package | Hardware or service | Transport | Documentation |
|---|---|---|---|
| [`amd_smn`](amd_smn/) | AMD Zen-family CPU thermal sensors on Windows | AMD SMN | [Protocol](amd_smn/docs/protocol.md) |
| [`asus_aura_usb`](asus_aura_usb/) | ASUS Aura motherboard and addressable RGB zones | HID | [Protocol](asus_aura_usb/docs/protocol.md) |
| [`corsair_dram`](corsair_dram/) | Corsair Vengeance and Dominator DDR4/DDR5 RGB | SMBus | [Protocol](corsair_dram/docs/protocol.md) |
| [`ene_smbus`](ene_smbus/) | ENE-backed DRAM and GPU RGB controllers | SMBus | [Protocol](ene_smbus/docs/protocol.md) |
| [`halo_effects`](halo_effects/) | Stock pixmap and direct RGB effects | Effect API | [Callback contract](halo_effects/docs/protocol.md) |
| [`hwmon`](hwmon/) | Linux temperature sensors and motherboard fan headers | hwmon | [Integration behavior](hwmon/docs/protocol.md) |
| [`logitech`](logitech/) | Declared Logitech HID++ devices and receivers | HID | [Overview](logitech/docs/protocol.md), [HID++ 1.0](logitech/docs/hidpp1.md), [HID++ 2.0](logitech/docs/hidpp2.md) |
| [`logitech_g560`](logitech_g560/) | Logitech G560 speakers | HID | [Protocol](logitech_g560/docs/protocol.md) |
| [`nvidia`](nvidia/) | GPUs reported by `nvidia-smi` | Command | [Protocol](nvidia/docs/protocol.md) |
| [`nuvoton_lpcio`](nuvoton_lpcio/) | Nuvoton NCT67xx Super I/O on Windows | LPCIO | [Protocol](nuvoton_lpcio/docs/protocol.md) |
| [`nzxt_control_hub`](nzxt_control_hub/) | NZXT RGB & Fan Control Hub | HID | [Hub protocol](nzxt_control_hub/docs/protocol.md) |
| [`nzxt_kraken`](nzxt_kraken/) | NZXT Kraken Z/Elite LCD coolers | HID + USB | [Z/Elite protocol](nzxt_kraken/docs/protocol.md) |
| [`nzxt_kraken_x3`](nzxt_kraken_x3/) | NZXT Kraken X53/X63/X73 | HID | [X3 protocol](nzxt_kraken_x3/docs/protocol.md) |
| [`openrgb`](openrgb/) | Devices exposed by an OpenRGB SDK server | TCP | [SDK protocol](openrgb/docs/protocol.md) |
| [`philips_evnia`](philips_evnia/) | Philips Evnia 49M2C8900 controls and Ambiglow | USB | [Overview](philips_evnia/docs/protocol.md), [DDC/CI](philips_evnia/docs/ddc-ci.md), [Ambiglow](philips_evnia/docs/ambiglow.md) |
| [`steelseries_arctis`](steelseries_arctis/) | Arctis Nova Pro Wireless variants | HID | [Protocol](steelseries_arctis/docs/protocol.md) |

## Package layout

A device package normally looks like this:

```text
plugin-id/
├── plugin.yaml       manifest, authority, devices, and transports
├── main.lua          runtime implementation
├── test.lua          optional recording-based regression tests
├── docs/
│   └── protocol.md   protocol owned by this package
└── assets/            optional logos and effect thumbnails
```

Shared authoring contracts live at repository level:

- [Manifest reference](docs/manifest-reference.md)
- [Lua API and test harness](docs/lua-api.md)

Hardware wire details do not belong in the shared references. Put them under
the implementing package's `docs/` directory and link to the exact Lua code.
When related packages share a vendor, each package documents only the commands
it sends and parses; cross-link another package instead of copying its protocol.

## Authority and activation

Plugins are disabled until the user approves their normalized authority. The
manifest declares permissions and the narrow transport scope the daemon will
enforce: HID identities, USB devices and endpoints, SMBus addresses, commands,
or network access. Adding authority to an installed plugin requires renewed
consent.

Repository compatibility belongs only to [`repository.yaml`](repository.yaml).
Package manifests intentionally contain no compatibility override or legacy
transport shim.

## Testing

The repository index is generated; do not edit package hashes manually. From a
HaloDaemon checkout, refresh or verify it with:

```powershell
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- index . --version 2026.07.1
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- index . --check
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- validate .
```

Publication recomputes every package SHA-256 before signing the exact generated
`repository.yaml` bytes. A content change therefore cannot retain an old hash
or signature.

Run one package against the daemon's recording transports:

```powershell
halod plugin-test .\nzxt_kraken
```

`test.lua` drives the real Lua worker without host hardware and can inspect HID,
TCP, and scoped USB traffic. CI discovers and runs every package that includes a
test. Protocol changes should add or update byte-level assertions in the owning
package; physical smoke tests remain necessary for hardware timing, interface
claims, and firmware-specific behavior.

## Licensing

Package files carry SPDX headers. Several protocols build on GPL-licensed
reverse-engineering work, including

| Project | License | Used for |
|---------|---------|----------|
| [Solaar](https://github.com/pwr-Solaar/Solaar) | GPL-2.0-or-later | Logitech HID++ protocol |
| [liquidctl](https://github.com/liquidctl/liquidctl) | GPL-3.0 | NZXT Kraken protocol |
| [Linux kernel nzxt-smart2](https://github.com/torvalds/linux/blob/master/drivers/hwmon/nzxt-smart2.c) | GPL-2.0-or-later | NZXT Control Hub protocol |
| [OpenRazer](https://github.com/openrazer/openrazer) | GPL-2.0-or-later | Razer protocol |
| [linux-arctis-manager](https://github.com/elegos/Linux-Arctis-Manager) | GPL-3.0 | SteelSeries Arctis protocol |
| [evnia](https://github.com/tomasf/evnia) | MIT | Philips Evnia Ambiglow protocol |
| [g560-led](https://github.com/mijoe/g560-led) | MIT | Logitech G560 protocol |
| [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) | MPL-2.0 | NCT677x SuperIO register map, AMD Ryzen (Zen) SMN thermal decode |
| [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB) | GPL-2.0-or-later | ENE SMBus, ASUS Aura USB, Corsair DRAM |
