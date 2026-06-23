# Future plan: SD-WAN-like egress controller

This plan reserves a future routing-policy layer that behaves like a small
SD-WAN controller for controlled VPN egress. It is not a request to route all
host traffic through the overlay and does not change current rollout behavior.

## Summary

The controller should choose between ingress-local egress and explicit cascade
egress paths. The first production-safe version is selective and profile-based:
it heals domains/IPs listed in `operator/egress_policy/profiles.json`, using
active cascade topology as the allowed path set.

A later version should support detect-and-promote fallback: when a local target
does not open, the controller probes one or more available cascade fallbacks,
compares behavior, and promotes a selective fallback route only when the
fallback result is better or clearly more reachable than the local result.

The goal is faster recovery than manual `probe -> suggest -> apply`: maintain
health for direct and cascade candidates, switch applied selective fallback
routes when the current path fails, and roll back to direct when direct becomes
stable again.

## Design Direction

- Treat `direct <ingress>` and `cascade <ingress>><egress>` as candidate paths
  for each explicit target.
- Keep SoftEther cascade as transport only; the controller owns path selection.
- Start with selective exact-route control, not full default-route SD-WAN.
- Use active `cascade_topology` and `profiles.json` as hard allowlists; retired
  paths such as `vps4>vps3` are never eligible.
- Prefer safe convergence over instant failover: use health windows, hysteresis,
  and cooldowns so routes do not flap.
- Compare local and fallback behavior before promoting a route. Fallback
  reachability by itself is not enough when the local path is already healthy.
- Allow detect-and-promote only inside an explicit policy scope. The controller
  may discover a failing target, but automatic apply requires profile or class
  policy that permits promotion.

## Detect-and-Promote Fallback

The future automatic flow is:

```text
observe local failure -> probe fallback candidates -> compare behavior -> promote route -> verify -> refresh or expire
```

Decision rules:

- Probe the local ingress path first.
- If the local path is healthy, do not create or switch a route.
- If the local path times out, resets, or returns a clear failure, probe active
  cascade fallback candidates.
- Promote a fallback when it improves the result, for example local timeout to
  fallback `200`/`3xx`, or local `403` to fallback `200`/`307`.
- Treat fallback `403`/`404` as "target reachable", not always "site works".
  A profile-specific policy decides whether that is enough.
- If fallback is not better than local, do not apply a route.

Promotion modes:

- `proposal` - write a proposal only; operator accepts or rejects it.
- `auto_promote` - apply a route automatically when policy and confidence allow
  it.
- `canary` - apply only one target or IP before expanding.
- `ttl_route` - apply a temporary route that must be refreshed or expires.

Required guardrails:

- Never enable full default egress automatically.
- Never apply inconclusive timeout/probe-error fallback.
- Never apply when local and fallback are equally healthy.
- Always write rollback state before runtime changes.
- Always verify after apply.
- Deduplicate route/NAT state for equivalent `IP:port` targets.
- Include the selected path in proposal and applied-route IDs, for example
  `vps1-to-vps3`, so path changes do not reuse stale decisions.

## Roadmap

1. **Selective health cache**
   - Store latest health per profile, target, ingress, candidate path.
   - Probe only the affected profile/target set, not the whole fleet.
   - Record latency, HTTP/TCP status, external IP/country, and failure reason.

2. **Reconciler control loop**
   - Extend `reconcile_selective_fallback.ps1` into one-shot and scheduled
     modes.
   - In check mode, report planned path changes only.
   - In apply mode, switch only when the current path is failed for N probes and
     an allowed alternative is healthy.

3. **Policy and safety**
   - Default policy: direct wins when healthy; cascade is fallback.
   - Route apply remains exact-target and self-auditing.
   - Rollback must restore direct/default egress and verify route/NAT removal.
   - Full-host default-route SD-WAN is out of scope until the selective layer is
     proven stable.
   - Add profile/class fields such as `auto_promote`, `promotion_mode`, and
     route TTL.
   - Add aggregate counters by `IP:port` so equivalent NAT rules do not make
     verification ambiguous.

4. **Operations**
   - Run from the operator/orchestration side first; do not deploy a daemon to
     every VPS in v1.
   - Use short, bounded probes and write history for review.
   - Target reaction time after v1 stabilization: about 30-60 seconds for
     detection plus switch, not sub-second failover.
   - Provide batch rollback by profile/path.
   - Refresh DNS-derived route sets safely and expire stale target IPs.

## Acceptance Criteria

- If direct egress for an approved target fails and `vps4>vps6` is healthy, the
  controller can switch the exact route to `vps6` without manual proposal
  editing.
- If the current cascade path becomes stale or retired, the controller refuses to
  use it and removes/replaces the applied route only through explicit active
  candidates.
- If direct egress recovers for a configured stability window, the controller can
  plan or apply rollback to direct.
- A failed probe or ambiguous result never creates a new domain target and never
  changes full host default routing.
- If local egress fails and a permitted fallback path produces a better result,
  the controller can create a path-specific proposal or TTL route without
  colliding with older decisions for a different fallback path.

## Assumptions

- The first version reuses existing selective fallback tools: probe, suggest,
  apply, refresh, and reconciler.
- `profiles.json`, `state.csv`, and cascade secrets remain operator-controlled
  sources of truth.
- Full SD-WAN for all outbound traffic is a later, separate architecture decision
  requiring out-of-band access, watchdog rollback, and broader observability.
