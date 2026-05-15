# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the AI Service Platform.

ADRs capture significant architectural decisions: their context, the decision itself, status, and consequences. They are not project tasks and not roadmap items — they record decisions that have already been made (or are explicitly proposed) so that anyone reading the repository later can understand *why* the platform looks the way it does.

- Format: [MADR](https://adr.github.io/madr/) — see [`template.md`](template.md).
- Filename: `NNNN-short-kebab-title.md`, four-digit zero-padded sequence.
- Status values: `Proposed` → `Accepted` → `Superseded` (record the superseder in both ADRs).

This is **not** the same as `docs/replit/`. `docs/replit/` is a snapshot of the current Replit-session work plan; ADRs live longer and describe architecture, not workflow.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-infra-only-repository.md) | This repository is infra/orchestration only | Accepted |
| [0003](0003-four-runtime-instances.md) | Four runtime instances on launch | Accepted |
| [0004](0004-extensible-service-catalog.md) | `services.yml` is an extensible service catalog | Accepted |
| [0005](0005-edge-haproxy-nginx-softether.md) | Edge: HAProxy + per-site Nginx + SoftEther | Accepted |
| [0006](0006-deploy-from-immutable-image-refs.md) | Deploy from immutable Docker image refs | Accepted |
| [0007](0007-shared-geo-policy-service.md) | Single shared GeoPolicy data source | Accepted |

## How to add a new ADR

1. Copy [`template.md`](template.md) to `NNNN-your-decision.md` using the next free number.
2. Fill in Context, Decision, Status, Consequences, and Date.
3. Add a row to the index above.
4. Open a PR. The decision becomes `Accepted` once merged unless explicitly marked `Proposed`.

## Superseding

When a new ADR replaces an old one:

- Set the old ADR's status to `Superseded by ADR-NNNN`.
- Set the new ADR's status to `Accepted (supersedes ADR-MMMM)`.
- Do not delete the old ADR — history matters.
