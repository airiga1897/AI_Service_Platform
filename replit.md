# AI Service Platform

## Overview

This repository is **infra/orchestration only**. It does not contain a runnable application (no frontend, no backend service). Product source code lives in separate repositories (`airiga1897/AromaFlowAI`, `airiga1897/AI_E_Retail`).

What is in this repo:

- `services.yml` — platform service registry (source of truth for runtime instances, env prefixes, edge routing, healthchecks, deploy targets).
- `infra/` — Ansible playbooks and edge configs (HAProxy, per-site Nginx, SoftEther) plus per-stack Compose files.
- `tools/validate-services-yml/` — Python validator for `services.yml`.
- `tools/healthcheck/`, `tools/render-compose/` — placeholder tool directories.
- `.github/workflows/` — CI for validate / deploy / rollback.
- `docs/` — architecture, deployment, CDN/Geo, SoftEther VPN, runbooks, etc.

## Replit setup

- **Language runtime:** Python 3.11 (installed as a Replit module).
- **Python deps:** `pyyaml` (validator + render-compose loader), `jinja2` (render-compose templates). Healthcheck использует только стандартную библиотеку.
- **Workflow:** `Validate services.yml` runs `make check` — это валидатор `services.yml`, проверка дрейфа `render-compose --check` и smoke-тесты всех инструментов (`validate-services-yml`, `render-compose`, `healthcheck`). Это console workflow (one-shot), не сервер. Порт не экспонируется, web preview нет.
- **CI / pre-commit:** `.github/workflows/validate.yml` повторяет `make check` на каждом PR/push. Локальные pre-commit хуки описаны в `.pre-commit-config.yaml` и `docs/CI_CD.md`.
- **Deployment:** Not configured. There is no application to deploy from this repo; real deploys are performed by the GitHub Actions workflows in `.github/workflows/` against external VPS hosts.

## User preferences

- Документация, описания (docstrings) и комментарии в коде, README-файлах
  и шаблонах должны быть на русском языке. Имена идентификаторов,
  CLI-флагов, ключей конфигурации, имена сервисов и сообщения об ошибках
  валидаторов остаются на английском (международный технический контракт
  и стабильность тестов).
- Конвенция расширения yaml-файлов в репозитории — `.yml`. Единственное
  обоснованное исключение — `.pre-commit-config.yaml`: это канонический
  путь, по которому утилита `pre-commit` ищет конфиг. Менять его нельзя
  без флага `--config` в каждом вызове, что ломает дефолтную интеграцию.
  Файлы под `.local/skills/**/*.yaml` — служебные файлы Replit и не
  входят в нашу зону ответственности.
