# Nuvoton LPCIO

`lpcio` is a Windows-only typed PawnIO transport. The daemon probes the two
standard Super I/O slots, confirms an explicitly listed Nuvoton chip ID, and
passes the slot, chip ID, and HWM BAR to Lua. The plugin performs all sensor
and PWM operations. The host snapshots every HWM register on its first Lua
write and restores modified registers in reverse order on close, worker failure,
or transport teardown; Lua cleanup is not the safety boundary.

For NCT679x-family chips, firmware can relock the HWM BAR between polls. The
plugin asks the typed broker operation to register/reopen it before each access;
Lua cannot enter Super-I/O configuration mode itself. Temperature slots are decoded
per chip family, including signed half-degree values and the firmware source
label, then deduplicated by that source.

The package is derived from LibreHardwareMonitor's Nct677X implementation and
is licensed MPL-2.0.
