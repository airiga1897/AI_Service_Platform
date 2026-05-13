# Nginx Edge

Nginx owns per-site reverse proxy behavior and Certbot renewal integration.
SoftEther does not own certificates directly; it consumes a read-only TLS copy
that is produced from the Nginx/Certbot certificate source.

Templates added here should be rendered from `services.yml` and must avoid
hardcoded legacy project names, real IP addresses, or committed secret paths.

Related reference:

- `infra/edge/softether/docker-compose.softether.yml.example`
- `docs/SOFTETHER_VPN.md`
