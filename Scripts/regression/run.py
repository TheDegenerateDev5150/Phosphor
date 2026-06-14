#!/usr/bin/env python3
"""Run focused Phosphor regression checks.

Each check module in Scripts/regression/checks exposes test_* functions. This
keeps lightweight source/fixture regressions split by feature area instead of
collecting every invariant in one growing script.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKS = Path(__file__).resolve().parent / "checks"


def load_module(path: Path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    failures: list[str] = []
    total = 0
    for path in sorted(CHECKS.glob("*.py")):
        if path.name.startswith("_"):
            continue
        module = load_module(path)
        for name in sorted(n for n in dir(module) if n.startswith("test_")):
            total += 1
            try:
                getattr(module, name)(ROOT)
                print(f"PASS {path.stem}.{name}")
            except Exception as exc:  # noqa: BLE001 - regression runner reports all failures
                failures.append(f"FAIL {path.stem}.{name}: {exc}")
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        raise SystemExit(1)
    print(f"PASS {total} regression checks")


if __name__ == "__main__":
    main()
