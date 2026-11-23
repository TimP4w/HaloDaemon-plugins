<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# NZXT Kraken firmware effects (`2A 04`)

One 64-byte report per channel starts an effect that the firmware runs on its own. Shared by `nzxt_kraken` and `nzxt_kraken_x3` (`lib/effects.lua`). Channel bytes: Kraken Z/Elite ring `0x01`, chain `0x02`; Kraken X3 external `0x01`, ring `0x02`, logo `0x04`.

| Offset | Meaning |
| --- | --- |
| 0..1 | `2A 04` |
| 2, 3 | channel byte, repeated |
| 4 | mode |
| 5..6 | speed, u16 LE (firmware ticks; smaller is faster) |
| 7..54 | up to 16 colours, G,R,B |
| 55 | `direction << 1 \| moving` (direction 1 = backward) |
| 56 | colour count |
| 57 | effect constant (see table) |
| 58 | LED count of the channel (sum of the chained accessories) |
| 59 | effect length, `3` unless set |

The static logo packet is the same report with mode `0x00`.

| Effect | Mode | Speeds, slowest → fastest | Colours | Byte 57 |
| --- | --- | --- | --- | --- |
| Fading | `0x01` | 80, 60, 40, 20, 10 | list | 8 |
| Spectrum Wave | `0x02` | 350, 300, 250, 150, 80 | none, direction | 0 |
| Covering Marquee | `0x04` | 350, 300, 250, 150, 80 | list, direction | 0 |
| Alternating | `0x05` | 1600, 1300, 1000, 800, 600; moving 800, 700, 500, 400, 300 | 2, direction, moving | 0 |
| Pulse | `0x06` | 25, 20, 15, 7, 4 | list | 8 |
| Breathing | `0x07` | 40, 30, 20, 10, 4 | list | 8 |
| Candle | `0x08` | fixed 50 | 1 | 0 |
| Starry Night | `0x09` | 25, 20, 15, 7, 4 | 1 | 0 |
| Rainbow Flow | `0x0B` | 350, 300, 250, 150, 80 | none, direction | 0 |
| Super Rainbow | `0x0C` | 350, 300, 250, 150, 80 | none, direction | 0 |
| Rainbow Pulse | `0x0D` | 350, 300, 250, 150, 80 | none, direction | 0 |
| Tai Chi | `0x0E` | 50, 40, 30, 20, 10 | 2, direction | 5 |
| Water Cooler | `0x0F` | 50, 40, 30, 20, 10 | 2 | 5 |
| Swish | `0x10` | 20, 15, 10, 7, 4 | 1 | 4 |

Fixed colour, breathing with fixed colours, marquee and wave have no firmware mode; they are rendered on the host and sent as per-LED frames. The firmware answers each report with an `FF 01` echo like any other lighting write.

Breathing, Fading, Pulse and Covering Marquee take a colour list in the vendor software, which encodes up to 16 colours; the per-effect maximum and the meaning of byte 57 were not determined, and the plugins send one or two colours.
