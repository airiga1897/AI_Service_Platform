# 0008. VPS3 destination-based GeoPolicy egress canary

- **Status:** Accepted
- **Date:** 2026-07-28

## Context

AI_E_Retail on VPS3 needs OpenAI access through a supported non-RU egress.
VPN clients entering through VPS3 should receive the same destination behavior:
RU destinations direct, non-RU destinations through a healthy non-RU path.
Routing all VPS3 traffic through that path would also redirect public HTTPS/VPN
replies and create asymmetric routing.

## Decision

Implement an IPv4-only canary on the VPS3 host:

- source scope is exactly `172.31.3.10/32` and `172.20.0.2/32`;
- destination classification uses a validated RU CIDR set;
- special and internal ranges remain direct;
- only new scoped flows receive a conntrack mark;
- established and related flows restore their existing connmark;
- an ordered, variable-length list of operator-approved `platform_router`
  transport tables provides non-RU egress; the initial set is `vps1`, `vps2`,
  and `vps4`;
- nftables atomically selects one configured alias or scoped fail-closed;
- health reconciliation uses 3-failure failover and 5-success/5-minute
  recovery hysteresis.

IPdeny provides the aggregated RU list. RIPE delegated statistics are an
independent sanity guard. The first dataset and ordered egress set require explicit
operator acceptance. The OpenAI country acceptance receipt references the
official supported-country page, while an unauthenticated live API probe checks
the actual path without exposing an API key.

## Consequences

- Public ingress replies and unrelated host/container traffic stay on their
  original routes.
- Every configured transport path must exist before mutation-free GeoPolicy preflight can
  pass.
- A stale dataset is degraded but remains available as last-known-good.
- If all egress paths fail, RU/internal traffic continues while scoped non-RU
  traffic is blocked.
- The canary has explicit check, manual alias override, receipt, and
  rollback interfaces.

OSPF is deferred to a separate transport milestone. It may distribute internal
routes but will not replace GeoPolicy decisions. BGP remains out of scope.
