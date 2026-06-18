# validate-services-yml

Validates the `services.yml` registry contract for the AI Service Platform.

## What it checks

**Platform invariants**

- Physical node metadata (`country`/`city`/`datacenter`) and platform role bindings.
- Compatibility VPS aliases (`VPS1`/`VPS2`/`VPS6`) with required current-layout fields.
- Source policy: source from Git only, deploy preferred via immutable Docker image refs.
- SoftEther as a required platform-owned edge/VPN component (not owned by any runtime instance).
- SoftEther TCP listener set, future-optional UDP set, HAProxy publish model.
- Shared `geo_policy` data outputs and CDN/VPN-acceleration scope guardrails.

**Projects**

- Each project has a `repository`, `bootstrap_ref`, stable branches (development/production),
  and `deploy_refs.preferred = image_ref` with `bootstrap_ref` listed in `allowed_source_refs`.

**Runtime instances** (per instance)

- Required `project`, `profile`, `role`.
- `env.prefix` is uppercase snake-case **and matches the instance name**
  (e.g. `aromaflow-work` → `AROMAFLOW_WORK`).
- `env.file` and `env.example_file` follow `.env.<project>.<role>` naming
  (e.g. `ai-retail-mvp` → `.env.ai-retail.mvp`).
- `healthcheck.path` starts with `/`, `expected_status` is an integer in
  `[100, 599]`, `timeout_seconds` is a positive number.
- `deploy.environments.*` only points at VPS nodes declared in `platform.vps_layout`.
- Instance must not declare its own `edge_vpn` block, and must not list
  `softether` in `containers.current`.

**Cross-instance uniqueness**

- `local.backend_port` and `local.frontend_port` are unique across all instances
  (each must be a valid TCP port `1–65535`).
- `domains.preprod` and `domains.prod` entries don't collide between instances.
- `data.database` names are unique and match `^[a-z][a-z0-9_]*$`.

**Conditional `future_service_template` checks**

- If an instance declares `type: site`, the fields listed under
  `future_service_template.site.required` must all be present.
- For `type: telegram-bot`, the validator looks under
  `future_service_template.telegram-bot.required` first and falls back to
  the short key `future_service_template.bot.required` (currently used in
  `services.yml`). Either spelling is accepted.
- Instances without an explicit `type` are unaffected (back-compat).

**Warnings (informational by default, errors under `--strict`)**

- A local port equals `5000` (reserved by the Replit web preview).
- A local port equals one of the SoftEther TCP listener ports
  (`443`, `992`, `5555`).

## Run locally

Default mode (warnings printed, exit 0 if no errors):

```bash
python3 tools/validate-services-yml/validate_services_yml.py
```

Strict mode (warnings count as errors):

```bash
python3 tools/validate-services-yml/validate_services_yml.py --strict
```

Validate a different file (useful for fixtures):

```bash
python3 tools/validate-services-yml/validate_services_yml.py path/to/other.yml
```

## Example output

Default mode on the current `services.yml`:

```
services.yml warnings:
- runtime_instances.aromaflow-work.local.backend_port=5000 collides with the Replit web preview reserved port
services.yml validation passed
```

A failing run (e.g. duplicate port `5170`):

```
services.yml validation failed:
- runtime_instances.aromaflow-demo.local.backend_port duplicates port 5170 already used by runtime_instances.aromaflow-work.local.frontend_port
```

## Tests

Smoke tests live in `tools/validate-services-yml/tests/`. There are two
layers:

- **In-memory mutation tests** load the real `services.yml`, mutate the
  parsed dict to produce intentionally broken inputs, and assert that
  each check fires with a sensible message. This is fast and stays
  automatically in sync with the real registry.
- **CLI fixture tests** run the validator as a subprocess against the
  committed YAML files in `tests/fixtures/` (`broken_duplicate_port.yml`,
  `broken_bad_env_prefix.yml`, `broken_unknown_vps.yml`,
  `broken_missing_healthcheck.yml`) and assert both exit code and
  stderr message. Regenerate them from the current `services.yml` only
  when the contract changes.

Run with the standard library only:

```bash
python3 -m unittest discover -s tools/validate-services-yml/tests -t .
```

Or with pytest if you have it installed:

```bash
pytest tools/validate-services-yml/tests
```

The only runtime dependency is `pyyaml`.
