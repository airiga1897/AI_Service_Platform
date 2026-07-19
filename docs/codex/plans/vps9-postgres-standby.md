# vps9 PostgreSQL Standby Expansion Plan

## Summary

Add `vps9` as a managed platform node, then validate a second PostgreSQL async
standby path from `vps9` to the existing `vps8` primary. Bootstrap has completed:
`vps9` is reachable as `useradmin`, sudo works, Docker is installed, and
`operator/nodes.csv` contains the canonical node entry. The standby expansion is
now accepted: `vps8` remains primary, and both `vps4` and `vps9` are async
streaming standbys.

The remaining related work is SoftEther cleanup, not another PostgreSQL reinit.
See [Future SoftEther runtime image](future-softether-runtime-image.md).

## Current Constraints

- `vps9` is present in `operator/nodes.csv`.
- `vps9` platform baseline, platform networks, edge/VPN baseline, and
  PostgreSQL standby initialization have completed.
- The current `platform_router` model uses one SoftEther server sidecar on
  `vps8` for the PG primary overlay, with separate standby accounts for `vps4`
  and `vps9`.
- Do not add a second server sidecar on `vps8` for `vps9`; server ports and
  listeners are shared inside the `platform-router` namespace.

## Implementation Outline

1. Keep `vps9` node metadata as the source of truth:
   - `operator/nodes.csv`: `vps9,vps9.mine-craft.su,161.104.47.37,ssh,22,`
   - `operator/vps9/admin_key`: private admin key for `useradmin@vps9`.

2. Add platform baseline intent for `vps9` in narrow phases:
   - first add `vps9` only to `platform_networks`;
   - after bootstrap and validation, add it to `edge_haproxy`, `edge_banlist`,
     `vpn_edge`, and `edge_route vpn_ingress`;
   - do not add PostgreSQL standby state until the local node baseline is
     healthy.

3. Add per-node platform networks:
   - data: `ai_service_data_vps9`, `172.30.9.0/24`
   - app: `ai_service_app_vps9`, `172.31.9.0/24`
   - keep cleanup lists consistent with existing `vps1..vps8` entries.

4. Extend `platform_router` for the shared primary overlay:
   - keep one `platform-router` container per node;
   - keep one SoftEther server sidecar on the primary side (`vps8`);
   - add separate standby client accounts in the primary hub;
   - allow per-standby client sidecars and TAP interfaces on source nodes;
   - keep `vps4` replication path unchanged while adding `vps9`.

5. Add `vps9` to the current `vps8` primary overlay:
   - shared primary hub on `vps8`, not a second server sidecar;
   - add a `vps9` standby account with a fixed client VPN IP;
   - runtime mode: `platform_router_sidecar`
   - primary service target: `172.30.8.10:5432`
   - source policy: `172.30.9.0/24 -> 172.30.8.10:5432`
   - avoid `vpn_cascade`, `softether_p2p`, SoftEther Cascade, and Local Bridge.

6. Add PostgreSQL intent only after TCP proof:
   - `postgres_runtime` candidate aliases become `vps4+vps9`;
   - add `vps9` service route:
     `172.30.8.10/32 via 172.30.9.2`;
   - prove the `vps9` path and then add the actual PG-observed source to
     `replication_hba_cidrs_by_alias.vps8`;
   - run `vps9` standby reinit only with explicit `-ReinitStandby`.

## Validation

- Local checks:
  - `git diff --check`
  - `python tools/validate-services-yml/validate_services_yml.py --strict`
  - `python tools/render-edge/render_edge.py --check`
  - `python tools/render-compose/render_compose.py --stack all --check`
  - `.\tools\services\check_vpn_cascade_links.ps1 -Json`
  - `.\tools\services\service.ps1 platform_networks plan`
  - `.\tools\services\service.ps1 softether_l3_vps plan`
  - `.\tools\services\service.ps1 platform_router plan`
  - `.\tools\services\service.ps1 postgres_runtime plan`

- Runtime checks before destructive reinit:
  - SSH works via `useradmin@vps9` using `operator\vps9\admin_key`;
  - Docker and platform networks are healthy on `vps9`;
  - `vps9 ai-service-postgres` routes `172.30.8.10` via `172.30.9.2`;
  - `vps9 platform-router` routes `172.30.8.10` through its per-link VPN
    interface;
  - TCP proof from `vps9 ai-service-postgres` to `172.30.8.10:5432` succeeds;
  - `vps8` logs or SQL observation confirm the source identity before pg_hba is
    finalized.

- Standby acceptance:
  - `vps8`: `pg_is_in_recovery() = false`;
  - `vps4`: `pg_is_in_recovery() = true`, WAL receiver `streaming`;
  - `vps9`: `pg_is_in_recovery() = true`, WAL receiver `streaming`;
  - `vps8 pg_stat_replication` sees `ai_sp_vps4` and `ai_sp_vps9` as
    `streaming` / `async`;
  - both replication slots are active;
  - primary-observed replication source is `172.30.8.2` for both standbys.

## Assumptions

- `vps9` follows the existing addressing convention: data `172.30.9.0/24`, app
  `172.31.9.0/24`.
- The second standby uses its own account/client identity in the current
  `vps8` primary overlay. It should not create a second SoftEther server
  sidecar on `vps8`.
- The `vps9` endpoint, public IP, and admin key are now present; remaining
  operator state changes should still be phased.
- No broad rollout and no destructive reinit are part of the bootstrap phase.
