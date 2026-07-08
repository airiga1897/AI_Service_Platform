# Active-Ready PostgreSQL Failover Plan

## Summary

This is a future design, not the current implementation track. The current path
remains simple: keep `vps8` as primary, keep `vps4` streaming, add `vps9` as a
second standby only after proving the `vps9 -> vps8` service path. Active-ready
failover is documented here so the transport model does not drift toward
multiple competing SoftEther server sidecars in one router namespace.

## Design

- Each potential primary (`vps4`, `vps8`, `vps9`) can own a primary-side
  `platform-router-softether-server` sidecar when it is the active primary.
- Standby nodes use `platform-router-softether-client` sidecars that connect to
  the current primary's SoftEther hub.
- Use one PG overlay hub per primary, not one hub per standby link. For current
  `vps8` primary, use a shared hub such as `P2PPgPrimaryVps8`.
- The primary hub uses one VPN subnet, for example `10.88.48.0/24`:
  - server/SecureNAT: `10.88.48.1`
  - `vps4` standby account: fixed client IP such as `10.88.48.4`
  - `vps9` standby account: fixed client IP such as `10.88.48.9`
- The primary-side PostgreSQL source identity remains the primary
  `platform-router` data IP:
  - `vps8` primary: `172.30.8.2`
  - `vps4` primary: `172.30.4.2`
  - `vps9` primary: `172.30.9.2`

## Operational Model

- PostgreSQL distinguishes standbys by replication slot and application name,
  not by transport source IP:
  - `ai_sp_vps4`
  - `ai_sp_vps9`
- Promotion remains manual. Active-ready does not mean automatic failover.
- A primary move still requires fencing the old primary, promoting the selected
  standby, changing operator state, and rebuilding other nodes as standbys from
  the new primary.
- Do not run multiple SoftEther server sidecars in one `platform-router`
  namespace for the same primary. Ports/listeners are shared, so server-side
  multi-standby support belongs inside one server sidecar with multiple hub
  users/accounts.

## Deferred Implementation

- Extend `softether_l3_vps` intent from link-per-standby to primary-overlay
  intent with a shared hub and multiple standby accounts.
- Extend `platform_router` to generate:
  - one server sidecar on the primary side;
  - one client sidecar per standby source;
  - per-standby route and narrow source-side SNAT rules;
  - one target-side PG policy allowing the primary router data IP.
- Keep `vpn_cascade`, `softether_p2p`, SoftEther Cascade, and Local Bridge out
  of the design.

## Current Track

- Finish current PG topology first:
  - `vps8` primary;
  - `vps4` standby;
  - future `vps9` standby after path proof.
- After PostgreSQL is stable, move to nginx.
