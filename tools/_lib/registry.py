"""Общий загрузчик реестра ``services.yml`` для AI Service Platform.

Модуль намеренно маленький: это единственное место, где платформенные
инструменты (валидатор, render-compose, healthcheck, …) читают реестр —
так все они видят одну и ту же форму словаря.

Валидатор был написан раньше этого помощника и сохраняет собственные
константы ``ROOT`` / ``SERVICES_YML`` ради обратной совместимости.
Новые инструменты должны использовать :func:`load_registry`.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SERVICES_YML = REPO_ROOT / "services.yml"


def load_registry(path: Path | str | None = None) -> dict[str, Any]:
    """Загрузить и распарсить ``services.yml``.

    Параметры
    ---------
    path:
        Опциональный путь до реестра. По умолчанию используется
        канонический ``services.yml`` в корне репозитория. Бросает
        ``FileNotFoundError``, если файл не найден.
    """
    target = Path(path) if path is not None else DEFAULT_SERVICES_YML
    if not target.exists():
        raise FileNotFoundError(f"services.yml not found at {target}")
    with target.open("r", encoding="utf-8-sig") as handle:
        data = yaml.safe_load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{target} did not parse to a mapping")
    return data


def runtime_instances(registry: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Вернуть блок ``runtime_instances`` как словарь."""
    instances = registry.get("runtime_instances") or {}
    if not isinstance(instances, dict):
        raise ValueError("runtime_instances must be a mapping")
    return instances


def projects(registry: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Вернуть блок ``projects`` как словарь."""
    block = registry.get("projects") or {}
    if not isinstance(block, dict):
        raise ValueError("projects must be a mapping")
    return block
