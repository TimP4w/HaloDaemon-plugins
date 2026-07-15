# Halo effect callback protocol

`halo_effects` is an effect package, not a device package, so it has no hardware
wire protocol. Its protocol is the Lua effect callback contract used by the RGB
engine.

Pixmap effects return one RGB color per canvas pixel for each render tick.
Direct effects receive a device zone's LED positions and return one RGB color
per LED. Parameters, audio samples, sensor values, and elapsed time are supplied
by HaloDaemon according to the declarations in `plugin.yaml`; `main.lua` contains
the reference implementations for both callback forms.

The runtime contract and value limits are documented in the repository's
[Lua API reference](../../docs/lua-api.md).
