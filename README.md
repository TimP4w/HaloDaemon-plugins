# HaloDaemon official plugins

This repository contains the official device, integration, and effect packages
for [HaloDaemon](https://github.com/TimP4w/HaloDaemon). Plugins are data and Lua
packages loaded by the daemon; they are released independently from the core
source tree but are validated against one repository index.

[![Test plugins](https://github.com/TimP4w/HaloDaemon-plugins/actions/workflows/test-plugins.yml/badge.svg)](https://github.com/TimP4w/HaloDaemon-plugins/actions/workflows/test-plugins.yml)

## Plugin catalog

Each hardware protocol is documented by the package that implements it. The
manifest remains the authoritative device, platform, and transport
catalog.

| Package | Hardware or service | Transport | Documentation |
|---|---|---|---|
| [`amd_smn`](amd_smn/) | AMD Zen-family CPU thermal sensors on Windows | AMD SMN | [Protocol](amd_smn/docs/protocol.md) |
| [`asus_aura_usb`](asus_aura_usb/) | ASUS Aura motherboard and addressable RGB zones | HID | [Protocol](asus_aura_usb/docs/protocol.md) |
| [`corsair_dram`](corsair_dram/) | Corsair Vengeance and Dominator DDR4/DDR5 RGB | SMBus | [Protocol](corsair_dram/docs/protocol.md) |
| [`ene_smbus`](ene_smbus/) | ENE-backed DRAM and GPU RGB controllers | SMBus | [Protocol](ene_smbus/docs/protocol.md) |
| [`halo_effects`](halo_effects/) | Stock pixmap and direct RGB effects | Effect API | [Callback contract](halo_effects/docs/protocol.md) |
| [`halo_lcd`](halo_lcd/) | Stock LCD widgets and presets | LCD widget API | [Rendering contract](halo_lcd/docs/protocol.md), [Lua API](docs/lua-api.md#lcd-widget-api) |
| [`hwmon`](hwmon/) | Linux temperature sensors and motherboard fan headers | hwmon | [Integration behavior](hwmon/docs/protocol.md) |
| [`hue`](hue/) | Philips Hue lights via a local bridge (CLIP v2) | HTTPS | [Protocol](hue/docs/protocol.md) |
| [`logitech`](logitech/) | Declared Logitech HID++ devices and receivers | HID | [Overview](logitech/docs/protocol.md), [HID++ 1.0](logitech/docs/hidpp1.md), [HID++ 2.0](logitech/docs/hidpp2.md) |
| [`nanoleaf`](nanoleaf/) | Nanoleaf light-panel controllers | HTTP + UDP | [Protocol](nanoleaf/docs/protocol.md) |
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

## What a plugin can reach

A plugin can only use what its manifest declares: its HID identities, USB
devices and endpoints, SMBus addresses, commands, or network transports. The
daemon enforces those scopes and shows the user what each plugin uses. Plugins
are installed, enabled and updated one at a time.

Each package carries its own semver `version` and the plugin `api` it targets
(see the [manifest reference](docs/manifest-reference.md#plugin-api-version)).

## Publishing

Every push to `main` runs the package tests, then publishes the repository to
GitHub Pages as a signed catalog:

```text
catalog.yaml                     signature line + index of every package
licenses.txt
packages/<id>-<version>.tar.gz   one immutable archive per package version
```

The catalog keeps the newest version of each package for every `api` value it
has published, so older HaloDaemon releases still find a compatible build.
Publishing fails if a package's content changed while its `version` did not.
Users add the repository by its catalog URL,
`https://timp4w.github.io/HaloDaemon-plugins/catalog.yaml`.

To check a change the same way CI does, from a HaloDaemon checkout:

```powershell
python scripts/generate-licenses.py --check
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- catalog . --out $env:TEMP\catalog --name "dry run" --previous https://timp4w.github.io/HaloDaemon-plugins/catalog.yaml --trusted-key halodaemon-official-2026=tjbwm5X4f70e+soVNV1AfRyb/TtnEsNNl+93YMO6IhQ=
```

Third-party repositories can reuse the publish workflow with their own key.
HaloDaemon pins a signed repository's key the first time it is added and
rejects a catalog signed by any other key; changing keys means removing and
re-adding the repository. Generate a key with:

```powershell
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- keygen example-repository-2026
```

Store `private_seed_b64` as the `HALOD_PLUGIN_SIGNING_KEY_B64` secret of the
`github-pages` environment and never commit it. The first publish has no
previous catalog: run the Publish workflow by hand with `bootstrap` checked.

Run one package against the daemon's recording transports:

```powershell
halod plugin-test .\nzxt_kraken
```

`test.lua` drives the real Lua worker without host hardware and can inspect HID,
TCP, and scoped USB traffic. CI discovers and runs every package that includes a
test. Protocol changes should add or update byte-level assertions in the owning
package; physical smoke tests remain necessary for hardware timing, interface
claims, and firmware-specific behavior.

For those smoke tests, run the daemon against this working tree instead of the
published catalog:

```powershell
halod --dev-plugins .
# or, so a daemon launched by the GUI picks it up:
$env:HALOD_DEV_PLUGINS = (Resolve-Path .); halod-gui
```

Only packages in that folder load: the official and any other repository are
neither loaded nor fetched for the session, and the saved repository list is
left untouched. Enabled plugins and their settings are shared with the normal
setup, so a local package with an already-enabled id starts right away. Stop
any running daemon first; only one instance can own the devices.

## Licensing

Package files carry SPDX headers. Several protocols build on open-source
projects, including

| Project | License | Used for |
|---------|---------|----------|
| [Solaar](https://github.com/pwr-Solaar/Solaar) | GPL-2.0-or-later | Logitech HID++ protocol |
| [liquidctl](https://github.com/liquidctl/liquidctl) | GPL-3.0 | NZXT Kraken protocol |
| [Linux kernel nzxt-smart2](https://github.com/torvalds/linux/blob/master/drivers/hwmon/nzxt-smart2.c) | GPL-2.0-or-later | NZXT Control Hub protocol |
| [OpenRazer](https://github.com/openrazer/openrazer) | GPL-2.0-or-later | Razer protocol |
| [linux-arctis-manager](https://github.com/elegos/Linux-Arctis-Manager) | GPL-3.0 | SteelSeries Arctis protocol |
| [evnia](https://github.com/tomasf/evnia) | MIT | Philips Evnia Ambiglow protocol |
| [g560-led](https://github.com/mijoe/g560-led) | MIT | Logitech G560 zone layout |
| [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) | MPL-2.0 | NCT677x SuperIO register map, AMD Ryzen (Zen) SMN thermal decode |
| [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB) | GPL-2.0-or-later | ENE SMBus, ASUS Aura USB, Corsair DRAM |

`licenses.txt` is generated from each `plugin.yaml` license and the SPDX
license/copyright declarations in that package, and published beside the
catalog. It deliberately shows both when they differ, such as the
GPL-3.0-or-later Logitech plugin and its GPL-2.0-or-later Solaar-derived source.
Regenerate it with `python scripts/generate-licenses.py`; CI fails when it is
stale.
