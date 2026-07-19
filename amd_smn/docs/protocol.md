# AMD SMN protocol

Read-only access to AMD Zen thermal registers over the daemon's typed SMN transport (Windows only).

**Credits:** decoding derived from [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) `Amd17Cpu.cs` (MPL-2.0).

---

## Overview

This is not a packet protocol: the daemon detects a supported AMD Zen CPUID family/model and exposes a single typed transport call, `dev.transport:amd_smn_read(offset)`, which returns one 32-bit SMN register value. The plugin never writes; all registers are read-only thermal sensors.

Tctl/Tdie is read from one fixed register. On specific CPU models, up to eight per-CCD temperature registers are also read. A failed SMN read is treated as a missing sample rather than taking the device offline.

---

## 1. Packet layout

The wire unit is a 32-bit SMN register, addressed by offset and read via `amd_smn_read(offset)`.

### Tctl/Tdie register: `0x00059800`

```text
bits 31..21   temperature, decoded as (raw >> 21) * 0.125 degrees C
bit  19       (0x00080000) firmware offset flag
bits 17..16   (0x00030000) alternate offset flag, both bits must be set
```

If bit 19 is set, or bits 17..16 are both set, subtract 49 C from the decoded value.

### CCD registers: base + `i * 4`, `i` in `0..7`

```text
bits 11..0    raw CCD temperature, decoded as raw * 0.125 - 305 degrees C
```

The base register depends on the CPU model (see section 3). Bits above 11 are masked off.

---

## 2. Functions

| Function | Register reads | Notes |
| --- | --- | --- |
| `initialize` | none | Sets the model label from the matched CPUID family; opening the SMN transport already proved the CPU is a supported Zen part, so init never fails on a thermal read |
| `get_sensors` | Tctl/Tdie, plus 8 CCD registers on eligible models | Returns temperature sensors; results are cached for one second |

### `get_sensors` sequence

1. If a cached result is younger than one second (Halo's monotonic clock), return it.
2. Read `0x00059800`, decode Tctl/Tdie; publish it only if the value is within -55..155 C.
3. If the model is CCD-eligible, read 8 registers at 4-byte intervals from the model's base; publish each valid CCD temperature.
4. If more than one CCD produced a value, also publish maximum and average sensors.
5. Cache the result for 1000 ms.

Any individual failed SMN read is skipped as a missing sample.

---

## 3. Parameters

### Registers

| Register | Offset | Used by |
| --- | --- | --- |
| Tctl/Tdie | `0x00059800` | All supported models |
| CCD base (legacy) | `0x00059954` | Models `0x31`, `0x71`, `0x21` |
| CCD base (Raphael / Granite Ridge) | `0x00059B08` | Models `0x61`, `0x44` |

CCD sensors are exposed only for models `0x31`, `0x71`, `0x21`, `0x61`, and `0x44`. Eight CCD registers are read at four-byte intervals from the base.

### Decoding

| Value | Formula | Validity |
| --- | --- | --- |
| Tctl/Tdie | `(raw >> 21) * 0.125`, minus 49 if the offset flags select it | -55..155 C inclusive |
| CCD | `(raw & 0xFFF) * 0.125 - 305` | masked raw of 0 is invalid; decoded values at or above 125 C are invalid |

### Architecture labels

The device model string is `AMD Ryzen (<label>)`, from the CPUID family:

| Family | Label |
| --- | --- |
| `0x17` | Zen / Zen+ / Zen 2 |
| `0x19` | Zen 3 / Zen 4 |
| `0x1A` | Zen 5 |
| other | Zen |

### Published sensors

All sensors are `temperature` in `celsius`:

| Sensor id | Name | Condition |
| --- | --- | --- |
| `amd_ryzen_cpu_tctl_tdie` | Core (Tctl/Tdie) | value in range |
| `amd_ryzen_cpu_ccd<n>` | CCD\<n\> (Tdie), `n` in 1..8 | eligible model, valid reading |
| `amd_ryzen_cpu_ccds_max` | CCDs Max (Tdie) | more than one valid CCD |
| `amd_ryzen_cpu_ccds_avg` | CCDs Average (Tdie) | more than one valid CCD |

---

## 4. Responses

Every `amd_smn_read(offset)` call returns one 32-bit register value, decoded as in section 1. There are no acknowledgements or multi-frame replies. A read failure yields no sample for that register; the sensor simply drops out of the result until the next successful poll.

---

## 5. Polling & notifications

Host-initiated polling only; the hardware never notifies. Reads are coalesced for one second using Halo's monotonic clock, so consumer reads at UI/render cadence reuse the cached sensor set instead of issuing fresh broker requests.

---

## Notes

- Windows-only and read-only: the manifest requests only the `amd_smn` permission and the plugin performs no writes.
- LibreHardwareMonitor additionally applies model-specific Tctl offsets (for example -20, -27, -10 C on certain parts); this plugin applies only the firmware-flagged 49 C offset.
- A transient SMN read failure must not hide the device: the transport match already established support, so failures are per-sample.
