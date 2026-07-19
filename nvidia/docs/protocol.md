# NVIDIA GPU sensor protocol

Read-only NVIDIA GPU temperature sensors via the stable `nvidia-smi` CSV command interface on Linux and Windows.

---

## Overview

There is no hardware wire packet: the plugin invokes the `nvidia-smi` executable through the command transport and parses its CSV output. It does not use the old native NvAPI-private-structure path. The model is host-initiated command/response: one enumeration command discovers GPUs, one per-GPU command reads temperatures. All failures degrade to empty results so a later poll can recover.

---

## 1. Packet layout

The natural data unit is one `nvidia-smi` invocation returning CSV rows with `--format=csv,noheader,nounits` (no header line, no unit suffixes). Rows are split at the first comma; fields are trimmed of surrounding whitespace.

### Enumeration row

```text
<uuid>, <name>
```

Example:

```text
GPU-54968926-…, NVIDIA GeForce RTX 5080
```

### Temperature row

```text
<temperature.gpu>, <temperature.memory>
```

Integer degrees Celsius; a field can be `N/A`. Example:

```text
47, N/A
```

---

## 2. Functions

| Function | Command | Result handling |
| --- | --- | --- |
| Enumerate GPUs | `nvidia-smi --query-gpu=uuid,name --format=csv,noheader,nounits` | One dynamic child device per non-empty row |
| Read temperatures | `nvidia-smi -i <uuid> --query-gpu=temperature.gpu,temperature.memory --format=csv,noheader,nounits` | First row parsed into up to two temperature sensors |

### Enumeration

Each non-empty row is split at the first comma into a stable GPU UUID and model name. One dynamic child device is created per UUID, with identity `nvidia_gpu_<uuid>` and the UUID stored as its serial and transport key. A missing executable, transient driver restart, or non-zero command exit yields no children rather than failing plugin discovery.

### Temperature read

The child's UUID selects the GPU via `-i <uuid>`. The first output row carries core and memory temperature in integer degrees Celsius. Numeric fields become `GPU Core` and `Memory` temperature sensors; `N/A`, blank, or otherwise non-numeric fields are omitted. Command failures return an empty sensor list, allowing a later poll to recover after a driver restart.

---

## 3. Parameters

| Parameter | Value | Meaning |
| --- | --- | --- |
| Executable | `nvidia-smi` | The only command the manifest grants access to |
| `--query-gpu=uuid,name` | enumeration | Stable UUID plus model name per GPU |
| `-i <uuid>` | per-GPU read | Selects one GPU by its UUID |
| `--query-gpu=temperature.gpu,temperature.memory` | per-GPU read | Core and memory temperature |
| `--format=csv,noheader,nounits` | both commands | CSV rows, no header line, no unit suffixes |
| Cache lifetime | 1 second | Sensor results cached per child |

Sensor identifiers derive from the child identity: `nvidia_gpu_<uuid>_temp1` (GPU Core) and `nvidia_gpu_<uuid>_temp2` (Memory), both `celsius` temperature sensors.

---

## 4. Responses

Only command stdout is consumed; a command counts as failed when the executable is missing, exits non-zero, or times out.

- **Enumeration:** every non-empty stdout line is a candidate GPU; lines that do not split into a non-empty UUID and name are skipped. Failure yields zero children.
- **Temperature read:** only the first stdout row is parsed. Each field is converted to a number; non-numeric fields produce no sensor. Failure yields an empty sensor list.

---

## 5. Polling & notifications

Entirely host-initiated: the plugin has no notifications, RGB controls, or fan controls. Sensor results are cached for one second so multiple UI and engine consumers in the same frame do not spawn duplicate commands; the cache also holds the empty result of a failed read for the same second.

---

## Notes

- The manifest grants access only to the exact `nvidia-smi` executable, on Linux and Windows.
- `temperature.memory` is commonly `N/A` on GPUs without a memory sensor; the plugin then reports only `GPU Core`.
- Enumeration and read failures are deliberately non-fatal so the plugin survives driver restarts.
