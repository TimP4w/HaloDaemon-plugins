-- Exercised via `halod plugin-test <package-dir>`. This hub has no RGB channels
-- or `apply` of its own (every zone lives on a chained accessory routed via
-- `write_frame`, which the harness doesn't drive yet) — only
-- `initialize()` is covered here.

return function(h)
  local dev = h:open()

  h:assert(dev:initialize(), "initialize succeeds")
  local w = dev:writes()
  h:assert_eq(#w, 2, "status-push interval config + detect_fans")
  h:assert_eq(w[1].data, { 0x60, 0x02, 0x01, 0xE8, 0x03, 0x01, 0xE8, 0x03 }, "status push interval (~1000ms)")
  h:assert_eq(w[2].data, { 0x60, 0x03 }, "detect_fans")
end
