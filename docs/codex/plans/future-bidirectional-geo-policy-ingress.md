# Bidirectional GeoPolicy for VPN ingress

Status: future milestone. This document records intended behavior only and does
not authorize rollout or runtime changes.

## Goal

Extend the accepted VPS3 GeoPolicy model to VPN ingress on non-RU nodes without
creating routing loops.

The policy direction is selected per ingress node:

- RU ingress (`vps3`, with `vps7` as the future RU backup): RU destinations use
  the local egress; non-RU and unknown public destinations use an accepted
  non-RU terminal egress.
- non-RU ingress: non-RU and unknown public destinations use the local egress;
  RU destinations use `vps3`, with automatic failover to `vps7`.

GeoIP classification happens exactly once, on the node where the VPN client
traffic enters the platform.

## Terminal transport rule

Traffic delivered through an accepted egress transport is already classified.
The receiving node must treat it as terminal traffic:

1. Exclude every accepted terminal transport interface from the local GeoPolicy
   classification chain before source or destination matching.
2. Keep remote-ingress source identities outside the receiving node's local
   source-class set.
3. Permit only the scoped FORWARD path from the transport interface.
4. Apply terminal SNAT on the receiving node and route through its normal main
   table.
5. Return `ESTABLISHED,RELATED` traffic through conntrack without classification
   or remarking.

This formalizes the behavior already used for `vps3 -> vps1/vps2/vps4`: the
non-RU nodes currently act as terminal egress because GeoPolicy is not installed
there. Before enabling GeoPolicy on those nodes, this implicit protection must
become an explicit `terminal_ingress_interfaces` contract.

## Required contract additions

- Per-node policy direction: `ru_direct` or `non_ru_direct`.
- Local source classes with unique per-node policy-side identities.
- `terminal_ingress_interfaces` for every accepted transport link.
- RU terminal egress candidates with stable aliases, marks and route tables:
  primary `vps3`, backup `vps7`.
- Existing non-RU terminal candidates remain variable-length and receipt-driven.
- Transport networks, management networks, terminal node addresses and platform
  internal networks remain direct/system exclusions.
- A packet arriving on a terminal transport interface must never receive a new
  GeoPolicy mark.

## Failover and failure behavior

- RU-bound traffic from a non-RU ingress uses `vps3`, then `vps7` after the
  accepted health threshold.
- If both RU terminal egresses are unavailable, only affected RU-bound traffic
  fails closed. Local non-RU and internal traffic continues to work.
- Existing non-RU failover from VPS3 remains unchanged.
- A terminal node must never forward received traffic into another GeoPolicy
  transport path.

## Acceptance tests

- RU ingress sends RU destinations locally and non-RU destinations through the
  accepted non-RU terminal egress.
- non-RU ingress sends non-RU destinations locally and RU destinations through
  `vps3`, then `vps7` during failover.
- Packets received on terminal transport interfaces bypass classification and
  are SNATed exactly once.
- No flow can form `vps3 -> non-RU node -> vps3` or
  `non-RU node A -> non-RU node B -> non-RU node A`.
- Connection marks remain stable for the lifetime of a flow.
- Return traffic follows conntrack and remains symmetric.
- Removing or failing a transport produces fail-closed behavior rather than a
  fallback through the receiving node's GeoPolicy.
- IPv6 cannot bypass the policy for any scoped source class.

## Rollout boundary

Implementation is a separate milestone after the current VPS3 GeoPolicy and its
transport receipts are committed and accepted. Rollout must begin with check
mode and one non-RU ingress canary. Long tests and remote rollout commands remain
operator-run.
