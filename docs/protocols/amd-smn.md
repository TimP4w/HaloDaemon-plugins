# AMD SMN

`amd_smn` is a Windows-only, read-only plugin transport. The daemon detects a
supported AMD Zen CPUID family/model and exposes only `dev.transport:amd_smn_read(offset)`.
The official package decodes Tctl/Tdie and populated CCD temperature registers.
It coalesces reads for one second with Halo's permission-free monotonic clock,
so repeated UI consumers cannot amplify SMN traffic or thermal sample jitter.

The implementation is derived from LibreHardwareMonitor's `Amd17Cpu.cs` and is
licensed MPL-2.0.
