#!/usr/bin/env python3
"""Prepare ignored SoftEther secrets for the VPS3 GeoPolicy egress links."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import secrets
import tempfile


PATHS = {
    "geo-egress-vps3-vps1": "mycleanbot-operator-vps1",
    "geo-egress-vps3-vps2": None,
    "geo-egress-vps3-vps4": None,
}


def token() -> str:
    return secrets.token_urlsafe(32)


def load(path: pathlib.Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"secret must be a JSON object: {path}")
    return value


def atomic_write(path: pathlib.Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate_secret(value: dict, path: pathlib.Path) -> None:
    for key in ("server_password", "hub_password"):
        if not isinstance(value.get(key), str) or len(value[key]) < 32:
            raise ValueError(f"{path} has no valid {key}")
    client = (value.get("client_users") or {}).get("vps3")
    if not isinstance(client, dict):
        raise ValueError(f"{path} has no client_users.vps3")
    for key in ("client_user", "client_password"):
        if not isinstance(client.get(key), str) or not client[key]:
            raise ValueError(f"{path} has no client_users.vps3.{key}")


def prepare(directory: pathlib.Path, check_only: bool) -> dict:
    existing_vps1 = directory / "mycleanbot-operator-vps1.json"
    if not existing_vps1.is_file():
        raise ValueError("existing vps1 SoftEther server secret is required")
    shared_vps1_password = str(load(existing_vps1).get("server_password") or "")
    if len(shared_vps1_password) < 32:
        raise ValueError("existing vps1 SoftEther server password is invalid")

    created = []
    validated = []
    for name, shared_from in PATHS.items():
        path = directory / f"{name}.json"
        if path.exists():
            value = load(path)
            validate_secret(value, path)
            if shared_from and value["server_password"] != shared_vps1_password:
                raise ValueError("vps1 GeoPolicy hub must reuse the active server credential")
            validated.append(name)
            continue
        if check_only:
            continue
        value = {
            "server_password": shared_vps1_password if shared_from else token(),
            "hub_password": token(),
            "client_users": {
                "vps3": {
                    "client_user": f"geo_vps3_{name.rsplit('vps', 1)[-1]}",
                    "client_password": token(),
                }
            },
        }
        atomic_write(path, value)
        validate_secret(load(path), path)
        created.append(name)
    missing = [name for name in PATHS if not (directory / f"{name}.json").is_file()]
    return {
        "action": "check" if check_only else "prepare",
        "created": sorted(created),
        "validated": sorted(validated),
        "missing": sorted(missing),
        "secret_values_printed": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--secrets-dir",
        default="operator/softether/l3-vps/secrets",
    )
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = prepare(pathlib.Path(args.secrets_dir), args.check)
    print(json.dumps(result, sort_keys=True))
    return 2 if result["missing"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
