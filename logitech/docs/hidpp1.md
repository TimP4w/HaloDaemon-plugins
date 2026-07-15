# HID++ 1.0 — register protocol

The older, **register-based** half of [HID++](protocol.md). A flat address space of 9-bit *registers* read/written with sub-IDs `0x80`–`0x83`. Used by every Unifying/Lightspeed receiver for pairing, device lists, and connection notifications. The separately packaged [G560 plugin](../../logitech_g560/docs/protocol.md) uses a related fixed vendor-report format. Modern feature-based devices use [HID++ 2.0](hidpp2.md) instead.

Code: [`main.lua`](../main.lua) contains the messenger, receiver operations, and register constants. See [protocol.md](protocol.md) for the shared frame format. Historical Rust symbol names are retained below for continuity with the original notes.

**Credits:** Solaar (GPL-2.0-or-later) — `hidpp10.py`, `receiver.py` by Daniel Pavel and contributors.

---

## Packet shape

A register access is a **short (7-byte) report** (`build_packet`, see [protocol.md](protocol.md) for the report sizes):

```
byte 0    0x10                report ID (HIDPP_SHORT)
byte 1    dd                  device number (0xFF = receiver itself; 1–6 = paired slot)
byte 2    sub-ID              0x80/0x81/0x82/0x83 (write/read × register bit 9)
byte 3    addr                register address low byte (R & 0xFF)
byte 4-6  p0 p1 p2            params, zero-padded to 7 bytes
```

A short register request's *reply* mirrors the reply payload size, not the request: the device-count register `0x0002` answers on the short collection, while the pairing-record register `0x02B5` answers with a long report on the long collection. The host reads both and matches by `(devnum, sub-ID)` — see [protocol.md](protocol.md).

---

## 1. Register access

Sub-ID encodes direction and register bit 9 (`HidppMessenger::hidpp10_read` / `hidpp10_write`, wrapped by `Hidpp10::read`/`write`). For register `R`: `sub_id = base | ((R >> 8) & 0x02)`, address = `R & 0xFF`, params padded to 3 bytes, **short report**.

| Op | Sub-ID base | Bytes sent | Notes |
|----|-------------|-----------|-------|
| Write, reg bit9=0 | `0x80` | `10 dd 80 <addr> p0 p1 p2` | fire-and-forget |
| Read,  reg bit9=0 | `0x81` | `10 dd 81 <addr> p0 p1 p2` | awaits reply |
| Write, reg bit9=1 | `0x82` | `10 dd 82 <addr> p0 p1 p2` | |
| Read,  reg bit9=1 | `0x83` | `10 dd 83 <addr> p0 p1 p2` | |

Registers (`v1/mod.rs`):

| Register | Const | Use |
|----------|-------|-----|
| `0x0002` | `REG_DEVICE_COUNT` | write `[0x02]` → receiver re-broadcasts connect status; read → paired count in reply **byte 1** |
| `0x02B5` | `REG_RECEIVER_INFO` | pairing records; sub-param `INFO_PAIRING 0x20` / `INFO_EXTENDED_PAIRING 0x30` / `INFO_DEVICE_NAME 0x40`, each `+ devnum − 1` |
| `0x00B2` | `REG_RECEIVER_PAIRING` | open/close the pairing lock and unpair a slot (Unifying-style); see §2 |

---

## 2. Receiver operations

All addressed to the receiver itself (`devnum = 0xFF`); the typed wrappers live in `v1/receiver.rs` on `Hidpp10`.

### `notify_devices` / `device_count`

`notify_devices` writes `REG_DEVICE_COUNT [0x02]` → the receiver re-broadcasts every paired slot's connection status as unsolicited notifications (see §3). `device_count` reads `REG_DEVICE_COUNT` and returns reply **byte 1** (not byte 0).

### `paired_info(slot)` — pairing record for a slot (1-based)

1. Read `REG_RECEIVER_INFO` with param `[INFO_PAIRING + slot − 1]` → `10 FF 83 B5 (0x20+slot-1) 00 00`. Reply must be ≥ 8 bytes.
2. **WPID** is bytes `[3:5]` big-endian (Solaar `extract_wpid` reverses `pair[3:5]`). A WPID of `0x0000` or `0xFFFF` means the slot is empty → `None`.
3. Read `REG_RECEIVER_INFO` with param `[INFO_EXTENDED_PAIRING + slot − 1]` → the **serial**: 4 bytes at `ext[1:5]`, formatted as 8 hex chars. All-zero or all-`0xFF` is the unset sentinel (`parse_extended_serial` → `None`).

Returns `PairedDevice { devnum, wpid, serial }`.

### Pairing — `open_pairing_lock` / `close_pairing_lock` / `unpair`

Writes to `REG_RECEIVER_PAIRING` (`0x00B2`), fire-and-forget. This Lightspeed family uses the Unifying-style register (`may_unpair = true`, `re_pairs = false`); no Bolt discovery is involved.

| Operation | Bytes sent | Params |
|-----------|-----------|--------|
| Open pairing lock | `10 FF 80 B2 01 00 <timeout>` | `[0x01, 0x00, timeout_secs]` |
| Close pairing lock | `10 FF 80 B2 02 00 00` | `[0x02, 0x00, 0x00]` |
| Unpair slot | `10 FF 80 B2 03 <slot>` | `[0x03, slot]` (slot 1-based) |

While the lock is open the receiver emits `0x4A` lock-status notifications (§3) and, when a device pairs, its `0x41` connection notification under the new device number.

---

## 3. Notifications

The receiver emits unsolicited HID++ 1.0 notifications on the broadcast channel, keyed by device number `1..=6`. (This page describes the wire packet only, not the daemon's device-list reaction.)

### Device connection — `0x41`

Sent for **both** connect and disconnect; the link state is in the payload. `decode_link_established(data)`: bit `0x40` of `data[0]` is "link **not** established" — set on power-off, clear on power-on, so `link_established = !(data[0] & 0x40)`. An empty payload reads as disconnected.

Live captures (trailing bytes vary per device, irrelevant):

| Payload | Meaning |
|---------|---------|
| `71 b0 40` / `72 99 40` | device 1 / 2 powered **off** (bit 0x40 set) |
| `b1 b0 40` / `b2 99 40` | device 1 / 2 powered **on** (bit 0x40 clear) |

### Pairing-lock status — `0x4A`

Emitted while a pairing lock is open/closing (`decode_pairing_lock(address, data)`). The "lock **open**" flag and the error code live in **two different bytes**, so an error code whose low bit is set (e.g. `0x03`) is never mistaken for the open flag:

- **`address` byte** (packet byte 3) — bit `0x01` set ⇒ lock open (listening for a device).
- **`data[0]`** (packet byte 4) — once the lock is closed, a **nonzero** value is a `PairingError` code; `0x00` means a device paired cleanly. Ignored while the lock is open.

| `data[0]` (lock closed) | `PairingError` |
|-------------------------|----------------|
| `0x00` | none — device paired |
| `0x01` | device-timeout |
| `0x02` | not-supported |
| `0x03` | too-many-devices |
| `0x06` | sequence-timeout |

