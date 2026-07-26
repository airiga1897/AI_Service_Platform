#!/usr/bin/env python3
"""Run one contract-declared site_runtime bootstrap operation without leaking secrets."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.site_runtime.project_contract import (
    ProjectContractError,
    load_contract,
    read_env,
)


class BootstrapError(RuntimeError):
    """A safe bootstrap failure suitable for operator output."""


def _run(command: list[str], *, env: dict[str, str] | None = None) -> None:
    completed = subprocess.run(
        command,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise BootstrapError(
            f"bootstrap subprocess failed with exit code {completed.returncode}"
        )


def _validate_secret(path: Path | None, expected: tuple[str, ...]) -> dict[str, str]:
    if not expected:
        return {}
    if path is None or not path.is_file():
        raise BootstrapError("bootstrap secret file is required")
    values = read_env(path)
    if set(values) != set(expected):
        raise BootstrapError("bootstrap secret keys do not match embedded contract")
    if any(not values[key] for key in expected):
        raise BootstrapError("bootstrap secret contains an empty required value")
    return values


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", choices=("check", "run"), required=True)
    parser.add_argument("--operation", required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--secret", type=Path)
    parser.add_argument("--compose", type=Path, required=True)
    args = parser.parse_args()
    try:
        contract = load_contract(args.contract)
        if args.operation not in contract.bootstrap:
            raise BootstrapError("operation is not declared by embedded contract")
        spec = contract.bootstrap[args.operation]
        expected = tuple(spec["environment"])
        values = _validate_secret(args.secret, expected)
        command_invoked = False
        check_command_invoked = False
        if args.action == "check" and spec.get("check_command"):
            command = spec["check_command"]
            check_command_invoked = True
        elif args.action == "run":
            command = spec["command"]
            command_invoked = True
        else:
            command = None
        if command:
            process_env = os.environ.copy()
            process_env.update(values)
            compose_command = [
                "docker",
                "compose",
                "-f",
                str(args.compose),
                "run",
                "--rm",
                "--no-deps",
            ]
            for key in expected:
                compose_command.extend(("-e", key))
            compose_command.extend(
                ("--entrypoint", "/bin/sh", "web", "-ec", f"exec {command}")
            )
            _run(compose_command, env=process_env)
        _run(
            [
                "docker",
                "compose",
                "-f",
                str(args.compose),
                "exec",
                "-T",
                "web",
                "python",
                "-c",
                (
                    "import urllib.request;"
                    "[urllib.request.urlopen('http://127.0.0.1:8080'+p,timeout=5).read() "
                    "for p in ('/healthz/','/readyz/','/worker-healthz/')]"
                ),
            ]
        )
        print(
            json.dumps(
                {
                    "operation": args.operation,
                    "environment_keys": sorted(expected),
                    "command_invoked": command_invoked,
                    "check_command_invoked": check_command_invoked,
                    "private_health": "succeeded",
                    "final_status": "succeeded",
                },
                ensure_ascii=False,
                sort_keys=True,
            )
        )
        return 0
    except (BootstrapError, OSError, ProjectContractError) as exc:
        print(f"site_runtime bootstrap error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
