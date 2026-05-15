# AI Service Platform

Infra-only orchestration repository for services deployed across the AI Service Platform.

Product source code lives in separate repositories:

- `airiga1897/AromaFlowAI`
- `airiga1897/AI_E_Retail`

This repository owns platform-level runtime metadata, VPS layout, edge routing templates, stack templates, deployment playbooks, and CI/CD orchestration rules. It must not vendor product source code and does not use git submodules in the first stage.

Migration source policy is documented in `docs/MIGRATION_SOURCES.md`. SoftEther VPN is a required platform edge/infrastructure component, independent of product ownership, and is documented in `docs/SOFTETHER_VPN.md`. CDN, GeoIP, GeoDNS, and VPN acceleration research are documented in `docs/CDN_GEO_POLICY.md`. The target VPN topology has SoftEther on VPS1, VPS2, and VPS3; HAProxy publishes the current TCP entrypoints.

## Runtime Instances

- `aromaflow-work` - working AromaFlowAI site.
- `aromaflow-demo` - AromaFlowAI demo-data site.
- `ai-retail-mvp` - frozen AI_E_Retail MVP.
- `ai-retail-dev` - AI_E_Retail development copy.

## CI/CD Model

Products build and publish images. This platform repository validates `services.yml` and deploys selected image refs to selected VPS stacks.

Product repository branches are tracked as build/source policy, not as deployment artifacts. While product `main` and `develop` branches are still being prepared, `services.yml` records temporary `bootstrap_ref` values for the current working product branches. Real deployment should use immutable Docker image refs tagged by commit SHA or release tag.

Initial workflows are validate-only or manual skeletons. Real deploy is enabled only after product image builds are stable.

## Architecture Decision Records

Significant architectural decisions for this platform are recorded as ADRs under [`docs/adr/`](docs/adr/README.md). Start with the [index](docs/adr/README.md) for the full list.

Key decisions in force today:

- [ADR-0002](docs/adr/0002-infra-only-repository.md) — this repository is infra/orchestration only; product code stays in product repositories.
- [ADR-0003](docs/adr/0003-four-runtime-instances.md) — four runtime instances on launch (`aromaflow-work`, `aromaflow-demo`, `ai-retail-mvp`, `ai-retail-dev`).
- [ADR-0004](docs/adr/0004-extensible-service-catalog.md) — `services.yml` is an extensible catalog for future sites and Telegram bots.
- [ADR-0005](docs/adr/0005-edge-haproxy-nginx-softether.md) — edge is HAProxy + per-site Nginx + SoftEther, owned by infrastructure.
- [ADR-0006](docs/adr/0006-deploy-from-immutable-image-refs.md) — deploy from immutable Docker image refs, not branches.
- [ADR-0007](docs/adr/0007-shared-geo-policy-service.md) — single shared GeoPolicy data source, per-traffic enforcement.

The current Replit-session work plan is snapshotted under [`docs/replit/`](docs/replit/README.md).
