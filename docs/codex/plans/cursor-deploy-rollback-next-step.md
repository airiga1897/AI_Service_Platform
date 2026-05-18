# Cursor Prompt: Deploy/Rollback Next Step

Скопируй этот промт в Cursor для доработки `AI_Service_Platform`.

```text
Ты работаешь в репозитории AI_Service_Platform.

Цель: реализовать следующий безопасный milestone после текущего infra-MVP:
подготовить реальный deploy/rollback pipeline, но включить фактический rollout
только для первого безопасного вертикального сценария:

  ai-retail-dev -> preprod -> VPS2

Важно:
- Не делать production deploy.
- Не добавлять реальные secrets, SSH keys, IP, .env, inventory.ini.
- Не переносить product source code.
- Не ломать существующие docs, ADR, validator, render-compose, render-edge,
  healthcheck.
- Не смешивать SoftEther/VPN с product runtime deploy.

Текущий контекст:
- `services.yml` является source of truth.
- Product repos:
  - https://github.com/airiga1897/AromaFlowAI
  - https://github.com/airiga1897/AI_E_Retail
- Runtime instances:
  - `aromaflow-work`
  - `aromaflow-demo`
  - `ai-retail-mvp`
  - `ai-retail-dev`
- VPS layout:
  - `VPS1`: Netherlands, production runtime
  - `VPS2`: Kazakhstan, preprod/hot-standby/backup
  - `VPS3`: Russia, management/monitoring/orchestration
- SoftEther is a platform VPN service on VPS1/VPS2/VPS3, not a product app.
- Deploy policy: deploy immutable Docker `image_ref`, not git branches.
- Existing `.github/workflows/deploy.yml` and `rollback.yml` are dry-run
  skeletons and must become useful, but safely.

Use these existing references:
- `docs/replit/plans/06-deploy-and-rollback-pipeline.md`
- `docs/adr/0006-deploy-from-immutable-image-refs.md`
- `docs/adr/0003-four-runtime-instances.md`
- `docs/DEPLOYMENT.md`
- `docs/RUNBOOKS.md`
- `tools/validate-services-yml/validate_services_yml.py`
- `tools/healthcheck/healthcheck.py`
- `tools/_lib/registry.py`

Implementation scope:

1. Extend `services.yml` deploy contract.

   For every `runtime_instances.<name>.deploy`, add explicit machine-readable
   fields needed by deploy pipeline:

   - `allowed_image_ref_pattern`
   - `frozen`
   - `frozen_image_ref_pattern`
   - `environments.<env>.vps`
   - `environments.<env>.compose_file`
   - `environments.<env>.deploy_dir`
   - `environments.<env>.deploy_state_tag_prefix`

   Rules:
   - `ai-retail-dev` must support `preprod` on `VPS2`.
   - `aromaflow-work` production remains declared but not actually rolled out
     by the first implementation.
   - `ai-retail-mvp` must be `frozen: true`.
   - For `ai-retail-mvp`, add a strict `frozen_image_ref_pattern` for MVP
     release refs, for example tags matching `ai-retail-mvp-v*`.
   - Keep existing branch/source policy fields if present; do not erase useful
     migration context.

2. Extend validator.

   Update `tools/validate-services-yml/validate_services_yml.py` so `make
   validate` checks:

   - every runtime instance has deploy fields listed above;
   - `allowed_image_ref_pattern` is present and is a valid regex;
   - if `frozen: true`, `frozen_image_ref_pattern` is present and is a valid
     regex;
   - each deploy environment points to a known VPS from
     `platform.vps_layout`;
   - each `compose_file` points under `infra/stacks/<instance>/`;
   - `deploy_state_tag_prefix` is non-empty and starts with
     `deploy/<instance>/<environment>/`;
   - SoftEther still does not appear in product runtime containers;
   - current SoftEther TCP ports remain `443`, `992`, `1194`, `5555`;
   - `ports.udp` is still forbidden as current state.

   Add focused tests and fixtures under `tools/validate-services-yml/tests/`:

   - missing deploy block fails;
   - invalid image ref regex fails;
   - frozen instance without frozen pattern fails;
   - unknown deploy VPS fails;
   - current good `services.yml` passes.

3. Add a small deploy preflight helper.

   Prefer a Python helper instead of huge bash embedded in YAML.

   Suggested path:

   - `tools/deploy/preflight.py`

   It should accept:

   - `--instance`
   - `--environment`
   - `--image-ref`
   - optional `--registry services.yml`

   It should:

   - load `services.yml`;
   - find the runtime instance;
   - validate requested environment exists;
   - validate image ref against `allowed_image_ref_pattern`;
   - if frozen, validate image ref against `frozen_image_ref_pattern`;
   - output resolved deploy metadata as JSON:
     - instance
     - environment
     - image_ref
     - vps
     - compose_file
     - deploy_dir
     - deploy_state_tag_prefix

   Add tests for this helper.

4. Update `.github/workflows/deploy.yml`.

   Replace pure dry-run with a safe staged workflow:

   - inputs:
     - `instance`
     - `environment`
     - `image_ref`
   - first job `preflight`:
     - checkout;
     - setup Python;
     - install dependencies;
     - run `make check`;
     - run `tools/deploy/preflight.py`;
     - upload or expose resolved JSON for later jobs;
   - deploy job:
     - only allow actual SSH deploy for `instance=ai-retail-dev` and
       `environment=preprod` in this milestone;
     - for all other instance/environment combinations, fail with a clear
       message saying rollout is intentionally not enabled yet;
     - use GitHub Environment `ai-retail-dev-preprod` or `preprod`;
     - leave SSH commands as guarded skeleton if real secrets are absent, but
       structure the steps so they are ready for:
       - copy/render compose file;
       - set `IMAGE_REF`;
       - `docker compose pull`;
       - `docker compose up -d`;
       - run healthcheck.

   Do not invent real hostnames or secrets.

5. Update `.github/workflows/rollback.yml`.

   Keep rollback conservative:

   - inputs:
     - `instance`
     - `environment`
     - optional `to_ref`
   - resolve target ref from `to_ref` for now;
   - if `to_ref` is empty, fail with a clear message that deploy-state lookup
     is not implemented yet;
   - run same preflight validation against resolved `to_ref`;
   - only allow actual rollback path for `ai-retail-dev/preprod`;
   - document deploy-state tag lookup as next follow-up if not implemented.

6. Update docs.

   Update:

   - `docs/DEPLOYMENT.md`
   - `docs/RUNBOOKS.md`
   - `docs/CI_CD.md`

   They must clearly explain:

   - only `ai-retail-dev/preprod` is enabled for first real rollout;
   - deploy uses immutable `image_ref`;
   - rollback is re-deploy of previous image ref, not git checkout;
   - `ai-retail-mvp` is frozen and guarded;
   - production deploy remains disabled until separate approval.

7. Keep generated configs consistent.

   Run and keep green:

   - `python tools/validate-services-yml/validate_services_yml.py --strict`
   - `python tools/render-compose/render_compose.py --stack all --check`
   - `python tools/render-edge/render_edge.py --check`
   - `python -m unittest discover -s tools/validate-services-yml/tests -t .`
   - `python -m unittest discover -s tools/render-compose/tests -t .`
   - `python -m unittest discover -s tools/render-edge/tests -t .`
   - `python -m unittest discover -s tools/healthcheck/tests -t .`
   - tests for new `tools/deploy/preflight.py`
   - `git diff --check`

Acceptance criteria:

- `services.yml` has explicit deploy contract for all 4 runtime instances.
- Validator rejects missing/invalid deploy contract fields.
- `tools/deploy/preflight.py` returns JSON metadata for
  `ai-retail-dev/preprod` and rejects invalid/frozen refs.
- `deploy.yml` is no longer a meaningless dry-run; it performs real preflight
  and has a guarded path for `ai-retail-dev/preprod`.
- `rollback.yml` has matching preflight and a conservative explicit-ref
  rollback path.
- Docs explain what is enabled now and what remains intentionally disabled.
- No real secrets, IP addresses, SSH keys, `.env`, `inventory.ini`, or product
  code are committed.

Important implementation preference:

- Keep this milestone small and reviewable.
- If real SSH deployment cannot be completed without secrets, leave only that
  final SSH execution as a clearly marked guarded step, but implement all
  validation/preflight logic fully.
- Do not broaden scope into production rollout, CDN, GeoPolicy service,
  monitoring activation, or SoftEther provisioning.
```
