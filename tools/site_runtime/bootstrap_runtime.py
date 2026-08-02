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


_PRIVATE_HEALTH_PROBE = """\
import json
import sys
import urllib.error
import urllib.request

endpoint = sys.argv[1]
result = {"endpoint": endpoint, "status": None, "error": None, "checks": {}}
body = b""
try:
    response = urllib.request.urlopen(
        "http://127.0.0.1:8080" + endpoint,
        timeout=5,
    )
    result["status"] = getattr(response, "status", 200)
    body = response.read()
    response.close()
except urllib.error.HTTPError as exc:
    result["status"] = exc.code
    result["error"] = "http_error"
    body = exc.read()
except urllib.error.URLError as exc:
    result["error"] = type(exc.reason).__name__
except Exception as exc:
    result["error"] = type(exc).__name__

try:
    payload = json.loads(body.decode("utf-8")) if body else {}
except (UnicodeDecodeError, json.JSONDecodeError):
    payload = {}
allowed = {
    "status": {"ok", "error", "pending", "skipped", "degraded"},
    "db": {"ok", "error"},
    "migrations": {"ok", "error", "pending"},
    "celery": {"ok", "error", "skipped"},
    "broker_type": {"redis", "sqla", "memory", "unknown"},
}
if isinstance(payload, dict):
    for key, values in allowed.items():
        value = payload.get(key)
        if value in values:
            result["checks"][key] = value

print(json.dumps(result, sort_keys=True))
sys.exit(
    0
    if result["error"] is None and result["status"] == 200
    else 1
)
"""


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


def _check_private_health(compose: Path) -> None:
    for endpoint in ("/healthz/", "/readyz/", "/worker-healthz/"):
        completed = subprocess.run(
            [
                "docker",
                "compose",
                "-f",
                str(compose),
                "exec",
                "-T",
                "web",
                "python",
                "-c",
                _PRIVATE_HEALTH_PROBE,
                endpoint,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if completed.returncode == 0:
            continue
        try:
            result = json.loads(completed.stdout.strip().splitlines()[-1])
        except (IndexError, json.JSONDecodeError):
            raise BootstrapError(
                f"private health check failed: endpoint={endpoint}, "
                f"probe_exit_code={completed.returncode}"
            ) from None
        status = result.get("status")
        error = result.get("error") or "unexpected_status"
        checks = result.get("checks")
        safe_checks = checks if isinstance(checks, dict) else {}
        raise BootstrapError(
            f"private health check failed: endpoint={endpoint}, "
            f"status={status}, error={error}, "
            f"checks={json.dumps(safe_checks, sort_keys=True, separators=(',', ':'))}"
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
        _check_private_health(args.compose)
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
