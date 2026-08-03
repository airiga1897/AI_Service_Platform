# 0010. Single GeoPolicy gateway namespace on VPS3

- **Status:** Accepted (supersedes ADR-0008)
- **Date:** 2026-08-02

## Context

The original canary classified traffic on the VPS3 host and copied route marks
into `platform-router`. That split ownership made transient tunnel failures and
container restarts difficult to reason about. It also left application and VPN
traffic dependent on separate host-routing mechanisms.

## Decision

`platform-router` is the only GeoPolicy classifier and L3 gateway on VPS3.

- AI_E_Retail uses `172.31.3.10 -> 172.31.3.2` on the application network.
- VPN SecureNAT uses `172.22.252.2 -> 172.22.252.4` on the isolated
  `ai_service_vpn_policy` network.
- The common `172.20.0.0/24` edge network is not attached to the router.
- Stable egress marks and policy tables exist only in the router namespace.
- A host guard rejects direct public forwarding from either scoped source, so a
  missing router or lost route fails closed instead of leaking through VPS3.
- Removing GeoPolicy deletes only its router nftables table. Source gateway
  routes remain and use the router's ordinary VPS3 egress.
- Explicit gateway rollback restores both Docker default routes and removes the
  host guard without removing transport links.

GeoPolicy apply is accepted only after real probes from both the application
container and the VPN policy namespace succeed. A failed probe restores the
previous router nftables table and does not write a receipt.

## Consequences

Application and VPN egress share one policy decision point while retaining
separate ingress and transport networks. Restart reconciliation is required for
both source namespaces. Failure of `platform-router` blocks scoped public
egress, but does not redirect it through the VPS3 host main route.

The three current SoftEther egress links stay independent. A future multi-node
L3/OSPF overlay is a separate milestone.
