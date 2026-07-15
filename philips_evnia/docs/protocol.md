# Philips Evnia protocols

The Philips Evnia plugin uses two independent protocols exposed by the monitor's
USB devices:

- [DDC/CI](ddc-ci.md) controls picture, OSD, input, audio, and monitor settings.
- [Ambiglow](ambiglow.md) streams the 30 RGB LEDs around the panel and releases
  them back to firmware control.

Keeping both pages beside the plugin makes the implementation, supported device
catalog, and wire documentation one package-owned unit.
