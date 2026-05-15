# 0006. Deploy from immutable Docker image refs

- **Status:** Accepted
- **Date:** 2026-05-15

## Context

Branch names ("deploy `main`", "deploy `develop`") are convenient but ambiguous: the same name resolves to different code over time, and rollbacks become impossible without external bookkeeping. Product repositories already build container images; the only sensible deploy unit across two product repos and three VPS nodes is the image ref.

This is already encoded in `platform.source_policy.preferred_deploy_artifact: immutable_docker_image_ref` in [`services.yml`](../../services.yml).

## Decision

Deployment artifacts are **immutable Docker image refs** (digest or commit-SHA tag). Branch names exist only as build/source policy.

- `platform.source_policy.preferred_deploy_artifact` is `immutable_docker_image_ref`.
- `platform.source_policy.deploy_from_archives` is `false`.
- `platform.source_policy.branch_names_are_build_policy_only` is `true`.
- Per-project `source.deploy_refs.preferred` is `image_ref`.
- `bootstrap_ref` values in `projects.*.source.bootstrap_ref` are **temporary** until product `develop` / `main` / release tags exist; they are always listed in `allowed_source_refs` and removed once promoted (see [`docs/DEPLOYMENT.md`](../DEPLOYMENT.md)).
- Rollback uses a previously deployed image ref; it does not re-checkout a branch.

## Consequences

- Positive: every deploy is reproducible and rollback is mechanical.
- Positive: product CI owns building and tagging; platform CI never compiles product code.
- Trade-off: requires a working image registry and stable image-tagging discipline in product repos.
- Follow-up: `bootstrap_ref` entries are tech debt and must be removed as product branches stabilise.

## Alternatives considered

- **Deploy from git refs.** Rejected — non-reproducible (mutable branches), couples deploy to source checkout.
- **Deploy from archives.** Explicitly rejected by `source_policy.deploy_from_archives: false` — same reproducibility problem plus opaque provenance.

## References

- `platform.source_policy`, `projects.*.source.deploy_refs` in [`services.yml`](../../services.yml)
- [`docs/DEPLOYMENT.md`](../DEPLOYMENT.md)
- [`docs/CI_CD.md`](../CI_CD.md)
