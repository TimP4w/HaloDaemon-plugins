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
| [`halo_lcd`](halo_lcd/) | Stock LCD widgets and presets | LCD widget API | [Lua API](docs/lua-api.md#lcd-widget-api) |
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
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- index . --version 2026.7.1
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- index . --check
python scripts/generate-licenses.py
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- validate .
```

Publication recomputes every package SHA-256 and the generated `licenses.txt`
SHA-256 before signing the exact `repository.yaml` bytes. A package or license
notice change therefore cannot retain an old hash or signature.

Third-party repositories can use the same optional trust-on-first-use format:
`halod-plugin-signing sign` writes the Ed25519 public key and key id into the
canonical `repository.yaml`, then signs those exact bytes as `repository.sig`.
HaloDaemon pins that advertised key on first import and rejects later key
changes. The official repository remains a special case authenticated by the
keys built into HaloDaemon.

The advertised public key is a top-level block in the repository root's
`repository.yaml`; it does not belong in any package's `plugin.yaml`:

```yaml
signing_key:
  id: example-repository-2026
  algorithm: ed25519
  public_key: "<base64-encoded raw 32-byte Ed25519 public key>"
```

`public_key` is Base64 of the raw 32-byte Ed25519 public key, not PEM and not a
path. Do not commit the matching private seed. Generate a key and let the tool
populate the block and `repository.sig`:

```powershell
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- keygen example-repository-2026
$env:HALOD_PLUGIN_SIGNING_KEY_B64 = '<private_seed_b64>'
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- index . --version 2026.7.1
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- sign . --key-id example-repository-2026
```

Commit `repository.yaml` and `repository.sig`. Keep the key id stable: after the
first successful import HaloDaemon pins the advertised key, and any later key
addition, removal, or replacement requires users to remove and re-import the
repository.

To test this locally, do not start HaloDaemon with `--dev-plugin-repo`: that is
an intentionally unverified working-tree override and always appears as a
development source. Run `index` and `sign`, commit the resulting
`repository.yaml`, `repository.sig`, and package changes, then import the
checkout through **Local Git folder**. Local Git import reads the committed
`HEAD`, not uncommitted edits. Remove an earlier unsigned registration before
re-importing, because HaloDaemon will not silently add or replace a repository's
pinned first-import key.

A public key block alone is never sufficient. `repository.sig` must name the
same key id and must be produced from the matching private seed over the exact
committed `repository.yaml` bytes. Run `halod-plugin-signing validate .` before
signing; package id, version, or hash mismatches make the repository invalid.

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

Publication generates `licenses.txt` from each `plugin.yaml` license and the
SPDX license/copyright declarations in that package. This deliberately shows
both when they differ, such as the GPL-3.0-or-later Logitech plugin and its
GPL-2.0-or-later Solaar-derived source. Development CI generates a temporary
copy to validate the source data without committing the release artifact.
