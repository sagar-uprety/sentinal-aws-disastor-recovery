#!/usr/bin/env python3
"""Fail if project prose contains an em dash or en dash.

Scope is the documentation this project maintains: the root README, docs/, and each
application README. Vendored references and agent scratch files are left alone.
"""
import sys
from pathlib import Path

DASHES = {"—": "em dash", "–": "en dash"}
SCOPE = ["README.md", "docs", "apps/sentry/README.md", "apps/url-shortener/README.md"]


def in_scope(paths: list[str]) -> list[Path]:
    if paths:
        return [Path(p) for p in paths if p.endswith(".md")]
    found: list[Path] = []
    for entry in SCOPE:
        path = Path(entry)
        if path.is_dir():
            found.extend(sorted(path.glob("*.md")))
        elif path.is_file():
            found.append(path)
    return found


def main(argv: list[str]) -> int:
    findings = []
    for path in in_scope(argv):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for number, line in enumerate(lines, 1):
            for char, label in DASHES.items():
                if char in line:
                    findings.append(f"{path}:{number}: {label}: {line.strip()[:88]}")

    if findings:
        print("Dash characters are not used in this project's prose:\n", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        print("\nUse a comma, colon, semicolon, or parentheses instead.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
