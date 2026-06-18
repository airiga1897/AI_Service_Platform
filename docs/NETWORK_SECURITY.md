# Network Security

This runbook documents the active network-security layers for AI Service
Platform nodes and edge traffic.

## Host Firewall

`bootstrap_converge` owns the host firewall baseline. It installs and enables
UFW with:

- default incoming policy: `deny`;
- default outgoing policy: `allow`;
- explicit TCP allows for current platform public ports:
  `22`, `80`, `443`, `992`, `5555`, `8443`, `8555`, `8992`, `25565`, `25575`.

The port list is intentionally broad for the first enforced baseline so existing
SSH, edge VPN, cascade, and Minecraft paths are not accidentally closed.

## Edge HAProxy

`edge_haproxy` owns public edge filtering. Operator-controlled lists live under
`operator/haproxy/lists/`:

- `blocked_ips.lst` - manual IP/CIDR deny list applied before route handling.
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
