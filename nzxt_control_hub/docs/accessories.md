<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# NZXT V2 accessory catalogue

Accessory IDs reported in the `21 03` lighting-info reply, shared by the NZXT Kraken, Kraken X3 and RGB & fan controller packages (`lib/accessories.lua`). The `21 03` layout and the pump-head IDs were cross-checked against a live Kraken Elite V2.

## `21 03` layout

| Offset | Meaning |
| --- | --- |
| 14 | Channel count (some firmware leaves it `0`, meaning one channel) |
| `15 + 6*ch + slot` | Accessory ID, six slots per channel, `0` = empty |

Elite V2 example: count `2`, channel 0 slot 0 = `0x1E` (its own pump ring), channel 1 slot 0 = `0x1D` (an F360 RGB Core). Cooler plugins skip the pump head's own IDs (16, 17, 18, 30, 38) when looking for the radiator-fan chain.

## IDs

Rings: multi-fan frames (240/280 = 2, 360/420 = 3) split their LEDs evenly per fan. Fan: the accessory sits on a fan header and can take that header's cooling channel.

| ID | Name | LEDs | Layout | Fan |
| --- | --- | --- | --- | --- |
| 1 | HUE+ LED Strip | 10 | linear | |
| 2 | Aer RGB | 8 | ring | yes |
| 4 / 5 / 6 | HUE 2 LED Strip | 10 / 8 / 6 | linear | |
| 7 / 8 | HUE 2 Cable Comb | 18 / 14 | linear | |
| 9 / 10 | HUE 2 Underglow 300 / 200 mm | 15 / 10 | linear | |
| 11 / 12 | Aer RGB 2 120 / 140 mm | 8 | ring | yes |
| 13 / 14 / 15 | Vertagear chair head / head / bottom | 10 / 40 / 10 | linear | |
| 16 / 17 | Kraken X3 ring / logo | 8 / 1 | ring / linear | built-in |
| 18 | Kraken 120 | 9 | ring | built-in |
| 19 / 20 | F120 / F140 RGB | 18 | ring | yes |
| 21 / 22 | F120 / F140 RGB Duo | 20 | ring | yes |
| 23 / 24 | F120 / F140 RGB Core | 8 | ring | yes |
| 25 / 26 | F120 / F140 RGB Core (case) | 8 | ring | yes |
| 27 / 28 | F240 / F280 RGB Core | 16 | 2 rings | yes |
| 29 / 31 | F360 / F420 RGB Core | 24 | 3 rings | yes |
| 30 | Kraken Elite V2 ring | 24 | ring | built-in |
| 32 / 33 | Performance Fan 120 / 140 mm | 16 | linear | yes |
| 34 / 35 / 36 | Performance Fan 240 / 280 / 360 mm | 24 / 24 / 32 | linear | yes |
| 38 | Kraken Core | 19 | linear | built-in |
| 39 / 40 | N9 Z890 cover | 49 / 31 | linear | |
| 41 / 42 | F240 / F360 RGB Core (EV) | 16 / 24 | 2 / 3 rings | yes |
| 43 | RGB Case Fan 360 mm | 24 | 3 rings | yes |
| 44 / 45 | Ultra RGB Fan 120 / 140 mm | 32 | ring | yes |
| 46 / 47 | Ultra RGB Fan 240 / 280 mm | 64 | 2 rings | yes |
| 48 / 50 | Ultra RGB Fan 360 / 420 mm | 96 | 3 rings | yes |
| 49 | N9 X870E cover | 17 | linear | |
| 51 / 52 | F120 / F140 RGB Fan (2026) | 8 | ring | yes |
| 53 / 54 | F240 / F280 RGB Fan (2026) | 16 | 2 rings | yes |
| 55 / 56 | F360 / F420 RGB Fan (2026) | 24 | 3 rings | yes |
| 62 / 63 | F360 / F420 RGB Reverse Fan (2026) | 24 | 3 rings | yes |
| 64 / 65 | F360 / F420 RGB Fan (2026, rev. 2) | 24 | 3 rings | yes |
| 66 / 67 | F120 / F140 RGB Fan (2026, rev. 2) | 8 | ring | yes |
| 68 / 69 | F360 / F420 RGB Reverse Fan (2026, rev. 2) | 24 | 3 rings | yes |

An accessory whose LED count exceeds the channel budget (40 on Kraken and Smart Device V2 headers) is not attached.
