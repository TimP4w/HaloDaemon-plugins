<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Repository instructions

After changing any plugin package, package documentation, test fixture, or
license notice:

- bump the package's `version` (publishing refuses changed content under a
  published version);
- regenerate `licenses.txt` with `python scripts/generate-licenses.py`;
- run `halod plugin-test` on the package if it has a `test.lua`.

Never commit `catalog.yaml` or package archives. The Publish workflow builds,
signs and deploys them to GitHub Pages on every push to `main`.
