# NVIDIA GPU sensor protocol

The NVIDIA plugin provides read-only temperature sensors by invoking the stable
`nvidia-smi` CSV command interface on Linux and Windows. There is no hardware
wire packet and the plugin does not use the old native NvAPI-private-structure
path.

## Enumeration

The plugin runs:

```text
nvidia-smi --query-gpu=uuid,name --format=csv,noheader,nounits
```

Each non-empty row is split at the first comma into a stable GPU UUID and model
name. One dynamic child device is created per UUID, with identity
`nvidia_gpu_<uuid>` and the UUID stored as its serial and transport key. A
missing executable, transient driver restart, or non-zero command exit yields
no children rather than failing plugin discovery.

Example response:

```text
GPU-54968926-…, NVIDIA GeForce RTX 5080
```

## Temperature read

For a child UUID, the plugin runs:

```text
nvidia-smi -i <uuid> --query-gpu=temperature.gpu,temperature.memory --format=csv,noheader,nounits
```

The first row contains core and memory temperature in integer degrees Celsius:

```text
47, N/A
```

Numeric fields become `GPU Core` and `Memory` temperature sensors. `N/A`, blank,
or otherwise non-numeric fields are omitted. Command failures return an empty
sensor list, allowing a later poll to recover after a driver restart.

## Polling and limits

Results are cached for one second so multiple UI and engine consumers in the
same frame do not spawn duplicate commands. The protocol is entirely
host-initiated and has no notifications, RGB controls, or fan controls. The
manifest grants access only to the exact `nvidia-smi` executable.
