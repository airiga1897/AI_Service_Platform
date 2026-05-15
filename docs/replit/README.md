# Replit session plans

This directory is a **snapshot of the current Replit-session work plan**. Each file in [`plans/`](plans) corresponds 1:1 to a project task created in this Replit session and mirrors the plan that lives under `.local/tasks/` in the working environment (which is not committed to git).

It is **not** an architecture record. Architecture decisions live in [`../adr/`](../adr/README.md).

It is **not** a runbook. Operational procedures live in [`../RUNBOOKS.md`](../RUNBOOKS.md).

## Purpose

- Make the Replit work plan reviewable in PRs and visible to anyone reading the repository on GitHub.
- Preserve the original scope ("What & Why", "Done looks like", "Out of scope", "Steps") for each task even after the task is completed and the working files in `.local/tasks/` are gone.

## Plans in this snapshot

| Plan | Title |
|------|-------|
| [`plans/01-adr-and-platform-vision-docs.md`](plans/01-adr-and-platform-vision-docs.md) | ADR и видение платформы в docs |
| [`plans/02-extend-services-yml-validator.md`](plans/02-extend-services-yml-validator.md) | Расширение валидатора `services.yml` |
| [`plans/03-render-compose-tool.md`](plans/03-render-compose-tool.md) | Реализация `tools/render-compose` |
| [`plans/04-healthcheck-tool.md`](plans/04-healthcheck-tool.md) | Реализация `tools/healthcheck` |
| [`plans/05-ci-and-precommit-integration.md`](plans/05-ci-and-precommit-integration.md) | CI и pre-commit интеграция |

## Conventions

- Filenames mirror the plan files in `.local/tasks/`.
- Plans are written in Russian (working language for this session); ADRs and the rest of `docs/` are in English.
- Plans are append-only snapshots: when scope changes, prefer a new plan file and a short note in the old one rather than rewriting history.
