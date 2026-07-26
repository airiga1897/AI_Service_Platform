#!/usr/bin/env python3
"""Import a project-owned env profile into an operator application secret."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.site_runtime.project_contract import (
    ProjectContractError,
    load_contract,
    read_env,
    resolve_application_environment,
)


def _write_atomic(path: Path, values: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            for key in sorted(values):
                stream.write(f"{key}={values[key]}\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--source-env", required=True, type=Path)
    parser.add_argument("--target", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        contract = load_contract(args.contract)
        source = read_env(args.source_env)
        current = read_env(args.target) if args.target.exists() else {}
        unclassified = sorted(set(source).difference(contract.classified_keys))
        if unclassified:
            raise ProjectContractError(
                "source env contains unclassified keys: " + ", ".join(unclassified)
            )
        unknown_current = sorted(set(current).difference(contract.application_keys))
        if unknown_current:
            raise ProjectContractError(
                "target env contains keys outside persistent application contract: "
                + ", ".join(unknown_current)
            )
        result = resolve_application_environment(contract, source, current)
        changed = sorted(key for key in set(current) | set(result) if current.get(key) != result.get(key))
        ignored_platform = sorted(key for key in contract.platform_owned if source.get(key, "") != "")
        ignored_bootstrap = sorted(
            key
            for spec in contract.bootstrap.values()
            for key in spec["environment"]
            if source.get(key, "") != ""
        )
        ignored_local = sorted(key for key in contract.local_only if source.get(key, "") != "")
        summary = {
            "application_keys": sorted(result),
            "changed_keys": changed,
            "ignored_bootstrap_keys": ignored_bootstrap,
            "ignored_local_only_keys": ignored_local,
            "ignored_platform_owned_keys": ignored_platform,
            "mutation_performed": False,
        }
        if not args.check and current != result:
            _write_atomic(args.target, result)
            summary["mutation_performed"] = True
        print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
        return 0
    except (OSError, ProjectContractError) as exc:
        print(f"project environment import error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
