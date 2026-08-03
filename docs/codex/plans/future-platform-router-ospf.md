# Future platform_router OSPF transport

## Decision boundary

FRR/OSPF is a later transport-plane milestone. It may distribute internal
Docker, VPN, management, and inter-VPS transport routes and provide faster
neighbor failure detection.

It must not replace GeoPolicy:

- OSPF answers how an accepted internal next hop is reached.
- GeoPolicy answers whether a scoped new flow goes direct, through one alias
  from an ordered variable-length egress set, or fail-closed based on
  destination classification and health.
- nftables connmarks preserve the selected path for the full connection.

## Possible scope

- FRR on selected platform routers only.
- Authenticated adjacencies over the existing private transport.
- Prefix allowlists; no default-route origination during the first phase.
- Passive-by-default interfaces.
- Staged metrics and explicit rollback to current static routes.
- Monitoring of adjacency state, advertised prefixes, and route churn.

## Explicit exclusions

- No BGP in the next milestone.
- No redistribution of public Internet tables.
- No automatic GeoIP decisions in OSPF.
- No coupling of product HA or PostgreSQL promotion to routing convergence.
- No deployment before the VPS3 GeoPolicy canary is accepted.
