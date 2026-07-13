# Manual Site Runtime Rollout Before GitHub CD

## Summary

До стабилизации deployment GitHub отвечает только за CI: тестирует продукт,
собирает image и публикует immutable tag/digest в GHCR. Rollout выполняет
оператор через единый platform tooling. Позже GitHub CD должен вызывать тот же
механизм через orchestration node, а не реализовывать собственный deployment.

Первым runtime будет `AI_E_Retail MVP`, но contract и tooling сразу должны быть
generic для AI_E_Retail, AromaFlow и TravellTickets.

## Runtime And Tooling Contract

- Добавить generic `site_runtime`.
- Topology и placement хранить в `operator/site_runtime/instances.yml`.
- `operator/state.csv` определяет aliases, на которых разрешён `site_runtime`.
- `services.yml` хранит product contract, image policy, healthchecks и compose
  metadata, но не номер VPS.
- Secrets остаются в operator-local per-instance env-файлах.
- Текущий image ref является входом deployment transaction и записывается в
  durable deployment journal, а не в `state.csv`.

Operator interface:

```powershell
.\tools\services\service.ps1 site_runtime plan `
  -Instance ai-retail-mvp `
  -ImageRef ghcr.io/...@sha256:...

.\tools\services\service_remote.ps1 site_runtime apply `
  -Instance ai-retail-mvp `
  -ImageRef ghcr.io/...@sha256:... `
  -Limit vps3
```

Wrapper requirements:

- resolve placement from operator config/state;
- reject a `-Limit` that does not match resolved placement;
- validate image ref against the policy in `services.yml`;
- reject mutable tags such as `latest`;
- never build a product image on a managed VPS;
- never turn one instance deployment into a broad rollout.

The durable journal for each instance records:

- deployment id and timestamp;
- target alias;
- previous and current image digests;
- rendered compose checksum;
- migration status;
- healthcheck result;
- final state: `success`, `failed`, or `rolled_back`.

Initial placement after node sizing is `ai-retail-mvp` on `vps3`,
`aromaflow-work` on `vps7`, and `travelltickets` on `vps2`. Add these mappings
to operator config/state only when `site_runtime` exists; documentation alone
must not create desired state that no wrapper can converge.

## Manual Rollout Sequence

1. Preflight without runtime mutation:
   - resolve exactly one placement target;
   - require the alias in `nodes.csv` and allow it in `state.csv`;
   - require Docker networks, platform-router endpoint, Redis and secrets;
   - validate and resolve the immutable GHCR image;
   - render compose and run `docker compose config`;
   - run short PostgreSQL and Redis connectivity probes.
2. Preparation:
   - record current image digest and compose checksum;
   - pull the immutable image;
   - run container-level configuration checks;
   - inspect the migration plan without applying it.
3. Apply:
   - allow only reviewed backward-compatible migrations;
   - update web, worker, beat and nginx;
   - preserve named volumes;
   - protect seed operations with an idempotency marker;
   - wait for container health.
4. Acceptance:
   - `/healthz/` returns 200;
   - `/readyz/` confirms PostgreSQL readiness;
   - worker health confirms Redis/Celery;
   - nginx config validation succeeds;
   - public route is tested only when its explicit `edge_route` is present.
5. Failure handling:
   - before migrations, leave the running runtime unchanged;
   - after compatible migrations, restore the previous image on health failure;
   - never perform automatic schema rollback;
   - stop with `manual-recovery` when rollback is not schema-safe;
   - retain the previous working revision until acceptance completes.

## Rehearsal And GitHub Gate

Before enabling GitHub CD, prove manually:

- first install on an empty target;
- idempotent repeat apply of the same digest;
- upgrade to a new digest;
- rollback to the previous digest;
- recreate after reboot without volume loss;
- safe failure on missing secret, network, Redis, PostgreSQL, or image;
- instance movement between aliases through operator placement;
- rejection of a mismatched `-Limit`;
- at least three consecutive clean rollouts;
- a documented and repeatable rollback rehearsal.

After the gate, GitHub CD may be added with these constraints:

- workflow inputs are `instance`, `environment`, and immutable `image_ref`;
- preflight resolves placement from operator state/config;
- GitHub connects only to the active orchestration node;
- orchestration invokes the same service wrapper and Ansible path;
- GitHub stores no per-VPS deployment keys;
- production requires GitHub Environment approval;
- workflow publishes deployment journal and health summary;
- GitHub does not change placement or automatically roll back schemas.

The legacy workflow with a fixed preproduction VPS must not be extended with
`docker compose pull/up`. Retire it after the role-based workflow exists.

## Test Plan

Unit tests:

- placement resolution, unknown/duplicate alias, and mismatched limit;
- immutable image validation;
- deployment journal transitions;
- rollback eligibility after migrations.

Integration tests:

- compose rendering for multiple instances on different aliases;
- dry-run without Docker mutation;
- simulated successful and failed healthchecks;
- repeated idempotent apply.

Runtime acceptance:

- web, nginx, worker and runtime-specific Redis are healthy;
- PostgreSQL traffic uses the controlled platform endpoint;
- volumes survive container recreation;
- a failed rollout does not destroy the previous runtime;
- platform PostgreSQL, SoftEther and other site instances remain unchanged.

## Assumptions

- Long PowerShell rollout commands are run by the operator.
- Provider resize and any required reboot are operator-run prerequisites.
- GitHub CI may publish images before CD is enabled.
- Blue/green deployment and automatic failover are outside v1; a short
  controlled restart window is acceptable.
- Database migrations must remain backward-compatible for automatic image
  rollback to be allowed.
