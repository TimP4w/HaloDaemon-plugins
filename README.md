# HaloDaemon Plugins (official)

The official plugin repository for [HaloDaemon](https://github.com/TimP4w/HaloDaemon). The daemon
seeds a non-removable record for this repository and clones it at startup; a network failure on
first launch is logged and never blocks boot — the daemon simply has no official plugins until a
later successful clone.

Every plugin here is a normal directory package (`plugin.yaml` + `main.lua`, see
[docs/plugins.md](https://github.com/TimP4w/HaloDaemon/blob/main/docs/plugins.md) in the main
repo for the package format and the Lua plugin API) — this repo carries **no special trust**
beyond being pre-registered. Installing, enabling, and updating any plugin here goes through the
same consent/permission flow as a community-repo plugin: nothing is auto-granted.

## Supported devices

| Vendor | Model | VID:PID | Plugin | Protocol |
|--------|-------|---------|--------|----------|
| NZXT | Kraken Z53/63/73, Elite 2023, 2023, Elite V2, Plus 2024 | 1e71:3008, 300c, 300e, 3012, 3014 | [`nzxt_kraken`](nzxt_kraken/) | [NZXT](docs/protocols/nzxt.md) |
| NZXT | Kraken X53, X63, X73 | 1e71:2007, 2014 | [`nzxt_kraken_x3`](nzxt_kraken_x3/) | [NZXT](docs/protocols/nzxt.md) |
| NZXT | Control Hub (+ chained F-series fans) | 1e71:2022 | [`nzxt_control_hub`](nzxt_control_hub/) | [NZXT](docs/protocols/nzxt.md) |
| ASUS/ENE | SMBus RGB (DRAM, GPU) | — | [`ene_smbus`](ene_smbus/) | [ENE SMBus](docs/protocols/ene-smbus.md) |
| Corsair | Vengeance / Dominator DDR4/DDR5 DRAM RGB | — | [`corsair_dram`](corsair_dram/) | [Corsair DRAM](docs/protocols/corsair-dram.md) |
| Philips | Evnia 49M2C8900 (DDC/CI + Ambiglow) | 2109:8884, 0cf2:b201 | [`philips_evnia`](philips_evnia/) | [DDC/CI](docs/protocols/ddc-ci.md), [Philips Ambiglow](docs/protocols/philips-ambiglow.md) |
| OpenRGB | Any device OpenRGB itself supports, via its SDK server | — | [`openrgb`](openrgb/) | [OpenRGB SDK](docs/protocols/openrgb.md) |

Plus [`halo_effects`](halo_effects/) — the stock library of pixmap/direct RGB effects and the
reference implementation of the effect-plugin API (not tied to any device).

## Testing

[![Test plugins](https://github.com/TimP4w/HaloDaemon-plugins/actions/workflows/test-plugins.yml/badge.svg)](https://github.com/TimP4w/HaloDaemon-plugins/actions/workflows/test-plugins.yml)

Every package with a `test.lua` is run in CI, without hardware, via `halod
plugin-test <package-dir>` (see
[.github/workflows/test-plugins.yml](.github/workflows/test-plugins.yml)).
Covered today: [`nzxt_kraken`](nzxt_kraken/), [`nzxt_kraken_x3`](nzxt_kraken_x3/),
[`nzxt_control_hub`](nzxt_control_hub/) — the harness currently only drives
`hid`/`tcp`-transport device plugins; see
[docs/plugins.md](https://github.com/TimP4w/HaloDaemon/blob/main/docs/plugins.md#testing-a-package-without-hardware)
in the main repo for the harness API.

## Licensing

Each package's `plugin.yaml`/`main.lua` carries its own SPDX header — several device protocols
here were reverse-engineered against prior open-source work ([liquidctl](https://github.com/liquidctl/liquidctl),
[OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB), the Linux [`nzxt-smart2`](https://github.com/torvalds/linux/blob/master/drivers/hwmon/nzxt-smart2.c)
driver, [tomasf/evnia](https://github.com/tomasf/evnia)) and are licensed accordingly
(GPL-2.0-or-later or GPL-3.0-or-later); everything else defaults to GPL-3.0-or-later. See
[REUSE.toml](REUSE.toml) and [LICENSES/](LICENSES/).
