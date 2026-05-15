# 0003. Four runtime instances on launch

- **Status:** Accepted
- **Date:** 2026-05-15

## Context

Each product needs more than a single runtime: AromaFlowAI requires a working public site **and** a demo site with seeded content; AI_E_Retail requires a frozen MVP **and** a mirrored development copy that can diverge. Modelling these as four independent runtime instances (rather than environments of two services) keeps env prefixes, ports, databases, volumes, and deploy targets explicitly separated and prevents accidental data crossover.

## Decision

The platform launches with **four runtime instances**, each with its own env prefix, port pair, database name, volume set, and deploy targets, as defined in `runtime_instances` in [`services.yml`](../../services.yml):

| Instance         | Project         | Role                              | Notes |
|------------------|-----------------|-----------------------------------|-------|
| `aromaflow-work` | AromaFlowAI     | Working public site               | Production on VPS1, preprod on VPS2. |
| `aromaflow-demo` | AromaFlowAI     | Demo-data site                    | `python manage.py setup_demo_content`. Preprod only. |
| `ai-retail-mvp`  | AI_E_Retail     | Frozen MVP                        | Frozen at a release tag (`ai-retail-mvp-v*`). Mirrors `ai-retail-dev` at launch. |
| `ai-retail-dev`  | AI_E_Retail     | Future development copy           | Starts as a mirror of `ai-retail-mvp`, then diverges on `develop`. |

Two implications:

- `ai-retail-mvp` is **frozen by policy**, not by accident. Changes to the MVP runtime require a new MVP release tag, not branch promotion.
- `ai-retail-dev` and `ai-retail-mvp` may share schema today but must not share databases, volumes, or env prefixes (see `data.database`, `data.volumes`, `env.prefix` per instance in `services.yml`).

## Consequences

- Positive: ports, databases, and volumes never collide; demo seeding cannot leak into production.
- Positive: the registry stays the source of truth for what runs where.
- Trade-off: four sets of env files / secrets to manage (mitigated by the env prefix convention enforced by the validator).
- Follow-up: the validator must enforce uniqueness of ports, databases, and env prefixes across instances (tracked in the validator extension task).

## Alternatives considered

- **Two instances with environment switches.** Rejected — env switches inside a single runtime were the source of past data leaks and made backups ambiguous.
- **Single MVP instance, no separate dev copy.** Rejected — would force destabilising changes onto the frozen MVP.

## References

- `runtime_instances` in [`services.yml`](../../services.yml)
- [ADR-0004](0004-extensible-service-catalog.md) — extensibility for future apps and bots
- [`docs/VPS_ROLES.md`](../VPS_ROLES.md)
