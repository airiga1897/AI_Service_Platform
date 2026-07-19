# Local VPN Admin PostgreSQL Access Plan

## Summary

Provide optional local PostgreSQL access through the ordinary `vpn-vpsN`
ingress without mixing it with the inter-VPS L3 replication transport. The
intended path is local-only:

```text
vpn-vpsN -> softether-edge SecureNAT -> vpn policy handoff -> platform-router -> local PG
```

For the current PostgreSQL nodes this means:

```text
vpn-vps8 -> policy/router -> PG8 172.30.8.10:5432
vpn-vps4 -> policy/router -> PG4 172.30.4.10:5432
```

## Intended Model

- Keep `vpn_edge` as mandatory user/operator VPN ingress.
- Do not attach PostgreSQL directly to VPN networks.
- Do not use `l3-vpsN` service transport for human/admin VPN access.
- Add an explicit local policy path from `softether-edge` to `platform-router`
  through the per-node VPN policy network.
- Prefer service-facing SNAT on `platform-router` so PostgreSQL sees the stable
  local router data IP:
  - `vps8`: PG sees `172.30.8.2`
  - `vps4`: PG sees `172.30.4.2`

## Implementation Outline

1. Re-enable or recreate the per-node VPN policy handoff only where needed:
   - `vps8`: policy subnet `172.22.247.0/24`, `softether-edge 172.22.247.2`;
   - `vps4`: policy subnet `172.22.251.0/24`, `softether-edge 172.22.251.2`;
   - add `platform-router` addresses in those policy networks, using the
     existing `.4` convention unless a new convention is chosen.

2. Add local VPN admin PG policies to `platform_router`:
   - `vps8`: source `172.22.247.2/32` to `172.30.8.10:5432`;
   - `vps4`: source `172.22.251.2/32` to `172.30.4.10:5432`;
   - add narrow SNAT to the local router data IP;
   - keep replication policies separate from admin VPN policies.

3. Add routes in `softether-edge`:
   - `vps8`: `172.30.8.10/32 via <vps8 platform-router policy IP>`;
   - `vps4`: `172.30.4.10/32 via <vps4 platform-router policy IP>`.

4. Add PostgreSQL `pg_hba` intent only for the intended DB user and stable router
   source:
   - avoid superuser/admin wildcard access;
   - prefer a dedicated admin/read-only user for human VPN access;
   - remember that `vps4` is a standby and should be read-only.

## Validation

- Verify a VPN client can route only the intended local PG target.
- Verify no cross-node PG access is introduced by this local VPN path.
- Verify `pg_hba` rejects unknown users/sources.
- Verify replication traffic still uses the L3/platform-router path and remains
  unaffected.

## Assumptions

- VPN-client traffic exits `softether-edge` through SecureNAT with a stable
  Docker-side source, usually the `softether-edge` policy/edge IP.
- Local VPN admin PG access is an operator convenience path, not a public route
  and not a replacement for inter-VPS replication transport.
