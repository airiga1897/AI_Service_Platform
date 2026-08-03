# 0009. One multi-account SoftEther client daemon per platform router

- **Status:** Accepted
- **Date:** 2026-08-01

## Context

`platform_router` places SoftEther client networking in the router network
namespace so that policy and service routes can use the VPN interfaces directly.
The first GeoPolicy transport implementation created one `vpnclient` container
for every link while all of those containers used
`network_mode: service:platform-router`.

Container boundaries do not isolate TCP listeners in a shared network namespace.
Every SoftEther client service uses the local management endpoint
`localhost:5555`. Multiple client daemons therefore competed for the same
endpoint, and `vpncmd` could configure whichever daemon owned the listener. On
VPS3 this made the existing PostgreSQL account race with the three GeoPolicy
egress accounts. The observed failure was a healthy application and Celery
broker with `readyz.db=error` after the transport rollout.

The current contract audit finds four client accounts on VPS3 and one on each of
VPS1, VPS4, VPS5, VPS6 and VPS9. `operator-arm` also has one. Only VPS3 currently
triggers the multi-daemon collision, but adding a second link to any router would
reproduce it.

## Decision

Run exactly one SoftEther `vpnclient` daemon in each `platform_router` network
namespace. Configure every accepted link as an independent account and virtual
NIC inside that daemon:

- the container name and persistent client data directory are node-wide;
- account names, NIC names, VPN subnets and credentials remain link-specific;
- the existing PostgreSQL client data directory is retained during migration;
- Compose `--remove-orphans` removes obsolete per-link client containers;
- stale per-link data directories are not deleted automatically;
- model validation rejects duplicate account or NIC names;
- the safe preflight reports one runtime container and its account count.

The SoftEther server listener on port `5555` remains unchanged. Client remote
management is not enabled or published; `localhost:5555` is only the local
control endpoint used by `vpncmd`.

## Consequences

- PostgreSQL and GeoPolicy tunnels coexist as accounts in one client service.
- Adding or removing egress paths changes accounts, not the number of client
  containers.
- A client daemon restart affects all client links on that router, so rollout
  acceptance must verify every configured account and every required service
  route, especially PostgreSQL, before writing the transport receipt.
- Every configured account must have persistent startup and retry policy. An
  `AccountConnect` command or the temporary appearance of its NIC is not
  sufficient acceptance: rollout waits until `AccountStatusGet` reports an
  established session before configuring and accepting the interface.
- A real `platform_router apply` currently builds timestamp-tagged local images;
  the changed Compose image reference recreates the shared router/client stack
  and therefore briefly interrupts all client NICs. Check mode does not perform
  this restart. Replacing timestamp tags with content-addressed image identities
  is a separate lifecycle improvement and must not be mixed into a transport
  recovery hotfix.
- The first migration rollout must be check-only first and must stop if the
  resolved account count or identities differ from the operator contract.
- Production GeoPolicy remains blocked until PostgreSQL readiness, HTTPS and all
  transport paths pass after the migration.
- New or repaired egress links use the GeoPolicy transport orchestrator rather
  than isolated service applies. It converges target `platform_router`, then
  target `edge_haproxy`, then source `platform_router`, and finishes with a
  check-only GeoPolicy acceptance. A listening server socket without an
  accepted public SNI/backend route is not a usable transport.
- `edge_route,softether_l3_vps` candidates are published through HAProxy so
  they can complete that acceptance before promotion. This exception does not
  publish candidate VPN ingress, Minecraft, or other edge routes; old aliases
  remain unpublished. HAProxy acceptance requires an `UP` backend and a local
  SNI/TLS handshake.
