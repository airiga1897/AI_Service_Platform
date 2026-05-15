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
- **Python deps:** `pyyaml` (used by the validator).
- **Workflow:** `Validate services.yml` runs `python3 tools/validate-services-yml/validate_services_yml.py`. It is a console workflow (one-shot), not a server. There is no port to expose and no web preview.
- **Deployment:** Not configured. There is no application to deploy from this repo; real deploys are performed by the GitHub Actions workflows in `.github/workflows/` against external VPS hosts.

## User preferences

- (none recorded yet)
