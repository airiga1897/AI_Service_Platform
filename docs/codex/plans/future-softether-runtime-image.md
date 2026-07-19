# Future SoftEther Runtime Image

## Summary

This is the next SoftEther cleanup/refactor track after PostgreSQL acceptance.
The current PostgreSQL state is already proven: `vps8` is primary, and `vps4`
and `vps9` are async streaming standbys. This plan must not change the working
PG topology first; it records the safe order for consolidating SoftEther
packaging and hardening the `platform_router` sidecar runtime.

Current PG overlay facts:

- `vps8` owns the primary-side `platform-router-softether-server`.
- `vps4` and `vps9` use client sidecars in their `platform-router` namespaces.
- The current shared hub is named `P2PPgPrimaryVps8`.
- Fixed client VPN identities are `vps4 = 10.88.48.4` and
  `vps9 = 10.88.48.9`.
- PostgreSQL on the primary sees both standby paths as source `172.30.8.2`.
- `vps8 pg_stat_replication` shows `ai_sp_vps4` and `ai_sp_vps9` as
  `streaming` / `async`.

## Target Model

- Build one generated image, for example
  `ai-service-platform/softether-runtime:<generated>`.
- The image contains:
  - `vpnserver`;
  - `vpnclient`;
  - `vpncmd`;
  - `hamcore.se2`;
  - `libcedar.so` and `libmayaqua.so`;
  - minimum runtime tools required by existing sidecar entrypoints.
- Keep one pinned upstream SoftEther ref for both server and client binaries.
- Use the same Docker save/load delivery model already used by
  `platform_router`; managed VPS nodes must not build or pull the image.

## Runtime Shape

- Use one image, but keep separate containers and commands:
  - `platform-router-softether-server` runs `vpnserver`;
  - `platform-router-softether-client` runs `vpnclient`.
- Keep both containers in the `platform-router` network namespace when used for
  the PostgreSQL overlay.
- Do not merge `vpnserver` and `vpnclient` into one multi-process container in
  the first implementation. Separate containers keep logs, health checks,
  restart behavior, state dirs, and secrets easier to reason about.
- Do not merge PG overlay SoftEther runtime with `vpn_edge` in the first
  implementation. User/admin VPN ingress and PostgreSQL replication overlay
  remain separate trust domains.

## Implementation Plan

0. Keep this as a documentation/acceptance snapshot before changing runtime.
1. Keep the hub name stable during future image refactors. Hub naming cleanup
   has already moved the PostgreSQL overlay toward `P2PPgPrimaryVps8`.
2. Add a new Docker build context for the unified image, or rename the current
   `softether-vpnclient` context after it can also package `vpnserver`.
3. Build `vpnserver`, `vpnclient`, `vpncmd`, and `hamcore.se2` from the same
   pinned SoftEther source checkout.
4. Add build-time assertions for all required runtime artifacts before the
   final image stage.
5. Extend `platform_router` image delivery to produce and verify one
   `softether-runtime` image ID, then copy/load it to hosts that need any
   SoftEther sidecar.
6. Change platform-router sidecar compose templates to use the unified image
   with process-specific commands.
7. Harden `platform_router` role checks after image unification:
   - fail clearly when expected hub users or fixed client IP intent are missing;
   - verify managed routes for each standby source;
   - keep check-mode free of undefined register fields.
8. Keep `vpn_edge` and legacy/standalone `softether_l3_vps` image alignment as
   later follow-up work, after the PG overlay path is stable.

## Validation

- Local checks:
  - `git diff --check`;
  - `python tools/validate-services-yml/validate_services_yml.py --strict`;
  - `python tools/render-edge/render_edge.py --check`;
  - `python tools/render-compose/render_compose.py --stack all --check`;
  - `.\tools\services\check_vpn_cascade_links.ps1 -Json`;
  - `.\tools\services\service.ps1 platform_router plan`.
- Narrow rollout only:
  - `.\tools\services\rollout_from_state.ps1 -NodesFile .\operator\nodes.csv -StateFile .\operator\state.csv -OnlyService platform_router`.
- Runtime checks:
  - server sidecar starts and `vpncmd` can manage the hub/listeners;
  - client sidecars start and `vpn_l3vps0` appears in the shared namespace;
  - existing `vps4 -> vps8` and `vps9 -> vps8` PG TCP paths still work;
  - no `vpn_cascade`, no `softether_p2p`, no Cascade or Local Bridge.

## Assumptions

- The primary benefit is operational consistency, not image count reduction.
- One reproducible image with separate containers is simpler to troubleshoot
  than one container running both SoftEther server and client processes.
- Hub naming cleanup is intentionally deferred until after the unified image
  rollout is stable.
- Broader active-ready failover work starts only after this cleanup is stable.
