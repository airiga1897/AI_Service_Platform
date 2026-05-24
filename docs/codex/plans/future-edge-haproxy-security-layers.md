# Future Plan: Edge HAProxy Security Layers

This plan preserves ideas from the previous HAProxy security work, but keeps
them out of the first `edge_haproxy` rollout.

## Why Deferred

The first HAProxy rollout serves the VPN/TCP path. It must not accidentally
block SSTP or SoftEther management traffic with HTTP-specific rules.

Current v1 protection:

- manual blacklist through `operator/haproxy/lists/blocked_ips.lst`;
- management allowlist for `5555/tcp` through `operator/haproxy/lists/vpn_mgmt_ips.lst`;
- soft TCP stick-table rate limiting;
- local-only HAProxy stats.

## Future Layers

Add these only after VPN over HAProxy is stable:

- GeoIP/generated policy allow/deny lists;
- site-specific routing/security policies;
- scanner-path autoban for HTTP frontends;
- HTTP error-rate bans;
- ACME bypass rules that never block Let's Encrypt validation;
- separate policies for website routes and VPN routes;
- operational scripts for safe HAProxy reload and log analysis.

## Rule

VPN routes and site routes must stay separate in policy. A rule designed for
web scanners must not apply to SSTP/SoftEther TCP traffic unless it is explicitly
tested and documented.
