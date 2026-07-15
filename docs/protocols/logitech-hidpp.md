# Logitech HID++

The Logitech package owns the explicitly catalogued HID++ devices and receiver
endpoints. Unknown product IDs are intentionally not registered. HID transport
operations are serialized per physical root by Halo's Lua worker.

The LIGHTSPEED receiver is a pairing transport only. It discovers paired slots
through HID++ 1.0 receiver registers and creates one child device per slot; RGB,
DPI, battery, report-rate, and audio capabilities are exposed only by a direct
device or such a child, never by the receiver itself.

Direct devices and receiver children enumerate the HID++ 2.0 feature table at
startup. The package enables a capability only when its corresponding feature is
advertised. Gaming headsets with `EQUALIZER` (`0x8310`) expose the firmware's
custom curve: band frequencies, signed dB bounds, current band levels, and a
clamped custom-band write. `SIDETONE` (`0x8300`) is exposed as an independent
0–100 range control.

Devices advertising `RGB_EFFECTS` (`0x8071`) also expose the firmware-native
Color Wave and Ripple effects. Ripple retains the captured HID++ byte layout
for its background colour, rate, and saturation parameters.
