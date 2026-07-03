# Network Security

This runbook documents the active network-security layers for AI Service
Platform nodes and edge traffic.

## Host Firewall

`bootstrap_converge` owns the host firewall baseline. It installs and enables
UFW with:

- default incoming policy: `deny`;
- default outgoing policy: `allow`;
- explicit TCP allows for current platform public ports:
  `22`, `80`, `443`, `992`, `5555`, `25565`, `25575`.

Retired cascade-only host ports `8443`, `8555`, and `8992` are no longer part
of the expected public surface. Cascade/fallback traffic uses
`cascade-vpsN.mine-craft.su:443` through HAProxy SNI routing.

Fresh bootstrap/converge must also remove any stale UFW allow rules for retired
ports and fail if UFW does not end in `Status: active`.

## Ban Layer

`bootstrap_converge` installs and enables `fail2ban` with an `sshd` jail on all
platform VPS nodes. This is the baseline automatic ban layer for repeated SSH
authentication attempts.

The older `security` role also manages `fail2ban` when the full Ansible
`site.yml` path is used. Both paths should leave `fail2ban` active. HAProxy
scanner-path blocking is currently enforced inline by HAProxy rules and is not
yet an automatic fail2ban jail.

## Edge HAProxy

`edge_haproxy` owns public edge filtering. Operator-controlled lists live under
`operator/haproxy/lists/`:

- `blocked_ips.lst` - manual IP/CIDR deny list applied before route handling.
- `generated_blocked_ips.lst` - automatic TTL deny list managed on each VPS by
  `edge_banlist`; operators do not edit it directly.
- `vpn_mgmt_ips.lst` - SoftEther management allowlist for `5555/tcp`; missing
  or empty means management is closed for everyone.
- `ru_networks.lst` - optional GeoIP source list. It is copied to target nodes
  when present, but enforced only by explicit route policy such as
  `geoip: ru_only`.

HTTP edge protection keeps ACME challenges open at
`/.well-known/acme-challenge/`. Non-ACME HTTP requests are checked against the
manual blacklist, HAProxy stick-table request/error-rate limits, and common
scanner paths such as `/.env`, `/.git`, `/wp-admin`, `/phpmyadmin`,
`/actuator`, and `/admin`.

VPN ingress on `443/992/5555` remains TCP-only. HTTP scanner rules and GeoIP
deny rules are not applied to VPN ingress.

TCP edge denials are intentionally quiet. For VPN, management, Minecraft, RCON,
blocked source IPs, route-rate limits, and SNI mismatches, HAProxy uses
`silent-drop` rather than `reject`. This makes invalid `cascade-vpsN` SNI probes
or non-allowlisted management attempts look like a timeout while keeping valid
`vpn-vpsN` traffic on the same public ports working.

`Test-NetConnection` can still report TCP success for an unused `cascade-vpsN`
name when it resolves to a VPS where HAProxy legitimately listens on shared
`443/992/5555` for VPN ingress. The security invariant is that invalid SNI is
not routed to a backend and eventually times out.

## Edge Banlist

`edge_banlist` is the HAProxy-native replacement for the older Nginx log-based
ban layer. It reads HAProxy stick-tables through the runtime socket and keeps a
separate generated TTL blacklist. The manual `blocked_ips.lst` is never edited
by automation, and entries from `vpn_mgmt_ips.lst` and private/internal networks
are never banned.

The first rollout is a canary on `vps2` in `observe` mode, configured by
`operator/edge_banlist/config.yml`. In `observe`, candidates are logged to
`/var/log/ai-service-platform/edge_banlist.log` and no generated bans are
enforced. Switching the config to `enforce` is a separate operator decision
after the canary log is reviewed.

`edge_banlist` intentionally uses `socat` for the first rollout. The critical
invariant is the HAProxy runtime socket lifecycle, not the client implementation:
`/opt/ai-service-platform/edge_haproxy/run/admin.sock` must exist and accept
`show table ...` commands. If the socket is missing, stale, or has bad
permissions, the collector logs `edge_banlist_error` and does not fail the
systemd timer.

Repeated scanner IPs use exponential TTL backoff. The default first ban is one
hour, and each later reappearance doubles the TTL up to a 24 hour cap. Because
generated-banned IPs are dropped before HAProxy stick-table tracking, repeats
during an active ban are usually not visible; repeat history is therefore kept
in `bans.json` and pruned after 30 days past expiry.

## Bootstrap SSH Direction

Bootstrap and converge should avoid managed-node-to-orchestration SSH paths.
When orchestration state or bundles are needed on the active control node,
the operator uploads to the control node and the control node runs Ansible
outbound to selected targets. Do not design a flow where a non-Russian VPS such
as `vps2` must initiate SSH to Russian control nodes such as `vps6`; if data is
needed from `vps2`, the control side should fetch it or the operator should push
it explicitly.

Ansible bootstrap converge uses explicit SSH connect and keepalive timeouts so
provider-level SSH filtering fails quickly instead of hanging the rollout.

## Operator Rollout

Long-running PowerShell and remote rollout commands are run by the operator.
After repo changes, run:

```powershell
.\tools\services\service_remote.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -Service edge_haproxy `
  -Action apply `
  -Check
```

If check mode is green:

```powershell
.\tools\services\service_remote.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -Service edge_haproxy `
  -Action apply
```

Then run the normal rollout:

```powershell
.\tools\services\rollout_from_state.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv
```

After rollout, run the read-only network security checker:

```powershell
.\tools\services\check_network_security.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv
```

For one edge node:

```powershell
.\tools\services\check_network_security.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -Limit vps4
```

Rollback is a normal rollout after reverting the relevant route, list, or
template change. For emergency access issues, disable the affected route policy
first; do not purge VPN or cascade data.
