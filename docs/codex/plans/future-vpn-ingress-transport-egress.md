# Future VPN ingress routing through platform_router egress

## Status

Future milestone. The current GeoPolicy transport rollout provisions and tests
the marked paths, but it does not yet redirect production VPN client traffic.
This plan starts only after all selected transport gateways and the VPS3
GeoPolicy canary are accepted.

## Goal

Use the shared `platform-router` transport layer to select an egress VPS for
ordinary VPN clients connected through VPS3. GeoPolicy remains the decision
layer: the source identifies traffic that is in scope, while the destination
determines whether the flow stays on the local VPS3 egress or receives the mark
of a non-RU transport path.

The initial source contract is the address observed after VPN SecureNAT:
`172.20.0.2/32`. This address must be revalidated on the live ingress before
every first apply or topology change; the implementation must not silently
broaden the source match to an entire VPN or Docker subnet.

## Traffic model

```text
VPN client
  -> VPN ingress on VPS3
  -> SecureNAT (observed source 172.20.0.2)
  -> GeoPolicy destination classification
       RU/special/internal destination -> ordinary VPS3 host egress
       non-RU public destination        -> stable transport mark
  -> platform-router table selected by that mark
  -> SoftEther L3 path to the selected gateway
  -> target platform-router scoped SNAT
  -> Docker bridge and target host NAT
  -> public egress of VPS1/VPS2/VPS4 or a future accepted gateway
```

`platform-router` owns tunnels, stable marks, route tables, forwarding and
target-side scoped SNAT. GeoPolicy owns destination classification, ranking,
active-path selection, health state and fail-closed behaviour. Adding or
removing a gateway must not renumber the marks or tables of surviving paths.

## Routing and connection safety

- Classify only new IPv4 flows from the exact accepted VPN ingress source.
- Restore the connection mark for established flows before evaluating a new
  destination policy.
- Do not reclassify replies to inbound VPN, HTTPS or management connections.
- Route RU public destinations directly through VPS3.
- Exclude loopback, RFC1918, CGNAT, link-local, multicast, Docker, management,
  PostgreSQL, VPN control and transport networks from remote egress.
- Route non-RU and unknown public destinations through the active accepted
  transport path.
- Disable or explicitly reject IPv6 for the scoped source until equivalent IPv6
  policy and transport acceptance exist; an IPv6 bypass is a preflight error.
- If every non-RU path is unavailable, drop only the scoped non-RU flows.
  Direct RU and internal traffic must remain available.

The target path is transit traffic rather than an ordinary ingress reply. It
therefore requires accepted `ip_forward`, scoped `FORWARD`, tunnel-side SNAT,
Docker/host NAT and a symmetric return path. A tunnel session and route-table
match alone are not sufficient acceptance evidence.

## Contracts and observability

- GeoPolicy reads the accepted variable-length path set from the
  `platform_router` runtime receipt.
- Each path retains its explicit alias, route mark, route table, tunnel
  interface, next hop and target SNAT address.
- Ranking changes preference order only; it never reallocates transport
  identities.
- The GeoPolicy receipt records the active gateway, source contract, RU dataset
  checksum, switch reason and probe results without credentials or client data.
- Counters distinguish direct RU, remote non-RU, excluded, restored-connmark and
  fail-closed decisions.
- Monitoring alerts on stale GeoIP data, source-address drift, missing marks,
  asymmetric return paths, IPv6 bypass and loss of all remote gateways.

## Rollout

1. Accept every required `platform_router` path independently, including an
   end-to-end marked external-IP, country and OpenAI reachability probe.
2. Apply and accept GeoPolicy first for `site_runtime` only.
3. Revalidate the actual post-SecureNAT VPN source on VPS3 and confirm that no
   unrelated workload shares it.
4. Render a VPN-source GeoPolicy candidate and run check mode. It must report no
   network mutations, preserve inbound conntrack flows and reject IPv6 bypass.
5. After explicit approval, enable the VPN source class for a single canary
   client/session.
6. Verify RU and internal destinations retain the VPS3 external path.
7. Verify non-RU destinations use the selected remote external IP and accepted
   country, including DNS, HTTPS and representative long-lived connections.
8. Exercise failover across the currently accepted gateways, then validate
   hysteresis and automatic return to the preferred path.
9. Exercise fail-closed with every remote gateway unavailable and confirm that
   RU/internal traffic still works.
10. Expand from the canary to all VPS3 VPN ingress traffic only after counters,
    logs and rollback have been accepted.

## Rollback

Rollback removes only the VPN source-class nftables rules and restores ordinary
VPS3 routing for new VPN flows. Existing transport tunnels, site-runtime policy
and accepted path receipts remain available for diagnosis. Established flows
may be allowed to drain or explicitly terminated according to the operator
decision; rollback must not silently migrate a live flow between public egress
addresses.

## Non-goals

- No OSPF or BGP is required for destination policy selection.
- No public exposure of private health or management endpoints.
- No automatic inclusion of new VPN source ranges or new egress VPS nodes.
- No coupling of VPN client lifecycle to transport-container recreation.

