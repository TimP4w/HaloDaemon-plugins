<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Repository instructions

After changing any plugin package, package documentation, test fixture, or
license notice, validate an ephemeral release manifest before finishing:

```powershell
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- index . --version 0.0.0 --id test-release --name "Test release"
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- validate .
Remove-Item release.yaml
```

Never commit `release.yaml`, `release.sig`, or `plugins.tar.gz`. The publication
workflow generates, signs, validates, and uploads all three as release assets.
