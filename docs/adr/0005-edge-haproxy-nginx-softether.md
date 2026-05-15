# 0005. Edge: HAProxy + per-site Nginx + SoftEther

- **Status:** Accepted
- **Date:** 2026-05-15

## Context

Public traffic, TLS, certificate renewal, and VPN ingress must be served by a coherent edge layer that sits **in front of** product runtimes and is not owned by any single product. Historical infrastructure already used HAProxy for SNI routing and SoftEther for VPN; product teams must not be able to silently re-shape that edge.

The edge contract is encoded in `defaults.edge`, `platform.edge_vpn`, and `platform.legacy_edge_colocation` in [`services.yml`](../../services.yml), and detailed in [`docs/SOFTETHER_VPN.md`](../SOFTETHER_VPN.md).

## Decision

The platform edge consists of three components, owned by infrastructure:

1. **HAProxy** — single public TCP entrypoint. Performs TLS-SNI routing on `443/tcp` between websites and SoftEther; forwards `992/tcp`, `1194/tcp`, and `5555/tcp` (management, allowlist) to SoftEther.
2. **Per-site Nginx** — per-runtime reverse proxy in front of each web service. Owns site-level routing, static/media delivery, and Certbot for ACME.
3. **SoftEther VPN** — required platform component, present on **every** VPS node (VPS1, VPS2, VPS3). Container is **not** published directly; only HAProxy publishes ports. UDP listeners are explicitly future-optional.

Hard constraints (already enforced by the validator):

- `runtime_instances.*` must not declare `edge_vpn`.
- `runtime_instances.*.containers.current` must not include `softether`.
- `platform.edge_vpn.publish_model.softether_container_publish_directly` is `false`.
- VPN management on `5555/tcp` is IP-allowlisted only.

Standard web CDN is **not** the default VPN transport; VPN acceleration is researched separately (see `platform.vpn_acceleration` and [`docs/CDN_GEO_POLICY.md`](../CDN_GEO_POLICY.md)).

## Consequences

- Positive: a new runtime cannot accidentally take over edge ports or break VPN.
- Positive: TLS, ACME, and rate limiting live in one place per site rather than scattered per app.
- Trade-off: adding a new site requires both an HAProxy SNI entry and a per-site Nginx config — codified through generator templates.
- Follow-up: render-compose and edge config generation must keep this layout (separate task).

## Alternatives considered

- **Single ingress (Traefik / Nginx-only).** Rejected — does not cleanly handle non-HTTP TCP (SoftEther 992/1194/5555) under a single SNI entrypoint with per-domain routing.
- **Per-runtime ingress containers.** Rejected — would let a product runtime accidentally compete with the platform edge for ports.
- **SoftEther published directly.** Rejected — collides with HTTPS sites on `443/tcp` and bypasses HAProxy rate limiting and allowlists.

## References

- `platform.edge_vpn`, `platform.legacy_edge_colocation`, `defaults.edge` in [`services.yml`](../../services.yml)
- [`docs/SOFTETHER_VPN.md`](../SOFTETHER_VPN.md)
- [`docs/CDN_GEO_POLICY.md`](../CDN_GEO_POLICY.md)
- [`docs/VPS_ROLES.md`](../VPS_ROLES.md)
