# Repository releases

`repository.yaml` is the release boundary for this repository. Its packages are sorted by `id` and
each entry names one contained directory, package version, and deterministic SHA-256 package digest.
The digest covers sorted relative regular-file paths, a NUL separator, each file length as a
little-endian 64-bit value, and the file bytes. Symlinks are not permitted anywhere in a package.

Create releases as follows:

1. Validate every `plugin.yaml` without running Lua.
2. Generate the sorted package index and compare every digest, id, and version to the package.
3. Sign the exact `repository.yaml` bytes with the protected Ed25519 release key and write
   `repository.sig` containing its schema, `ed25519` algorithm, key id, and base64 signature.
4. Publish only after the daemon compatibility range, plugin API generation, package validation,
   and tests pass.

The private key must never be committed or made available to pull-request workflows. Local and
development repositories may omit `repository.sig`; Halo presents them as unsigned or local
development provenance and still requires normal enable consent.

When launched with `--dev-plugin-repo <path>`, Halo uses that canonical path
as the process-local replacement for the managed official repository. It does
not fetch, check, update, or repair the official checkout during that run;
restart without the flag to resume normal official repository management.

An update is repository-scoped. Halo fetches objects, validates and materializes the proposed
revision into a staging directory, then atomically selects it. A failed validation leaves the active
revision untouched. Official releases retain the previously verified SHA for rollback diagnostics.
