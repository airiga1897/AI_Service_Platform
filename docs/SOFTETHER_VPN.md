# SoftEther VPN

SoftEther VPN is a first-class platform edge component. It must not be removed
or treated as incidental legacy state during migration from MyPet01/AromaFlowAI
runtime names.

SoftEther belongs to the infrastructure layer. Product runtimes such as
`aromaflow-work`, `aromaflow-demo`, `ai-retail-mvp`, and `ai-retail-dev` may be
routed through the shared edge, but they do not own the VPN service.

Target state: SoftEther runs on every VPS node:

- VPS1 in Latvia;
- VPS2 in Kazakhstan;
- VPS3 in Russia.

The existing preserved setup is TCP-only. UDP VPN protocols are future optional
features, not current required listeners.

Additional countries can be added later as VPN-only edge nodes. Such nodes run
HAProxy TCP entrypoints, SoftEther, monitoring, and backup for VPN config, but
do not host product runtimes, product databases, or product deploy workflows.

Standard website CDN is not the default transport for SoftEther because VPN is
not normal HTTP site traffic. Future acceleration may still be tested through
GeoDNS, Anycast, or an L4 TCP proxy provider for `443/tcp`, `992/tcp`, and
`1194/tcp`. Management on `5555/tcp` must remain direct and allowlisted.

## Platform Role

- HAProxy owns public TCP entrypoints and sends VPN traffic to the SoftEther
  container inside the Docker network.
- On `443/tcp`, HAProxy can separate site and VPN traffic by domain name because
  it can see TLS SNI.
- On UDP, domain-name routing is not available in this design; UDP packets are
  routed by IP and port if UDP protocols are enabled later.
- Nginx/Certbot own certificate renewal; SoftEther consumes copied certificate
  files from the shared TLS directory.
- VPN configuration and logs are persistent platform data and are included in
  backup, restore, monitoring, and firewall rules.

## Current TCP Ports

| Port | Protocol | Purpose |
|---|---|---|
| `443` | TCP | SSTP/SSL VPN through HAProxy SNI routing |
| `992` | TCP | SoftEther alternative SSL endpoint |
| `1194` | TCP | OpenVPN-compatible TCP endpoint |
| `5555` | TCP | SoftEther Server Manager, IP-filtered |

## Future Optional UDP Ports

These ports are not active in the current preserved setup. Add them only after
the matching SoftEther protocols are enabled and tested:

| Port | Protocol | Purpose |
|---|---|---|
| `500` | UDP | IPsec/IKE |
| `4500` | UDP | IPsec NAT-T |
| `1701` | UDP | L2TP |
| `1194` | UDP | OpenVPN-compatible UDP endpoint |

## Required Volumes

- `softether_data`: SoftEther server configuration, including
  `vpn_server.config`.
- `softether_logs`: SoftEther server logs.
- `certbot_conf`: certificate source of truth owned by Certbot.
- Nginx/Certbot TLS copy directory mounted read-only into SoftEther as
  `/etc/ssl/vpn`.

## Backup And Restore

Backup scope must include:

- `softether_data`;
- `softether_logs` when useful for incident review;
- copied VPN certificate files;
- HAProxy VPN routing config and management allowlist.

Restore is incomplete until:

- SoftEther container starts with the restored `softether_data` volume;
- VPN certificate files are present and valid;
- HAProxy routes VPN SNI to SoftEther;
- ports `443/tcp`, `992/tcp`, `1194/tcp`, and `5555/tcp` are intentionally
  routed through HAProxy;
- future UDP ports are intentionally open or blocked according to the enabled
  protocol set;
- management port `5555` is reachable only from approved IPs.

## Product HA Boundary

Do not build AromaFlowAI or AI_E_Retail high availability on top of SoftEther.
Product availability belongs to DNS, HAProxy/Nginx, private node overlay,
backup/restore, replication, and deploy rollback. SoftEther is for VPN access,
management access, and controlled egress routing.

## Monitoring And Security

- Monitor SoftEther TCP endpoints and container health.
- Prefer TCP health checks over ICMP-only checks.
- Keep Server Manager access IP-filtered.
- Include SoftEther logs in fail2ban or alerting only after confirming the log
  format and real client IP behavior.
- Do not commit `vpn_server.config` if it contains passwords, users, keys, or
  other secrets.
