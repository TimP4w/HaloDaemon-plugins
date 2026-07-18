# Halo effect callback protocol

`halo_effects` is an effect package, not a device package, so it has no hardware
wire protocol. Its protocol is the Lua effect callback contract used by the RGB
engine.

Pixmap effects implement `render_effect_<id>(buffer, ctx)` and write one RGB
color per canvas pixel for each render tick. Direct effects implement
`led_effect_<id>(leds, ctx)` and return one linear RGB color per LED. The context
contains a single engine-frame snapshot of parameters, audio, sensors, timing,
seed, and zone identity. Direct LED records also carry stable LED and zone IDs.
`main.lua` contains the reference implementations for both callback forms and
uses `ctx.frame` to keep state updates idempotent across multiple zones.

The runtime contract and value limits are documented in the repository's
[Lua API reference](../../docs/lua-api.md).
