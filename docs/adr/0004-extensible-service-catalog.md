# 0004. `services.yml` is an extensible service catalog

- **Status:** Accepted
- **Date:** 2026-05-15

## Context

Beyond the four launch runtimes ([ADR-0003](0003-four-runtime-instances.md)), the platform must accept new public sites and Telegram bots without schema changes. The registry already reserves a `future_service_template` block in [`services.yml`](../../services.yml) for this purpose, with two service kinds:

- `site` — public web service (Django, Django+React, etc.).
- `telegram-bot` — aiogram3 bot (polling in dev, webhook in preprod/prod, per `defaults.bots`).

A `bots/` directory is also reserved under `defaults.platform_structure`, separate from `services/`.

## Decision

`services.yml` is the **single, extensible catalog** for all platform runtimes. Adding a new app or bot is a registry change plus a generator template — never a manual edit of edge configs or per-stack Compose.

Contract for new entries:

- A new `runtime_instances.<name>` entry must satisfy the `required` fields of the matching `future_service_template` kind:
  - `site` requires `profile`, `env.prefix`, `domains`, `healthcheck`, `containers`, `data.database`, `data.cache`.
  - `telegram-bot` requires `profile`, `env.prefix`, `webhook.preprod`, `webhook.prod`, `containers`, `healthcheck`.
- An explicit `type:` field (`site` | `telegram-bot`) is recommended for new entries so the validator can apply the right contract conditionally.
- New entries must declare `deploy.environments` only against VPS nodes that exist in `platform.vps_layout`.
- New entries must not declare `edge_vpn` — VPN is owned by the platform, not by runtimes ([ADR-0005](0005-edge-haproxy-nginx-softether.md)).

Generator and validator changes that depend on this contract are tracked in separate tasks (`tools/render-compose`, validator extensions).

## Consequences

- Positive: adding a fifth runtime — site or bot — is a small, mechanical change.
- Positive: the validator and renderer can grow with the catalog instead of branching per-stack.
- Trade-off: the `future_service_template` block is a soft contract today; full enforcement lands with the validator extension.
- Follow-up: when the first real bot is added, revisit `defaults.bots` (framework, modes) to confirm it still matches reality.

## Alternatives considered

- **Per-app config files.** Rejected — duplicates fields, encourages drift, and makes cross-app invariants (port uniqueness, env prefix shape) impossible to validate.
- **Hardcoding service list in tools.** Rejected — would invert the source of truth and force code changes for every new runtime.

## References

- `future_service_template` and `defaults.bots` in [`services.yml`](../../services.yml)
- [ADR-0003](0003-four-runtime-instances.md)
- [ADR-0006](0006-deploy-from-immutable-image-refs.md)
