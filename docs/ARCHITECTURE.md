# Architecture

AI Service Platform is an infra/orchestration repository. It coordinates multiple product repositories without merging their source code.

## Repository Boundaries

- `AromaFlowAI` owns application code for `aromaflow-work` and `aromaflow-demo` images.
- `AI_E_Retail` owns application code for `ai-retail-mvp` and `ai-retail-dev` images.
- `AI_Service_Platform` owns platform registry, VPS layout, edge routing, stack templates, deploy playbooks, and runbooks.

Migration source rules are documented in [MIGRATION_SOURCES.md](MIGRATION_SOURCES.md). SoftEther VPN is a required platform edge/infrastructure capability, not a product-runtime-owned service, and is documented in [SOFTETHER_VPN.md](SOFTETHER_VPN.md). Target VPN placement is one SoftEther instance per VPS; product HA stays separate from the VPN layer.

CDN, GeoIP, GeoDNS, shared GeoPolicy, and VPN acceleration research are
documented in [CDN_GEO_POLICY.md](CDN_GEO_POLICY.md).

Public websites may later use a CDN in front of the HAProxy/Nginx web edge for
static caching, TLS edge, WAF/bot filtering, and origin shielding. CDN is a site
delivery layer, not a VPN layer: SoftEther, VPN management, database traffic,
and private node overlay traffic stay outside CDN.

This does not forbid VPN acceleration. It only means a standard website CDN is
not the default VPN transport. SoftEther can be evaluated separately with
GeoDNS, Anycast, or an L4 TCP proxy provider. Management traffic on `5555/tcp`
must stay direct and allowlisted.

A shared GeoPolicy service can be used as the single source for country/IP
decisions. It may generate HAProxy country lists, VPN GeoDNS target choices,
egress country rules, and CDN policy inputs. Enforcement remains separate per
traffic type so a web protection rule cannot accidentally break VPN access or
product failover.

## Roadmap / Runtime instances

The platform launches with **four runtime instances**, all defined in `runtime_instances` in [`../services.yml`](../services.yml). They are deliberately independent so ports, databases, env prefixes, and volumes never collide:

| Instance         | Project       | Role                       | Notes |
|------------------|---------------|----------------------------|-------|
| `aromaflow-work` | AromaFlowAI   | Working public site        | Production on VPS1, preprod on VPS2. |
| `aromaflow-demo` | AromaFlowAI   | Demo-data site             | Seeded via `setup_demo_content`. Preprod only. |
| `ai-retail-mvp`  | AI_E_Retail   | Frozen MVP                 | Frozen at a release tag (`ai-retail-mvp-v*`). |
| `ai-retail-dev`  | AI_E_Retail   | Future development copy    | Mirrors MVP at launch, then diverges on `develop`. |

See [ADR-0003](adr/0003-four-runtime-instances.md) for the rationale.

The catalog is **extensible**. New public sites and Telegram bots can be added to `runtime_instances.*` by following the `future_service_template` contract in [`../services.yml`](../services.yml) (kinds: `site`, `telegram-bot`). A `bots/` directory is already reserved alongside `services/` under `defaults.platform_structure`. See [ADR-0004](adr/0004-extensible-service-catalog.md).

`services.yml` remains the single source of truth: validator (`tools/validate-services-yml/`), renderer (`tools/render-compose/`), and healthcheck (`tools/healthcheck/`) all derive their behaviour from it.

For the full set of platform decisions, see [`adr/README.md`](adr/README.md).

## Non-Goals

- No product source code in this repository.
- No git submodules in the first stage.
- No real secrets in this repository.
- No deploy from archives.
