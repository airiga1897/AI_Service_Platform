# Edge HAProxy Security Layers

This note tracks the edge security layers ported from the previous HAProxy
security work.

## Current Layers

Current protection:

- manual blacklist through `operator/haproxy/lists/blocked_ips.lst`;
- management allowlist for `5555/tcp` through `operator/haproxy/lists/vpn_mgmt_ips.lst`;
- optional GeoIP source list through `operator/haproxy/lists/ru_networks.lst`;
- soft TCP stick-table rate limiting for VPN and Minecraft;
- HTTP request/error-rate stick-table protection;
- scanner-path blocking for common web probe paths;
- ACME bypass for `/.well-known/acme-challenge/`;
- local-only HAProxy stats.

## Remaining Future Layers

- site-specific routing/security policies;
- operational scripts for safe HAProxy reload and log analysis.

## Rule

VPN routes and site routes must stay separate in policy. A rule designed for
web scanners must not apply to SSTP/SoftEther TCP traffic unless it is explicitly
tested and documented.
