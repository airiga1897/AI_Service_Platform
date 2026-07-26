#!/usr/bin/env python3
"""Validation and environment resolution for portable project contracts."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml


class ProjectContractError(ValueError):
    """The project-owned deployment contract is invalid."""


ENVIRONMENT_CLASSES = ("runtime", "secrets", "platform_owned", "local_only")
REQUIRED_COMPONENTS = ("static", "migration", "web", "worker", "beat")
REQUIRED_HEALTH = ("live", "ready", "worker")


def read_env(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    text = path.read_text(encoding="utf-8-sig").lstrip("\ufeff")
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ProjectContractError(f"{path}:{number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or not key.replace("_", "A").isalnum() or key[0].isdigit():
            raise ProjectContractError(f"{path}:{number}: invalid environment key")
        if key in result:
            raise ProjectContractError(f"{path}:{number}: duplicate environment key {key}")
        result[key] = value.strip()
    return result


def _string_list(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise ProjectContractError(f"{label} must be a list of non-empty strings")
    if len(value) != len(set(value)):
        raise ProjectContractError(f"{label} contains duplicates")
    return tuple(value)


@dataclass(frozen=True)
class ProjectContract:
    runtime: tuple[str, ...]
    secrets: tuple[str, ...]
    platform_owned: tuple[str, ...]
    local_only: tuple[str, ...]
    bootstrap: dict[str, dict[str, Any]]
    frontend_endpoint: str
    components: dict[str, str]
    health: dict[str, str]

    @property
    def application_keys(self) -> tuple[str, ...]:
        return self.runtime + self.secrets

    @property
    def classified_keys(self) -> tuple[str, ...]:
        bootstrap = tuple(
            key for spec in self.bootstrap.values() for key in spec["environment"]
        )
        return self.application_keys + self.platform_owned + self.local_only + bootstrap


def load_contract(path: Path) -> ProjectContract:
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        raise ProjectContractError(f"cannot read project contract: {exc}") from exc
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise ProjectContractError("project contract schema_version must be 1")
    application = document.get("application")
    if not isinstance(application, dict):
        raise ProjectContractError("application must be a mapping")
    environment = application.get("environment")
    if not isinstance(environment, dict):
        raise ProjectContractError("application.environment must be a mapping")

    classes = {
        name: _string_list(environment.get(name), f"application.environment.{name}")
        for name in ENVIRONMENT_CLASSES
    }
    classified: dict[str, str] = {}
    for class_name, keys in classes.items():
        for key in keys:
            previous = classified.setdefault(key, class_name)
            if previous != class_name:
                raise ProjectContractError(
                    f"environment key {key} belongs to both {previous} and {class_name}"
                )

    bootstrap = environment.get("bootstrap")
    if not isinstance(bootstrap, dict) or not bootstrap:
        raise ProjectContractError("application.environment.bootstrap must be a non-empty mapping")
    normalized_bootstrap: dict[str, dict[str, Any]] = {}
    for operation, spec in bootstrap.items():
        if not isinstance(operation, str) or not operation or not isinstance(spec, dict):
            raise ProjectContractError("bootstrap operations must be named mappings")
        command = spec.get("command")
        if not isinstance(command, str) or not command.strip():
            raise ProjectContractError(f"bootstrap.{operation}.command must be non-empty")
        check_command = spec.get("check_command")
        if check_command is not None and (
            not isinstance(check_command, str) or not check_command.strip()
        ):
            raise ProjectContractError(f"bootstrap.{operation}.check_command must be non-empty")
        keys = _string_list(spec.get("environment"), f"bootstrap.{operation}.environment")
        collisions = sorted(set(keys).intersection(classified))
        if collisions:
            raise ProjectContractError(
                f"bootstrap.{operation} keys collide with persistent environment: {', '.join(collisions)}"
            )
        normalized_bootstrap[operation] = {
            "command": command.strip(),
            "environment": keys,
            **({"check_command": check_command.strip()} if check_command is not None else {}),
        }

    frontend = application.get("frontend")
    if not isinstance(frontend, dict) or frontend.get("configuration") != "runtime":
        raise ProjectContractError("application.frontend.configuration must be runtime")
    endpoint = frontend.get("public_endpoint")
    if not isinstance(endpoint, str) or not endpoint.startswith("/") or "?" in endpoint:
        raise ProjectContractError("application.frontend.public_endpoint must be an absolute path")

    components = application.get("components")
    if not isinstance(components, dict):
        raise ProjectContractError("application.components must be a mapping")
    component_commands: dict[str, str] = {}
    for name in REQUIRED_COMPONENTS:
        command = components.get(name)
        if not isinstance(command, str) or not command.strip():
            raise ProjectContractError(f"application.components.{name} must be non-empty")
        component_commands[name] = command.strip()

    health = application.get("health")
    if not isinstance(health, dict):
        raise ProjectContractError("application.health must be a mapping")
    health_paths: dict[str, str] = {}
    for name in REQUIRED_HEALTH:
        path_value = health.get(name)
        if not isinstance(path_value, str) or not path_value.startswith("/"):
            raise ProjectContractError(f"application.health.{name} must be an absolute path")
        health_paths[name] = path_value

    return ProjectContract(
        runtime=classes["runtime"],
        secrets=classes["secrets"],
        platform_owned=classes["platform_owned"],
        local_only=classes["local_only"],
        bootstrap=normalized_bootstrap,
        frontend_endpoint=endpoint,
        components=component_commands,
        health=health_paths,
    )


def resolve_application_environment(
    contract: ProjectContract,
    source: dict[str, str],
    current: dict[str, str],
) -> dict[str, str]:
    """Merge project application values while preserving established secrets."""

    result: dict[str, str] = {}
    for key in contract.runtime:
        value = source.get(key, "")
        if value != "":
            result[key] = value
        elif current.get(key, "") != "":
            result[key] = current[key]
    for key in contract.secrets:
        if current.get(key, "") != "":
            result[key] = current[key]
        elif source.get(key, "") != "":
            result[key] = source[key]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, required=True)
    args = parser.parse_args()
    contract = load_contract(args.contract)
    print(
        json.dumps(
            {
                "schema_version": 1,
                "frontend_endpoint": contract.frontend_endpoint,
                "bootstrap_operations": sorted(contract.bootstrap),
                "environment_key_counts": {
                    "runtime": len(contract.runtime),
                    "secrets": len(contract.secrets),
                    "platform_owned": len(contract.platform_owned),
                    "local_only": len(contract.local_only),
                },
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
