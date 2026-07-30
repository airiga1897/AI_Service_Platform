#!/usr/bin/env python3
"""Manage desired per-invitation MyCleanBot SoftEther users.

The helper only changes operator-local desired state. Applying that state to
VPS1 remains a separate platform_router plan/apply operation.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import tempfile
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

LINK_NAME = "mycleanbot-operator-vps1"
HUB = "MyCleanBotOperatorVps1"
SERVER = "l3-vps1.mine-craft.su:443"
HOSTS_ENTRY = "172.31.1.11 mycleanbot.mine-craft.su"
PROTECTED_ALIAS = "operator-arm"
PROTECTED_USERNAME = "operator_arm"
MANAGED_PREFIX = "mcb_user_"
MANAGED_LIMIT = 9
TOMBSTONE_DAYS = 90
USERNAME_RE = re.compile(r"^mcb_user_(00[1-9])$")


class VpnUserError(RuntimeError):
    pass


def now_utc() -> datetime:
    return datetime.now(UTC)


def iso(value: datetime) -> str:
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def read_json(path: Path, *, required: bool) -> dict[str, Any]:
    if not path.exists():
        if required:
            raise VpnUserError(f"required operator file is missing: {path}")
        return {}
    if path.is_symlink() or not path.is_file():
        raise VpnUserError(f"refusing non-regular operator file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise VpnUserError(f"invalid JSON operator file: {path}") from exc
    if not isinstance(value, dict):
        raise VpnUserError(f"operator JSON root must be an object: {path}")
    return value


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.is_symlink():
        raise VpnUserError(f"refusing symlink target: {path}")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        os.chmod(temporary, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if temporary.exists():
            temporary.unlink()


def assert_operator_paths(operator_dir: Path, paths: list[Path]) -> None:
    root = operator_dir.resolve()
    for path in paths:
        candidate = path.resolve()
        if os.path.commonpath([root, candidate]) != str(root):
            raise VpnUserError(f"path escapes operator directory: {path}")


def load_state(
    secret_path: Path, registry_path: Path
) -> tuple[dict[str, Any], dict[str, Any]]:
    secret = read_json(secret_path, required=True)
    users = secret.get("client_users")
    if not isinstance(users, dict):
        raise VpnUserError("SoftEther secret has no client_users object")
    protected = users.get(PROTECTED_ALIAS)
    if not isinstance(protected, dict) or protected.get("client_user") != PROTECTED_USERNAME:
        raise VpnUserError("protected operator_arm account is missing or changed")
    if not protected.get("client_password"):
        raise VpnUserError("protected operator_arm password is empty")

    registry = read_json(registry_path, required=False) or {
        "schema_version": 1,
        "link_name": LINK_NAME,
        "entries": {},
    }
    if registry.get("schema_version") != 1 or registry.get("link_name") != LINK_NAME:
        raise VpnUserError("unsupported MyCleanBot VPN registry")
    if not isinstance(registry.get("entries"), dict):
        raise VpnUserError("VPN registry entries must be an object")
    return secret, registry


def active_entries(registry: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        item
        for item in registry["entries"].values()
        if isinstance(item, dict) and item.get("status") == "active"
    ]


def validate_state(secret: dict[str, Any], registry: dict[str, Any]) -> None:
    users = secret["client_users"]
    active = active_entries(registry)
    if len(active) > MANAGED_LIMIT:
        raise VpnUserError("managed MyCleanBot VPN user limit exceeded")
    seen: set[str] = set()
    for item in active:
        username = str(item.get("vpn_username") or "")
        invitation_id = int(item.get("invitation_id") or 0)
        alias = f"invitation-{invitation_id}"
        if not USERNAME_RE.fullmatch(username):
            raise VpnUserError(f"unsafe managed username for invitation {invitation_id}")
        if username in seen:
            raise VpnUserError("duplicate managed VPN username")
        seen.add(username)
        secret_item = users.get(alias)
        if (
            not isinstance(secret_item, dict)
            or secret_item.get("client_user") != username
            or not secret_item.get("client_password")
        ):
            raise VpnUserError(
                f"active invitation {invitation_id} is inconsistent with SoftEther secret"
            )
    managed_in_secret = {
        str(item.get("client_user"))
        for item in users.values()
        if isinstance(item, dict)
        and str(item.get("client_user") or "").startswith(MANAGED_PREFIX)
    }
    if managed_in_secret != seen:
        raise VpnUserError("orphaned or missing managed user in SoftEther desired state")


def available_username(registry: dict[str, Any], current_time: datetime) -> str:
    blocked = {
        str(item.get("vpn_username") or "")
        for item in registry["entries"].values()
        if isinstance(item, dict)
        and (
            item.get("status") == "active"
            or (
                item.get("status") == "revoked"
                and item.get("tombstone_until")
                and parse_time(str(item["tombstone_until"])) > current_time
            )
        )
    }
    for index in range(1, MANAGED_LIMIT + 1):
        username = f"{MANAGED_PREFIX}{index:03d}"
        if username not in blocked:
            return username
    raise VpnUserError("no managed VPN slot is available")


def public_result(**values: Any) -> None:
    print(json.dumps(values, ensure_ascii=False, sort_keys=True))


def issue(
    args: argparse.Namespace,
    secret: dict[str, Any],
    registry: dict[str, Any],
    delivery_dir: Path,
) -> None:
    key = str(args.invitation_id)
    existing = registry["entries"].get(key)
    if isinstance(existing, dict) and existing.get("status") == "active":
        public_result(
            action="issue",
            apply=args.apply,
            invitation_id=args.invitation_id,
            state="already-active",
            vpn_username=existing["vpn_username"],
        )
        return
    if isinstance(existing, dict):
        raise VpnUserError(
            "invitation ID already has a retained VPN registry record"
        )
    current_time = now_utc()
    username = available_username(registry, current_time)
    if not args.apply:
        public_result(
            action="issue",
            apply=False,
            invitation_id=args.invitation_id,
            state="would-issue",
            vpn_username=username,
            mutations=False,
        )
        return

    password = secrets.token_urlsafe(36)
    alias = f"invitation-{args.invitation_id}"
    secret["client_users"][alias] = {
        "client_user": username,
        "client_password": password,
    }
    delivery_path = delivery_dir / f"invitation-{args.invitation_id}.json"
    registry["entries"][key] = {
        "invitation_id": args.invitation_id,
        "vpn_username": username,
        "status": "active",
        "issued_at": iso(current_time),
        "product_username": "",
        "bound_at": None,
        "delivery_pending": True,
    }
    atomic_write_json(args.secret_path, secret)
    atomic_write_json(args.registry_path, registry)
    atomic_write_json(
        delivery_path,
        {
            "invitation_id": args.invitation_id,
            "server": SERVER,
            "virtual_hub": HUB,
            "username": username,
            "password": password,
            "application_url": "https://mycleanbot.mine-craft.su",
            "hosts_entry": HOSTS_ENTRY,
        },
    )
    public_result(
        action="issue",
        apply=True,
        invitation_id=args.invitation_id,
        state="issued",
        vpn_username=username,
        delivery_file=str(delivery_path),
        next_step="platform_router plan; separately approved apply --limit vps1",
    )


def bind(args: argparse.Namespace, registry: dict[str, Any]) -> None:
    item = registry["entries"].get(str(args.invitation_id))
    if not isinstance(item, dict) or item.get("status") != "active":
        raise VpnUserError("invitation has no active VPN account")
    if not args.apply:
        public_result(
            action="bind",
            apply=False,
            invitation_id=args.invitation_id,
            product_username=args.product_username,
            mutations=False,
        )
        return
    item["product_username"] = args.product_username
    item["bound_at"] = iso(now_utc())
    atomic_write_json(args.registry_path, registry)
    public_result(
        action="bind",
        apply=True,
        invitation_id=args.invitation_id,
        state="bound",
    )


def acknowledge(
    args: argparse.Namespace, registry: dict[str, Any], delivery_dir: Path
) -> None:
    item = registry["entries"].get(str(args.invitation_id))
    if not isinstance(item, dict) or item.get("status") != "active":
        raise VpnUserError("invitation has no active VPN account")
    delivery_path = delivery_dir / f"invitation-{args.invitation_id}.json"
    if not args.apply:
        public_result(
            action="acknowledge",
            apply=False,
            invitation_id=args.invitation_id,
            delivery_exists=delivery_path.exists(),
            mutations=False,
        )
        return
    if delivery_path.exists():
        if delivery_path.is_symlink() or not delivery_path.is_file():
            raise VpnUserError("refusing unsafe delivery file")
        delivery_path.unlink()
    item["delivery_pending"] = False
    item["delivered_at"] = iso(now_utc())
    atomic_write_json(args.registry_path, registry)
    public_result(
        action="acknowledge",
        apply=True,
        invitation_id=args.invitation_id,
        state="delivery-removed",
    )


def revoke(
    args: argparse.Namespace,
    secret: dict[str, Any],
    registry: dict[str, Any],
    delivery_dir: Path,
) -> None:
    key = str(args.invitation_id)
    item = registry["entries"].get(key)
    if not isinstance(item, dict) or item.get("status") != "active":
        raise VpnUserError("invitation has no active VPN account")
    if not args.apply:
        public_result(
            action="revoke",
            apply=False,
            invitation_id=args.invitation_id,
            vpn_username=item["vpn_username"],
            mutations=False,
        )
        return
    alias = f"invitation-{args.invitation_id}"
    secret["client_users"].pop(alias, None)
    current_time = now_utc()
    item["status"] = "revoked"
    item["revoked_at"] = iso(current_time)
    item["tombstone_until"] = iso(current_time + timedelta(days=TOMBSTONE_DAYS))
    item["delivery_pending"] = False
    delivery_path = delivery_dir / f"invitation-{args.invitation_id}.json"
    if delivery_path.exists():
        if delivery_path.is_symlink() or not delivery_path.is_file():
            raise VpnUserError("refusing unsafe delivery file")
        delivery_path.unlink()
    atomic_write_json(args.secret_path, secret)
    atomic_write_json(args.registry_path, registry)
    public_result(
        action="revoke",
        apply=True,
        invitation_id=args.invitation_id,
        state="revoked-in-desired-state",
        next_step=(
            "platform_router plan; separately approved apply disconnects sessions "
            "and deletes the managed user on VPS1"
        ),
    )


def prune(args: argparse.Namespace, registry: dict[str, Any]) -> None:
    current_time = now_utc()
    expired = sorted(
        key
        for key, item in registry["entries"].items()
        if isinstance(item, dict)
        and item.get("status") == "revoked"
        and item.get("tombstone_until")
        and parse_time(str(item["tombstone_until"])) <= current_time
    )
    if args.apply:
        for key in expired:
            del registry["entries"][key]
        atomic_write_json(args.registry_path, registry)
    public_result(
        action="prune",
        apply=args.apply,
        expired_invitation_ids=[int(key) for key in expired],
        mutations=bool(args.apply and expired),
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument(
        "action",
        choices=["audit", "issue", "bind", "acknowledge", "revoke", "prune"],
    )
    result.add_argument("--invitation-id", type=int)
    result.add_argument("--product-username", default="")
    result.add_argument("--apply", action="store_true")
    result.add_argument("--operator-dir", type=Path, default=Path("operator"))
    result.add_argument("--secret-path", type=Path)
    result.add_argument("--registry-path", type=Path)
    result.add_argument("--delivery-dir", type=Path)
    return result


def main() -> int:
    args = parser().parse_args()
    if args.action in {"issue", "bind", "acknowledge", "revoke"} and (
        not args.invitation_id or args.invitation_id < 1
    ):
        raise VpnUserError("--invitation-id must be a positive integer")
    if args.action == "bind" and not args.product_username.strip():
        raise VpnUserError("--product-username is required for bind")
    if args.action == "bind" and not re.fullmatch(
        r"[\w.@+-]{1,150}", args.product_username, flags=re.UNICODE
    ):
        raise VpnUserError("--product-username has an unsafe format")

    operator_dir = args.operator_dir
    args.secret_path = args.secret_path or (
        operator_dir / "softether" / "l3-vps" / "secrets" / f"{LINK_NAME}.json"
    )
    args.registry_path = (
        args.registry_path or operator_dir / "mycleanbot" / "vpn-users.json"
    )
    delivery_dir = (
        args.delivery_dir or operator_dir / "mycleanbot" / "vpn-delivery"
    )
    assert_operator_paths(
        operator_dir, [args.secret_path, args.registry_path, delivery_dir]
    )
    secret, registry = load_state(args.secret_path, args.registry_path)
    validate_state(secret, registry)

    if args.action == "audit":
        public_result(
            action="audit",
            state="valid",
            active_accounts=len(active_entries(registry)),
            available_accounts=MANAGED_LIMIT - len(active_entries(registry)),
            protected_username=PROTECTED_USERNAME,
            secrets_exposed=False,
        )
    elif args.action == "issue":
        issue(args, secret, registry, delivery_dir)
    elif args.action == "bind":
        bind(args, registry)
    elif args.action == "acknowledge":
        acknowledge(args, registry, delivery_dir)
    elif args.action == "revoke":
        revoke(args, secret, registry, delivery_dir)
    else:
        prune(args, registry)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except VpnUserError as exc:
        raise SystemExit(f"MyCleanBot VPN user error: {exc}") from None
