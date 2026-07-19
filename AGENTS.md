<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Repository instructions

After changing any plugin package, package documentation, test fixture, or
license notice, regenerate the repository index before finishing:

```powershell
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- index .
cargo run --manifest-path ..\HaloDaemon\src\Cargo.toml -p halod-plugin-signing -- index . --check
```

Never edit package hashes in `repository.yaml` manually. Include the generated
`repository.yaml` change with the package change. `repository.sig` is updated
only by the signing workflow because it requires the private signing key.

The tracked pre-commit hook in `.githooks/pre-commit` enforces the index check.
