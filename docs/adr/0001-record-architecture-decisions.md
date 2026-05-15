# 0001. Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-05-15

## Context

The AI Service Platform repository orchestrates multiple product runtimes, edge components, VPS roles, and CI/CD policies. Several non-trivial architectural decisions are already encoded in `services.yml` and scattered across `docs/` (e.g. infra-only repo, SoftEther on every VPS, immutable image refs, shared GeoPolicy). Without a single place to record *why* these decisions were taken, future contributors must re-derive them from configuration and risk overturning them by accident.

## Decision

Record significant architectural decisions as Architecture Decision Records (ADRs) in `docs/adr/`, using the [MADR](https://adr.github.io/madr/) format defined in [`template.md`](template.md).

- One decision per file, sequentially numbered (`NNNN-short-title.md`).
- Status values: `Proposed`, `Accepted`, `Superseded by ADR-NNNN`.
- An ADR is never deleted; superseded ADRs stay for history.
- The index in [`README.md`](README.md) is updated whenever an ADR is added or its status changes.
- ADRs describe architecture and policy. They are **not** the Replit-session work plan (that lives in `docs/replit/plans/`) and **not** runbooks (those live in `docs/RUNBOOKS.md`).

## Consequences

- Positive: every significant decision has a discoverable, dated rationale.
- Positive: changes to architecture become a deliberate act (write a new ADR or supersede an old one) rather than an accidental config edit.
- Trade-off: small overhead per decision. We accept that overhead for decisions with cross-cutting consequences; trivial choices stay out of `docs/adr/`.

## Alternatives considered

- **Long-form architecture document only.** Already partially exists as `docs/ARCHITECTURE.md`. Rejected as the sole record because it does not capture decision context, status, or supersession history.
- **Issues / commit messages only.** Rejected because they are not discoverable as a coherent body of architecture knowledge.

## References

- [MADR](https://adr.github.io/madr/)
- [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md)
