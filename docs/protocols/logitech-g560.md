# Logitech G560

The G560 is deliberately packaged separately from Logitech HID++ devices. It
uses fixed 20-byte vendor long reports (`0x11`) addressed to device number
`0xff`, not the HID++ feature table protocol.

Lighting uses feature/function `0x04/0x3a` with the speaker-zone byte followed
by `01 R G B 02`. Subwoofer volume uses `0x09/0x1c` with one byte clamped to
0–100. The implementation is derived from the MIT-licensed `g560-led` project;
the package and its test fixture retain its attribution.
