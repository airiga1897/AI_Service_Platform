#!/usr/bin/env python3
"""Validate the AI Service Platform registry contract."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError as exc:  # pragma: no cover - exercised in bare environments.
    raise SystemExit(
        "PyYAML is required. Install with: python -m pip install pyyaml"
    ) from exc


ROOT = Path(__file__).resolve().parents[2]
SERVICES_YML = ROOT / "services.yml"
ENV_PREFIX_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
DB_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")

REPLIT_RESERVED_PORT = 5000
SOFTETHER_TCP_PORTS = (443, 992, 5555)
RESERVED_LOCAL_PORTS = (REPLIT_RESERVED_PORT,) + SOFTETHER_TCP_PORTS


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def warn(warnings: list[str], message: str) -> None:
    warnings.append(message)


def require_mapping(errors: list[str], value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(errors, f"{path} must be a mapping")
        return {}
    return value


def require_list(errors: list[str], value: Any, path: str) -> list[Any]:
    if not isinstance(value, list):
        fail(errors, f"{path} must be a list")
        return []
    return value


def nested_has_key(value: Any, key: str) -> bool:
    if isinstance(value, dict):
        return key in value or any(nested_has_key(child, key) for child in value.values())
    if isinstance(value, list):
        return any(nested_has_key(child, key) for child in value)
    return False


def get_dotted(data: Any, dotted_path: str) -> Any:
    cur = data
    for part in dotted_path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def validate_platform(errors: list[str], data: dict[str, Any]) -> None:
    platform = require_mapping(errors, data.get("platform"), "platform")
    source_policy = require_mapping(errors, platform.get("source_policy"), "platform.source_policy")
    if source_policy.get("source_from_git_only") is not True:
        fail(errors, "platform.source_policy.source_from_git_only must be true")
    if source_policy.get("deploy_from_archives") is not False:
        fail(errors, "platform.source_policy.deploy_from_archives must be false")
    if source_policy.get("deploy_from_git_only") is not False:
        fail(errors, "platform.source_policy.deploy_from_git_only must be false")
    if source_policy.get("preferred_deploy_artifact") != "immutable_docker_image_ref":
        fail(
            errors,
            "platform.source_policy.preferred_deploy_artifact must be immutable_docker_image_ref",
        )
    if source_policy.get("branch_names_are_build_policy_only") is not True:
        fail(errors, "platform.source_policy.branch_names_are_build_policy_only must be true")

    physical_nodes = require_mapping(
        errors, platform.get("physical_nodes"), "platform.physical_nodes"
    )
    forbidden_physical_node_fields = {
        "ip",
        "public_ip",
        "public_ip_hint",
        "hostname",
        "public_endpoint",
        "provider",
        "provider_id",
        "tariff",
        "plan",
        "os_template",
        "lifecycle_state",
    }
    expected_physical_nodes = {
        "vps-nl-qupra-01": {
            "current_alias": "VPS1",
            "country": "Netherlands",
            "city": "Amsterdam",
            "datacenter": "Qupra DC2",
        },
        "vps-kz-ahost-01": {
            "current_alias": "VPS2",
            "country": "Kazakhstan",
            "city": "Almaty",
            "datacenter": "Ahost",
        },
        "vps-ru-vps6-01": {
            "current_alias": "VPS6",
            "country": "Russia",
            "city": "Moscow",
            "datacenter": "replacement-vps6",
        },
        "vps-ru-ixcellerate-01": {
            "current_alias": "VPS3",
            "country": "Russia",
            "city": "Moscow",
            "datacenter": "IXcellerate",
        },
    }
    for node_name, expected in expected_physical_nodes.items():
        node_data = require_mapping(
            errors,
            physical_nodes.get(node_name),
            f"platform.physical_nodes.{node_name}",
        )
        for field, expected_value in expected.items():
            if node_data.get(field) != expected_value:
                fail(
                    errors,
                    f"platform.physical_nodes.{node_name}.{field} must be {expected_value!r}",
                )
        for field in forbidden_physical_node_fields:
            if field in node_data:
                fail(
                    errors,
                    f"platform.physical_nodes.{node_name}.{field} must not be stored in services.yml",
                )

    platform_roles = require_mapping(
        errors, platform.get("platform_roles"), "platform.platform_roles"
    )
    expected_roles = {
        "production-runtime": {
            "current_alias": "VPS1",
            "ansible_group": "prod",
            "active_node": "vps-nl-qupra-01",
        },
        "preprod-hot-standby-backup": {
            "current_alias": "VPS2",
            "ansible_group": "backup",
            "active_node": "vps-kz-ahost-01",
        },
        "management-monitoring-orchestration": {
            "current_alias": "VPS6",
            "ansible_group": "management",
            "active_node": "vps-ru-vps6-01",
        },
    }
    for role_name, expected in expected_roles.items():
        role_data = require_mapping(
            errors, platform_roles.get(role_name), f"platform.platform_roles.{role_name}"
        )
        for field, expected_value in expected.items():
            if role_data.get(field) != expected_value:
                fail(
                    errors,
                    f"platform.platform_roles.{role_name}.{field} must be {expected_value!r}",
                )
        for field in ("candidate_node", "old_node"):
            node_ref = role_data.get(field)
            if node_ref is not None and node_ref not in physical_nodes:
                fail(
                    errors,
                    f"platform.platform_roles.{role_name}.{field} references unknown physical node {node_ref!r}",
                )

    vpn_edge_role = require_mapping(
        errors, platform_roles.get("vpn-only-edge"), "platform.platform_roles.vpn-only-edge"
    )
    if vpn_edge_role.get("current_alias") is not None:
        fail(errors, "platform.platform_roles.vpn-only-edge.current_alias must be null")
    if vpn_edge_role.get("ansible_group") != "vpn_edges":
        fail(errors, "platform.platform_roles.vpn-only-edge.ansible_group must be 'vpn_edges'")
    for field in ("active_nodes", "candidate_nodes", "old_nodes"):
        for node_ref in require_list(
            errors, vpn_edge_role.get(field), f"platform.platform_roles.vpn-only-edge.{field}"
        ):
            if node_ref not in physical_nodes:
                fail(
                    errors,
                    f"platform.platform_roles.vpn-only-edge.{field} references unknown physical node {node_ref!r}",
                )

    vps_layout = require_mapping(errors, platform.get("vps_layout"), "platform.vps_layout")
    for node in ("VPS1", "VPS2", "VPS6"):
        node_data = require_mapping(errors, vps_layout.get(node), f"platform.vps_layout.{node}")
        for field in ("role", "country", "resources_hint", "notes"):
            if not node_data.get(field):
                fail(errors, f"platform.vps_layout.{node}.{field} is required")

    edge_vpn = require_mapping(errors, platform.get("edge_vpn"), "platform.edge_vpn")
    expected_pairs = {
        "provider": "softether",
        "status": "required-platform-component",
        "ownership": "infrastructure",
    }
    for field, expected in expected_pairs.items():
        if edge_vpn.get(field) != expected:
            fail(errors, f"platform.edge_vpn.{field} must be {expected!r}")

    if edge_vpn.get("not_owned_by_runtime_instances") is not True:
        fail(errors, "platform.edge_vpn.not_owned_by_runtime_instances must be true")
    if edge_vpn.get("preserve_during_migration") is not True:
        fail(errors, "platform.edge_vpn.preserve_during_migration must be true")

    deployment_scope = require_mapping(
        errors, edge_vpn.get("deployment_scope"), "platform.edge_vpn.deployment_scope"
    )
    target_nodes = set(
        require_list(
            errors,
            deployment_scope.get("target_nodes"),
            "platform.edge_vpn.deployment_scope.target_nodes",
        )
    )
    for node in ("VPS1", "VPS2", "VPS6"):
        if node not in target_nodes:
            fail(errors, f"platform.edge_vpn.deployment_scope.target_nodes must include {node}")
    if deployment_scope.get("bootstrap_node") not in target_nodes:
        fail(errors, "platform.edge_vpn.deployment_scope.bootstrap_node must be one of target_nodes")
    if deployment_scope.get("supports_vpn_only_expansion_nodes") is not True:
        fail(errors, "platform.edge_vpn.deployment_scope.supports_vpn_only_expansion_nodes must be true")
    expansion_contract = require_mapping(
        errors,
        deployment_scope.get("expansion_node_contract"),
        "platform.edge_vpn.deployment_scope.expansion_node_contract",
    )
    if expansion_contract.get("role") != "vpn-only-edge":
        fail(errors, "platform.edge_vpn.deployment_scope.expansion_node_contract.role must be vpn-only-edge")
    if expansion_contract.get("product_runtime_allowed") is not False:
        fail(
            errors,
            "platform.edge_vpn.deployment_scope.expansion_node_contract.product_runtime_allowed must be false",
        )

    ports = require_mapping(errors, edge_vpn.get("ports"), "platform.edge_vpn.ports")
    tcp_ports = set(require_list(errors, ports.get("tcp"), "platform.edge_vpn.ports.tcp"))
    for port in (443, 992, 5555):
        if port not in tcp_ports:
            fail(errors, f"platform.edge_vpn.ports.tcp must include {port}")
    if "udp" in ports:
        fail(errors, "platform.edge_vpn.ports.udp must not describe current listeners")
    future_udp = require_mapping(
        errors,
        ports.get("future_optional_udp"),
        "platform.edge_vpn.ports.future_optional_udp",
    )
    future_udp_ports = set(
        require_list(
            errors,
            future_udp.get("ports"),
            "platform.edge_vpn.ports.future_optional_udp.ports",
        )
    )
    for port in (500, 4500, 1701):
        if port not in future_udp_ports:
            fail(errors, f"platform.edge_vpn.ports.future_optional_udp.ports must include {port}")

    publish_model = require_mapping(
        errors, edge_vpn.get("publish_model"), "platform.edge_vpn.publish_model"
    )
    expected_publish = {
        "external_owner": "haproxy",
        "softether_container_publish_directly": False,
        "softether_container_visibility": "docker-network-only",
        "udp_domain_routing_supported": False,
        "udp_currently_enabled": False,
    }
    for field, expected in expected_publish.items():
        if publish_model.get(field) != expected:
            fail(errors, f"platform.edge_vpn.publish_model.{field} must be {expected!r}")
    routing = require_mapping(
        errors, publish_model.get("routing"), "platform.edge_vpn.publish_model.routing"
    )
    for route in ("443/tcp", "992/tcp", "5555/tcp"):
        if route not in routing:
            fail(errors, f"platform.edge_vpn.publish_model.routing must include {route}")

    volumes = require_mapping(errors, edge_vpn.get("volumes"), "platform.edge_vpn.volumes")
    if volumes.get("config") != "softether_data":
        fail(errors, "platform.edge_vpn.volumes.config must be softether_data")
    if volumes.get("logs") != "softether_logs":
        fail(errors, "platform.edge_vpn.volumes.logs must be softether_logs")

    backup_scope = set(require_list(errors, edge_vpn.get("backup_scope"), "platform.edge_vpn.backup_scope"))
    for item in ("softether_data", "softether_logs", "certbot_conf", "haproxy_vpn_routing"):
        if item not in backup_scope:
            fail(errors, f"platform.edge_vpn.backup_scope must include {item}")

    legacy_edge = require_mapping(
        errors, platform.get("legacy_edge_colocation"), "platform.legacy_edge_colocation"
    )
    legacy_containers = set(
        require_list(errors, legacy_edge.get("containers"), "platform.legacy_edge_colocation.containers")
    )
    if "softether" not in legacy_containers:
        fail(errors, "platform.legacy_edge_colocation.containers must record historical softether")

    geo_policy = require_mapping(errors, platform.get("geo_policy"), "platform.geo_policy")
    if geo_policy.get("status") != "planned-shared-platform-service":
        fail(errors, "platform.geo_policy.status must be planned-shared-platform-service")
    outputs = set(require_list(errors, geo_policy.get("data_outputs"), "platform.geo_policy.data_outputs"))
    for output in (
        "haproxy_country_lists",
        "vpn_geodns_targets",
        "egress_country_rules",
        "cdn_country_policy_inputs",
    ):
        if output not in outputs:
            fail(errors, f"platform.geo_policy.data_outputs must include {output}")

    site_cdn = require_mapping(errors, platform.get("site_cdn"), "platform.site_cdn")
    if site_cdn.get("status") != "future-optional":
        fail(errors, "platform.site_cdn.status must be future-optional")
    excluded = set(require_list(errors, site_cdn.get("does_not_apply_to"), "platform.site_cdn.does_not_apply_to"))
    if "softether-vpn-through-standard-web-cdn" not in excluded:
        fail(
            errors,
            "platform.site_cdn.does_not_apply_to must include softether-vpn-through-standard-web-cdn",
        )

    vpn_acceleration = require_mapping(errors, platform.get("vpn_acceleration"), "platform.vpn_acceleration")
    if vpn_acceleration.get("status") != "future-research":
        fail(errors, "platform.vpn_acceleration.status must be future-research")
    if vpn_acceleration.get("not_standard_site_cdn") is not True:
        fail(errors, "platform.vpn_acceleration.not_standard_site_cdn must be true")


def validate_projects(errors: list[str], data: dict[str, Any]) -> None:
    projects = require_mapping(errors, data.get("projects"), "projects")
    for project_name, project in projects.items():
        project_data = require_mapping(errors, project, f"projects.{project_name}")
        source = require_mapping(errors, project_data.get("source"), f"projects.{project_name}.source")
        for field in ("repository", "bootstrap_ref"):
            if not source.get(field):
                fail(errors, f"projects.{project_name}.source.{field} is required")

        stable = require_mapping(
            errors, source.get("stable_branches"), f"projects.{project_name}.source.stable_branches"
        )
        for field in ("development", "production"):
            if not stable.get(field):
                fail(errors, f"projects.{project_name}.source.stable_branches.{field} is required")

        deploy_refs = require_mapping(
            errors, source.get("deploy_refs"), f"projects.{project_name}.source.deploy_refs"
        )
        if deploy_refs.get("preferred") != "image_ref":
            fail(errors, f"projects.{project_name}.source.deploy_refs.preferred must be image_ref")
        allowed = require_list(
            errors,
            deploy_refs.get("allowed_source_refs"),
            f"projects.{project_name}.source.deploy_refs.allowed_source_refs",
        )
        if source.get("bootstrap_ref") and source["bootstrap_ref"] not in allowed:
            fail(errors, f"projects.{project_name}.source.bootstrap_ref must be an allowed source ref")


def expected_env_prefix(instance_name: str) -> str:
    return instance_name.replace("-", "_").upper()


def validate_regex_pattern(errors: list[str], pattern: Any, path: str) -> bool:
    if not isinstance(pattern, str) or not pattern.strip():
        fail(errors, f"{path} is required and must be a non-empty string")
        return False
    try:
        re.compile(pattern)
    except re.error as exc:
        fail(errors, f"{path} is not a valid regex: {exc}")
        return False
    return True


def validate_instance_deploy(
    errors: list[str],
    instance_name: str,
    deploy: dict[str, Any],
    valid_vps: set[str],
    node_path: str,
) -> None:
    allowed_pattern = deploy.get("allowed_image_ref_pattern")
    if not validate_regex_pattern(
        errors, allowed_pattern, f"{node_path}.deploy.allowed_image_ref_pattern"
    ):
        allowed_pattern = None

    release_guard = deploy.get("release_guard")
    frozen = deploy.get("frozen")
    frozen_pattern = deploy.get("frozen_image_ref_pattern")
    if release_guard is not None:
        if release_guard != "immutable-released-image":
            fail(errors, f"{node_path}.deploy.release_guard must be immutable-released-image")
        if "frozen" in deploy or "frozen_image_ref_pattern" in deploy:
            fail(errors, f"{node_path}.deploy must not mix release_guard with legacy frozen fields")
        if isinstance(allowed_pattern, str) and "@sha256:" not in allowed_pattern:
            fail(errors, f"{node_path}.deploy.allowed_image_ref_pattern must be digest-only")
    elif frozen is not True and frozen is not False:
        fail(errors, f"{node_path}.deploy.frozen must be a boolean")
        frozen = False

    if release_guard is None and frozen is True:
        if not validate_regex_pattern(
            errors,
            frozen_pattern,
            f"{node_path}.deploy.frozen_image_ref_pattern",
        ):
            frozen_pattern = None
        elif allowed_pattern and frozen_pattern:
            try:
                allowed_re = re.compile(allowed_pattern)
                frozen_re = re.compile(frozen_pattern)
                if not allowed_re.pattern == frozen_re.pattern:
                    fail(
                        errors,
                        f"{node_path}.deploy.allowed_image_ref_pattern must match"
                        f" frozen_image_ref_pattern when frozen is true",
                    )
            except re.error:
                pass
    elif release_guard is None and frozen_pattern not in (None, False, ""):
        fail(
            errors,
            f"{node_path}.deploy.frozen_image_ref_pattern must be null when frozen is false",
        )

    environments = require_mapping(
        errors, deploy.get("environments"), f"{node_path}.deploy.environments"
    )
    stack_prefix = f"infra/stacks/{instance_name}/"
    for env_name, env_cfg in environments.items():
        env_path = f"{node_path}.deploy.environments.{env_name}"
        if isinstance(env_cfg, str):
            fail(
                errors,
                f"{env_path} must be a mapping with vps, compose_file, deploy_dir,"
                f" deploy_state_tag_prefix (got legacy VPS string {env_cfg!r})",
            )
            continue
        env_data = require_mapping(errors, env_cfg, env_path)
        vps = env_data.get("vps")
        if vps not in valid_vps:
            fail(errors, f"{env_path}.vps targets unknown {vps!r}")
        compose_file = env_data.get("compose_file")
        if not isinstance(compose_file, str) or not compose_file.startswith(stack_prefix):
            fail(
                errors,
                f"{env_path}.compose_file must start with {stack_prefix!r}",
            )
        if not env_data.get("deploy_dir"):
            fail(errors, f"{env_path}.deploy_dir is required")
        tag_prefix = env_data.get("deploy_state_tag_prefix")
        expected_tag = f"deploy/{instance_name}/{env_name}/"
        if not isinstance(tag_prefix, str) or not tag_prefix.startswith(expected_tag):
            fail(
                errors,
                f"{env_path}.deploy_state_tag_prefix must start with {expected_tag!r}",
            )


def expected_env_file_stems(instance_name: str) -> tuple[str, str] | None:
    """Return (env_file, env_example_file) following the project.role naming scheme.

    Splits instance name on the last hyphen so ``aromaflow-work`` becomes
    ``aromaflow.work`` and ``ai-retail-mvp`` becomes ``ai-retail.mvp``.
    """
    if "-" not in instance_name:
        return None
    project, _, role = instance_name.rpartition("-")
    base = f".env.{project}.{role}"
    return base, f"{base}.example"


def validate_runtime_instances(
    errors: list[str], warnings: list[str], data: dict[str, Any]
) -> None:
    platform = require_mapping(errors, data.get("platform"), "platform")
    valid_vps = set(require_mapping(errors, platform.get("vps_layout"), "platform.vps_layout").keys())
    instances = require_mapping(errors, data.get("runtime_instances"), "runtime_instances")
    template = data.get("future_service_template") or {}

    seen_ports: dict[int, str] = {}
    seen_domains: dict[str, str] = {}
    seen_databases: dict[str, str] = {}

    for instance_name, instance in instances.items():
        node_path = f"runtime_instances.{instance_name}"
        instance_data = require_mapping(errors, instance, node_path)

        if nested_has_key(instance_data, "edge_vpn"):
            fail(errors, f"{node_path} must not define edge_vpn")

        current_containers = instance_data.get("containers", {}).get("current", [])
        if isinstance(current_containers, list) and "softether" in current_containers:
            fail(errors, f"{node_path}.containers.current must not include softether")

        for field in ("project", "profile", "role"):
            if not instance_data.get(field):
                fail(errors, f"{node_path}.{field} is required")

        # ---- env block ---------------------------------------------------
        env = require_mapping(errors, instance_data.get("env"), f"{node_path}.env")
        prefix = env.get("prefix")
        if not isinstance(prefix, str) or not ENV_PREFIX_RE.fullmatch(prefix):
            fail(errors, f"{node_path}.env.prefix must be uppercase snake case")
        else:
            wanted_prefix = expected_env_prefix(instance_name)
            if prefix != wanted_prefix:
                fail(
                    errors,
                    f"{node_path}.env.prefix must be {wanted_prefix!r} to match the instance name",
                )
        for field in ("file", "example_file"):
            if not env.get(field):
                fail(errors, f"{node_path}.env.{field} is required")
        wanted_files = expected_env_file_stems(instance_name)
        if wanted_files is not None:
            wanted_file, wanted_example = wanted_files
            if env.get("file") and env.get("file") != wanted_file:
                fail(
                    errors,
                    f"{node_path}.env.file must be {wanted_file!r} to match the instance name",
                )
            if env.get("example_file") and env.get("example_file") != wanted_example:
                fail(
                    errors,
                    f"{node_path}.env.example_file must be {wanted_example!r} to match the instance name",
                )

        # ---- healthcheck -------------------------------------------------
        healthcheck = require_mapping(
            errors, instance_data.get("healthcheck"), f"{node_path}.healthcheck"
        )
        path_value = healthcheck.get("path")
        if not isinstance(path_value, str) or not path_value:
            fail(errors, f"{node_path}.healthcheck.path is required")
        elif not path_value.startswith("/"):
            fail(errors, f"{node_path}.healthcheck.path must start with '/'")

        status_value = healthcheck.get("expected_status")
        if not isinstance(status_value, int) or isinstance(status_value, bool):
            fail(errors, f"{node_path}.healthcheck.expected_status must be an integer")
        elif not 100 <= status_value <= 599:
            fail(
                errors,
                f"{node_path}.healthcheck.expected_status must be between 100 and 599",
            )

        timeout_value = healthcheck.get("timeout_seconds")
        if isinstance(timeout_value, bool) or not isinstance(timeout_value, (int, float)):
            fail(errors, f"{node_path}.healthcheck.timeout_seconds must be a positive number")
        elif timeout_value <= 0:
            fail(errors, f"{node_path}.healthcheck.timeout_seconds must be a positive number")

        # ---- deploy contract --------------------------------------------
        deploy = require_mapping(errors, instance_data.get("deploy"), f"{node_path}.deploy")
        validate_instance_deploy(errors, instance_name, deploy, valid_vps, node_path)

        site_runtime = instance_data.get("site_runtime")
        if site_runtime is not None:
            runtime_path = f"{node_path}.site_runtime"
            runtime = require_mapping(errors, site_runtime, runtime_path)
            repository = runtime.get("image_repository")
            if not isinstance(repository, str) or not re.fullmatch(r"[a-z0-9.-]+(?:/[a-z0-9._-]+)+", repository):
                fail(errors, f"{runtime_path}.image_repository must be a normalized repository")
            if runtime.get("platform") != "linux/amd64":
                fail(errors, f"{runtime_path}.platform must be linux/amd64 in v1")
            if runtime.get("release_guard") != "immutable-released-image":
                fail(errors, f"{runtime_path}.release_guard must be immutable-released-image")
            if runtime.get("entrypoint_override") != []:
                fail(errors, f"{runtime_path}.entrypoint_override must be an empty list")
            support_images = require_mapping(errors, runtime.get("support_images"), f"{runtime_path}.support_images")
            if support_images != {"redis": "redis:7-alpine", "nginx": "nginx:alpine"}:
                fail(errors, f"{runtime_path}.support_images must contain redis:7-alpine and nginx:alpine")
            volumes = require_mapping(errors, runtime.get("volumes"), f"{runtime_path}.volumes")
            if set(volumes) != {"redis"}:
                fail(errors, f"{runtime_path}.volumes должен содержать только redis")
            for volume_name, volume_value in volumes.items():
                if not isinstance(volume_value, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]+", volume_value):
                    fail(errors, f"{runtime_path}.volumes.{volume_name} must be a normalized Docker volume name")

            storage = require_mapping(errors, runtime.get("storage"), f"{runtime_path}.storage")
            expected_storage = {
                "release_static": {
                    "lifecycle": "release",
                    "container_path": "/app/staticfiles",
                    "runtime_access": "read-only",
                    "nginx": True,
                    "name_field": "volume_prefix",
                },
                "public_media": {
                    "lifecycle": "persistent",
                    "container_path": "/app/media",
                    "runtime_access": "read-write",
                    "nginx": True,
                    "name_field": "volume",
                },
                "private_media": {
                    "lifecycle": "persistent",
                    "container_path": "/app/private_media",
                    "runtime_access": "read-write",
                    "nginx": False,
                    "name_field": "volume",
                },
            }
            if set(storage) != set(expected_storage):
                fail(
                    errors,
                    f"{runtime_path}.storage должен содержать release_static, public_media и private_media",
                )
            storage_names = [volumes.get("redis")]
            for storage_name, expected in expected_storage.items():
                storage_path = f"{runtime_path}.storage.{storage_name}"
                storage_class = require_mapping(errors, storage.get(storage_name), storage_path)
                expected_fields = {
                    "lifecycle",
                    "container_path",
                    "runtime_access",
                    "nginx",
                    expected["name_field"],
                }
                if set(storage_class) != expected_fields:
                    fail(errors, f"{storage_path} должен содержать только поля: {', '.join(sorted(expected_fields))}")
                for field in ("lifecycle", "container_path", "runtime_access", "nginx"):
                    if storage_class.get(field) != expected[field]:
                        fail(errors, f"{storage_path}.{field} должен быть {expected[field]!r}")
                volume_value = storage_class.get(expected["name_field"])
                if not isinstance(volume_value, str) or not re.fullmatch(
                    r"[a-z0-9][a-z0-9_-]+", volume_value
                ):
                    fail(
                        errors,
                        f"{storage_path}.{expected['name_field']} должен быть нормализованным именем Docker volume",
                    )
                storage_names.append(volume_value)
            normalized_storage_names = [name for name in storage_names if isinstance(name, str)]
            if len(normalized_storage_names) != len(set(normalized_storage_names)):
                fail(errors, f"Имена {runtime_path} storage и Redis volume не должны совпадать")
            components = require_mapping(errors, runtime.get("components"), f"{runtime_path}.components")
            for component in ("static", "web", "worker", "beat", "migration"):
                command = (components.get(component) or {}).get("command") if isinstance(components.get(component), dict) else None
                if not isinstance(command, str) or not command.strip():
                    fail(errors, f"{runtime_path}.components.{component}.command is required")
            health_contract = require_mapping(errors, runtime.get("health"), f"{runtime_path}.health")
            for health_name in ("live", "ready", "worker"):
                health_path = health_contract.get(health_name)
                if not isinstance(health_path, str) or not health_path.startswith("/"):
                    fail(errors, f"{runtime_path}.health.{health_name} must start with '/'")

        # ---- local ports -------------------------------------------------
        local = instance_data.get("local") or {}
        if isinstance(local, dict):
            for port_field in ("backend_port", "frontend_port"):
                port_value = local.get(port_field)
                if port_value is None:
                    continue
                port_path = f"{node_path}.local.{port_field}"
                if isinstance(port_value, bool) or not isinstance(port_value, int):
                    fail(errors, f"{port_path} must be an integer")
                    continue
                if not 1 <= port_value <= 65535:
                    fail(errors, f"{port_path} must be between 1 and 65535")
                    continue
                if port_value in seen_ports:
                    fail(
                        errors,
                        f"{port_path} duplicates port {port_value} already used by {seen_ports[port_value]}",
                    )
                else:
                    seen_ports[port_value] = port_path
                if port_value in RESERVED_LOCAL_PORTS:
                    if port_value == REPLIT_RESERVED_PORT:
                        warn(
                            warnings,
                            f"{port_path}={port_value} collides with the Replit web preview reserved port",
                        )
                    else:
                        warn(
                            warnings,
                            f"{port_path}={port_value} collides with a SoftEther TCP listener port",
                        )

        # ---- domain uniqueness ------------------------------------------
        domains = instance_data.get("domains") or {}
        if isinstance(domains, dict):
            for scope in ("preprod", "prod"):
                values = domains.get(scope) or []
                if not isinstance(values, list):
                    continue
                for entry in values:
                    if not isinstance(entry, str) or not entry:
                        continue
                    domain_path = f"{node_path}.domains.{scope}[{entry}]"
                    if entry in seen_domains:
                        fail(
                            errors,
                            f"{domain_path} duplicates domain {entry!r} already used by {seen_domains[entry]}",
                        )
                    else:
                        seen_domains[entry] = domain_path

        # ---- postgres database name -------------------------------------
        data_block = instance_data.get("data") or {}
        if isinstance(data_block, dict):
            db_name = data_block.get("database")
            if db_name is not None:
                db_path = f"{node_path}.data.database"
                if not isinstance(db_name, str) or not DB_NAME_RE.fullmatch(db_name):
                    fail(
                        errors,
                        f"{db_path} must match ^[a-z][a-z0-9_]*$ (got {db_name!r})",
                    )
                elif db_name in seen_databases:
                    fail(
                        errors,
                        f"{db_path} duplicates database {db_name!r} already used by {seen_databases[db_name]}",
                    )
                else:
                    seen_databases[db_name] = db_path

        # ---- future_service_template required fields --------------------
        instance_type = instance_data.get("type")
        if instance_type in ("site", "telegram-bot"):
            # Support both the short key (`site` / `bot`) and the long key
            # (`site` / `telegram-bot`) under future_service_template, so the
            # registry can evolve without breaking this validator.
            candidate_keys: tuple[str, ...]
            if instance_type == "site":
                candidate_keys = ("site",)
            else:
                candidate_keys = ("telegram-bot", "bot")

            tpl = None
            template_key = candidate_keys[0]
            if isinstance(template, dict):
                for key in candidate_keys:
                    if isinstance(template.get(key), dict):
                        tpl = template[key]
                        template_key = key
                        break

            if isinstance(tpl, dict):
                required = tpl.get("required") or []
                if isinstance(required, list):
                    for required_path in required:
                        if not isinstance(required_path, str):
                            continue
                        if get_dotted(instance_data, required_path) in (None, "", [], {}):
                            fail(
                                errors,
                                f"{node_path}.{required_path} is required for type={instance_type!r}"
                                f" (per future_service_template.{template_key}.required)",
                            )


def validate_data(data: Any) -> tuple[list[str], list[str]]:
    """Run every check against an in-memory registry dict.

    Returns a (errors, warnings) tuple. Used by the CLI and the test suite.
    """
    errors: list[str] = []
    warnings: list[str] = []

    registry = require_mapping(errors, data, "services.yml")
    if registry.get("version") != 2:
        fail(errors, "version must be 2")

    validate_platform(errors, registry)
    validate_projects(errors, registry)
    validate_runtime_instances(errors, warnings, registry)

    return errors, warnings


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the AI Service Platform services.yml registry contract.",
    )
    parser.add_argument(
        "path",
        nargs="?",
        type=Path,
        default=SERVICES_YML,
        help="Path to services.yml (default: repository root services.yml).",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat warnings as errors (non-zero exit code on any warning).",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    target = args.path

    if not target.exists():
        print(f"Missing {target}", file=sys.stderr)
        return 1

    with target.open("r", encoding="utf-8-sig") as handle:
        data = yaml.safe_load(handle)

    errors, warnings = validate_data(data)

    if warnings:
        stream = sys.stderr if args.strict else sys.stdout
        label = "warnings (treated as errors)" if args.strict else "warnings"
        print(f"services.yml {label}:", file=stream)
        for warning in warnings:
            print(f"- {warning}", file=stream)

    if errors:
        print("services.yml validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    if args.strict and warnings:
        return 1

    print("services.yml validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
