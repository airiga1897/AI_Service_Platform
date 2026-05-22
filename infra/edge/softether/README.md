# SoftEther Edge Templates

SoftEther `vpn_edge` is a platform edge/VPN component. Product stacks do not
own it. The target topology runs one SoftEther edge instance on each VPS node.
Future `vpn_cascade` site-to-site transport is a separate reserved service and
must not reuse the edge config, container, or volumes without an explicit
migration plan.

The templates in this directory are placeholders for the future renderer:

- `docker-compose.softether.yml.example` defines the SoftEther edge service,
  persistent volumes, TCP-only exposed container ports, and TLS mount contract.
- `haproxy-softether.cfg.example` defines the HAProxy SNI and management routing
  pattern.

Current listener contract:

- `443/tcp`: HAProxy separates site and VPN by TLS SNI.
- `992/tcp`: HAProxy routes by port to SoftEther.
- `1194/tcp`: HAProxy routes by port to SoftEther.
- `5555/tcp`: HAProxy routes by port to SoftEther management with an allowlist.

UDP is not part of the current preserved setup. If IPsec, L2TP, or OpenVPN UDP
is enabled later, route it by port/IP, not by domain name.

The edge ingress seed config is an opaque secret state file:

```text
operator/softether/edge/vpn_server.config
```

It may contain multiple VirtualHUBs, users, groups, SecureNAT/DHCP, passwords,
and certificates. Do not parse or patch it with string replacements in v1.

Do not commit `vpn_server.config`, real management allowlists, passwords, or
private keys.
