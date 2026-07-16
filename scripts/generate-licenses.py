#!/usr/bin/env python3
"""Generate the per-plugin license/SPDX notice shipped with HaloDaemon."""

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path


# These are parser inputs, not this script's own license declaration.
# REUSE-IgnoreStart
SPDX_LICENSE = "SPDX-License-" "Identifier:"
SPDX_COPYRIGHT = "SPDX-File" "CopyrightText:"
# REUSE-IgnoreEnd


def manifest_fields(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^(id|name|license):\s*(.*?)\s*$", line)
        if match:
            value = match.group(2)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            fields[match.group(1)] = value
    missing = {"id", "license"} - fields.keys()
    if missing:
        raise ValueError(f"{path}: missing {', '.join(sorted(missing))}")
    return fields


def spdx_value(line: str, tag: str) -> str | None:
    if tag not in line:
        return None
    value = line.split(tag, 1)[1].strip()
    value = re.sub(r"\s*(?:-->|\*/)$", "", value).strip()
    return value or None


def package_spdx(package: Path) -> dict[str, set[str]]:
    by_license: dict[str, set[str]] = defaultdict(set)
    for path in sorted(item for item in package.rglob("*") if item.is_file()):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        licenses = {value for line in lines if (value := spdx_value(line, SPDX_LICENSE))}
        copyrights = {
            value for line in lines if (value := spdx_value(line, SPDX_COPYRIGHT))
        }
        for license_id in licenses:
            by_license[license_id].update(copyrights)
    return by_license


def generate(root: Path) -> str:
    packages = sorted(path for path in root.iterdir() if (path / "plugin.yaml").is_file())
    lines = [
        "Embedded official plugin licenses",
        "=================================",
        "",
        "These plugins are embedded in halod. The plugin license is declared by",
        "the HaloDaemon plugin package. Source SPDX licenses describe incorporated",
        "or adapted source inside that plugin and may therefore differ.",
        "",
    ]
    used_licenses: set[str] = set()
    for package in packages:
        fields = manifest_fields(package / "plugin.yaml")
        source_licenses = package_spdx(package)
        if not source_licenses:
            raise ValueError(f"{package}: contains no SPDX license declarations")
        plugin_license = fields["license"]
        used_licenses.add(plugin_license)
        lines.extend(
            [
                f"{fields.get('name', fields['id'])} ({fields['id']})",
                f"  Plugin license: {plugin_license}",
                "  Source SPDX licenses:",
            ]
        )
        for license_id, copyrights in sorted(source_licenses.items()):
            used_licenses.add(license_id)
            lines.append(f"    - {license_id}")
            lines.extend(f"      Copyright: {value}" for value in sorted(copyrights))
        lines.append("")

    lines.extend(["Full license texts", "=================="])
    for license_id in sorted(used_licenses):
        path = root / "LICENSES" / f"{license_id}.txt"
        if not path.is_file():
            raise ValueError(f"missing license text for {license_id}: {path}")
        lines.extend(["", f"--- {license_id} ---", "", path.read_text(encoding="utf-8").rstrip()])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("licenses.txt"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    expected = generate(root)
    if args.check:
        actual = args.output.read_text(encoding="utf-8") if args.output.is_file() else None
        if actual != expected:
            print(f"{args.output} is stale; run {Path(__file__).name}", file=sys.stderr)
            return 1
        print(f"{args.output} is current")
        return 0
    args.output.write_text(expected, encoding="utf-8", newline="\n")
    print(f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
