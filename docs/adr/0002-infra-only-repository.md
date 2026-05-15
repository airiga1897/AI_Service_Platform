# 0002. This repository is infra/orchestration only

- **Status:** Accepted
- **Date:** 2026-05-15

## Context

Two product codebases exist in separate GitHub repositories:

- [`airiga1897/AromaFlowAI`](https://github.com/airiga1897/AromaFlowAI)
- [`airiga1897/AI_E_Retail`](https://github.com/airiga1897/AI_E_Retail)

There is recurring pressure to "just put the source here too" so that local development and deployment touch one repository. That would couple platform orchestration to product release cadence, force the platform repo to grow with product code, and conflict with the migration policy already documented in [`docs/MIGRATION_SOURCES.md`](../MIGRATION_SOURCES.md).

## Decision

This repository owns **only** platform-level orchestration:

- `services.yml` (the platform registry, source of truth);
- `infra/` (Ansible, edge configs, per-stack Compose);
- `tools/` (validators and generators);
- `.github/workflows/` (validate / deploy / rollback);
- `docs/` (architecture, ADRs, runbooks).

Product source code is **not** vendored, **not** mirrored, and **not** referenced as a git submodule in the first stage. Products build and publish container images from their own repositories; this repository deploys those image refs.

This is also encoded as `platform.repository_note` and `platform.source_policy` in [`services.yml`](../../services.yml).

## Consequences

- Positive: clear ownership boundary; product cadence does not destabilise platform orchestration.
- Positive: platform CI is fast — no product dependencies to install.
- Negative: contributors must clone two or three repositories to reproduce a full deploy locally.
- Follow-up: deploy artifacts must be addressable across repos (covered by [ADR-0006](0006-deploy-from-immutable-image-refs.md)).

## Alternatives considered

- **Monorepo containing all products and platform.** Rejected — couples release cadence and inflates CI; product teams would lose autonomy.
- **Git submodules.** Rejected for the first stage — operationally noisy (detached HEADs, accidental version drift) and not needed because products publish images.

## References

- [`docs/MIGRATION_SOURCES.md`](../MIGRATION_SOURCES.md)
- [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md)
- `platform.source_policy` in [`services.yml`](../../services.yml)
