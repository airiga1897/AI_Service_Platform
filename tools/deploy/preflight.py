#!/usr/bin/env python3
"""Deploy preflight: resolve and validate deploy metadata from services.yml."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "_lib"))

from registry import DEFAULT_SERVICES_YML, load_registry, runtime_instances  # noqa: E402


class PreflightError(Exception):
    """Validation failure for deploy preflight."""


def _require_mapping(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PreflightError(f"{path} must be a mapping")
    return value


def _validate_image_ref(image_ref: str, pattern: str, label: str) -> None:
    try:
        compiled = re.compile(pattern)
    except re.error as exc:
        raise PreflightError(f"{label} is not a valid regex: {exc}") from exc
    if not compiled.fullmatch(image_ref):
        raise PreflightError(
            f"image_ref {image_ref!r} does not match {label} ({pattern!r})"
        )


def resolve_preflight(
    registry: dict[str, Any],
    instance: str,
    environment: str,
    image_ref: str,
) -> dict[str, str]:
    instances = runtime_instances(registry)
    if instance not in instances:
        raise PreflightError(f"unknown runtime instance {instance!r}")

    instance_data = _require_mapping(
        instances[instance], f"runtime_instances.{instance}"
    )
    deploy = _require_mapping(instance_data.get("deploy"), f"{instance}.deploy")

    allowed_pattern = deploy.get("allowed_image_ref_pattern")
    if not isinstance(allowed_pattern, str) or not allowed_pattern:
        raise PreflightError(f"{instance}.deploy.allowed_image_ref_pattern is required")

    _validate_image_ref(
        image_ref, allowed_pattern, f"{instance}.deploy.allowed_image_ref_pattern"
    )

    if deploy.get("frozen") is True:
        frozen_pattern = deploy.get("frozen_image_ref_pattern")
        if not isinstance(frozen_pattern, str) or not frozen_pattern:
            raise PreflightError(
                f"{instance}.deploy.frozen_image_ref_pattern is required when frozen is true"
            )
        _validate_image_ref(
            image_ref,
            frozen_pattern,
            f"{instance}.deploy.frozen_image_ref_pattern",
        )

    environments = _require_mapping(deploy.get("environments"), f"{instance}.deploy.environments")
    if environment not in environments:
        raise PreflightError(
            f"environment {environment!r} is not configured for instance {instance!r}"
        )

    env_cfg = environments[environment]
    if isinstance(env_cfg, str):
        raise PreflightError(
            f"{instance}.deploy.environments.{environment} uses legacy VPS string;"
            " expected mapping with vps, compose_file, deploy_dir, deploy_state_tag_prefix"
        )

    env_data = _require_mapping(
        env_cfg, f"{instance}.deploy.environments.{environment}"
    )
    for field in ("vps", "compose_file", "deploy_dir", "deploy_state_tag_prefix"):
        value = env_data.get(field)
        if not isinstance(value, str) or not value:
            raise PreflightError(
                f"{instance}.deploy.environments.{environment}.{field} is required"
            )

    return {
        "instance": instance,
        "environment": environment,
        "image_ref": image_ref,
        "vps": env_data["vps"],
        "compose_file": env_data["compose_file"],
        "deploy_dir": env_data["deploy_dir"],
        "deploy_state_tag_prefix": env_data["deploy_state_tag_prefix"],
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate deploy inputs and emit resolved deploy metadata as JSON.",
    )
    parser.add_argument("--instance", required=True, help="Runtime instance name")
    parser.add_argument("--environment", required=True, help="Deploy environment name")
    parser.add_argument("--image-ref", required=True, dest="image_ref", help="Docker image ref")
    parser.add_argument(
        "--registry",
        type=Path,
        default=DEFAULT_SERVICES_YML,
        help="Path to services.yml (default: repository root)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        registry = load_registry(args.registry)
        metadata = resolve_preflight(
            registry, args.instance, args.environment, args.image_ref
        )
    except (FileNotFoundError, ValueError, PreflightError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    json.dump(metadata, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
