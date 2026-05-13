# SoftEther Edge Templates

SoftEther is a platform edge/VPN component. Product stacks do not own it.
The target topology runs one SoftEther instance on each VPS node.

The templates in this directory are placeholders for the future renderer:

- `docker-compose.softether.yml.example` defines the SoftEther service,
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

Do not commit `vpn_server.config`, real management allowlists, passwords, or
private keys.
