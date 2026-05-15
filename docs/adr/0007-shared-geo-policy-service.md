# 0007. Single shared GeoPolicy data source

- **Status:** Accepted
- **Date:** 2026-05-15

## Context

Geographic decisions are needed in several unrelated places: HAProxy country lists for site protection, GeoDNS for picking the nearest VPN ingress, egress country selection for VPN traffic, and country inputs for any future site CDN. If each layer maintains its own country/IP data, lists drift, decisions diverge, and a "fix" in one place silently regresses another.

This is already documented in `platform.geo_policy` in [`services.yml`](../../services.yml) and in [`docs/CDN_GEO_POLICY.md`](../CDN_GEO_POLICY.md).

## Decision

There is **one** shared GeoPolicy source for country/IP data. **Enforcement stays per traffic type.**

- `platform.geo_policy.status` is `planned-shared-platform-service`.
- `platform.geo_policy.data_outputs` enumerates the consumers: `haproxy_country_lists`, `vpn_geodns_targets`, `egress_country_rules`, `cdn_country_policy_inputs`.
- `enforcement_boundaries` records that web protection is owned by HAProxy (or future CDN), VPN nearest ingress by GeoDNS, VPN egress selection by the routing-policy controller, and product HA is **not** handled by GeoPolicy.
- Safety: dry-run first, audit log required, manual override required (`platform.geo_policy.safety`).
- A web-protection rule must never be able to silently break VPN access or product failover.

## Consequences

- Positive: one place to update country data, four consistent applications.
- Positive: edge protection, VPN routing, and CDN policy stay decoupled at the enforcement layer.
- Trade-off: the GeoPolicy service itself does not exist yet (`planned-…`); until it ships, individual layers maintain their own lists with the contract that they will migrate.
- Follow-up: when GeoPolicy is implemented, supersede this ADR with a new ADR describing the actual interface and rollout.

## Alternatives considered

- **Per-layer country lists.** Today's de facto state. Rejected as the long-term plan because it caused drift between HAProxy lists and VPN/CDN expectations historically.
- **Single enforcement engine for all geo decisions.** Rejected — couples web protection, VPN, and CDN; one rule could break unrelated traffic types.

## References

- `platform.geo_policy`, `platform.edge_protection`, `platform.vpn_acceleration` in [`services.yml`](../../services.yml)
- [`docs/CDN_GEO_POLICY.md`](../CDN_GEO_POLICY.md)
- [ADR-0005](0005-edge-haproxy-nginx-softether.md)
