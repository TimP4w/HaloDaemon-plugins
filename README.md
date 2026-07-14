# HaloDaemon Plugins (official)

The official plugin repository for [HaloDaemon](https://github.com/TimP4w/HaloDaemon). The daemon
seeds a non-removable record for this repository and clones it at startup; a network failure on
first launch is logged and never blocks boot — the daemon simply has no official plugins until a
later successful clone.

Every release is an indexed repository: [`repository.yaml`](repository.yaml) is the sorted,
authoritative allowlist of package ids, paths, versions, and deterministic package digests. Halo
fetches Git objects separately from executable files, validates a complete revision, and atomically
selects that immutable revision only after validation succeeds. It never updates individual package
subtrees or changes the active revision while merely checking for updates.

Official releases also carry a detached `repository.sig` over the exact `repository.yaml` bytes.
The signing private key is kept outside this repository; see [repository releases](docs/repository-release.md).
Signing establishes provenance, not blanket execution authority: every disabled-to-enabled plugin
transition presents the complete normalized authority in Halo and needs a fresh confirmation.

Packages are normal directory packages (`plugin.yaml` + `main.lua`; see the
[manifest reference](docs/manifest-reference.md) and [Lua API reference](docs/lua-api.md)).
Repository compatibility belongs to `repository.yaml`; package manifests are inert catalogs for
their platforms, permissions, transport scopes, supported devices, and advertised capabilities.

## Supported devices

| Vendor | Model | VID:PID | Plugin | Protocol |
|--------|-------|---------|--------|----------|
| NZXT | Kraken Z53/63/73, Elite 2023, 2023, Elite V2, Plus 2024 | 1e71:3008, 300c, 300e, 3012, 3014 | [`nzxt_kraken`](nzxt_kraken/) | [NZXT](docs/protocols/nzxt.md) |
| NZXT | Kraken X53, X63, X73 | 1e71:2007, 2014 | [`nzxt_kraken_x3`](nzxt_kraken_x3/) | [NZXT](docs/protocols/nzxt.md) |
| NZXT | Control Hub (+ chained F-series fans) | 1e71:2022 | [`nzxt_control_hub`](nzxt_control_hub/) | [NZXT](docs/protocols/nzxt.md) |
| ASUS/ENE | SMBus RGB (DRAM, GPU) | — | [`ene_smbus`](ene_smbus/) | [ENE SMBus](docs/protocols/ene-smbus.md) |
| ASUS | Aura USB motherboard RGB (on-board zones + ARGB headers) | 0b05:1aa6, 18a3, 1866, 18a5, 18f3, 1867, 1872, 1939, 19af, 1a30, 1a6c, 1b3b, 1bed | [`asus_aura_usb`](asus_aura_usb/) | [Aura USB (OpenRGB)](https://gitlab.com/CalcProgrammer1/OpenRGB) |
| Corsair | Vengeance / Dominator DDR4/DDR5 DRAM RGB | — | [`corsair_dram`](corsair_dram/) | [Corsair DRAM](docs/protocols/corsair-dram.md) |
| Philips | Evnia 49M2C8900 (DDC/CI + Ambiglow) | 2109:8884, 0cf2:b201 | [`philips_evnia`](philips_evnia/) | [DDC/CI](docs/protocols/ddc-ci.md), [Philips Ambiglow](docs/protocols/philips-ambiglow.md) |
| SteelSeries | Arctis Nova Pro Wireless / Wireless X | 1038:12e0, 12e5, 225d | [`steelseries_arctis`](steelseries_arctis/) | [SteelSeries Arctis](docs/protocols/steelseries-arctis.md) |
| OpenRGB | Any device OpenRGB itself supports, via its SDK server | — | [`openrgb`](openrgb/) | [OpenRGB SDK](docs/protocols/openrgb.md) |
Plus [`halo_effects`](halo_effects/) — the stock library of pixmap/direct RGB effects and the
reference implementation of the effect-plugin API (not tied to any device).

## Testing

[![Test plugins](https://github.com/TimP4w/HaloDaemon-plugins/actions/workflows/test-plugins.yml/badge.svg)](https://github.com/TimP4w/HaloDaemon-plugins/actions/workflows/test-plugins.yml)

Every package with a `test.lua` is run in CI, without hardware, via `halod
plugin-test <package-dir>` (see
[.github/workflows/test-plugins.yml](.github/workflows/test-plugins.yml)).
Covered today: [`nzxt_kraken`](nzxt_kraken/), [`nzxt_kraken_x3`](nzxt_kraken_x3/),
[`nzxt_control_hub`](nzxt_control_hub/), [`asus_aura_usb`](asus_aura_usb/),
[`steelseries_arctis`](steelseries_arctis/), and [`openrgb`](openrgb/) — the
harness currently only drives `hid`/`tcp`-transport device plugins; see
the [test harness section](docs/lua-api.md#testlua-harness) for its API and limitations.

## Licensing

Each package's `plugin.yaml`/`main.lua` carries its own SPDX header — several device protocols
here were reverse-engineered against prior open-source work ([liquidctl](https://github.com/liquidctl/liquidctl),
[OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB), the Linux [`nzxt-smart2`](https://github.com/torvalds/linux/blob/master/drivers/hwmon/nzxt-smart2.c)
driver, [tomasf/evnia](https://github.com/tomasf/evnia),
[linux-arctis-manager](https://github.com/elegos/Linux-Arctis-Manager)) and are licensed accordingly
(GPL-2.0-or-later or GPL-3.0-or-later); everything else defaults to GPL-3.0-or-later. See
[REUSE.toml](REUSE.toml) and [LICENSES/](LICENSES/).
