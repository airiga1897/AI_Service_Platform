# HAProxy Edge

HAProxy is the platform edge router for public HTTP/TLS traffic and SoftEther
SNI routing. Templates in this directory must stay product-neutral and should
be rendered from `services.yml`.

For SoftEther, HAProxy owns the public TCP entrypoints:

- `443/tcp` uses SNI to separate VPN and site traffic.
- `992/tcp`, `1194/tcp`, and `5555/tcp` route by port.
- `5555/tcp` must use a management IP allowlist.

UDP traffic cannot be split by domain name in this design. Future UDP VPN
protocols should be routed by port or by separate IP/GeoDNS policy.

For public websites, a CDN may be placed before the web edge later. CDN should
terminate/cache/protect site traffic only; SoftEther VPN and management traffic
stay outside CDN and continue to use direct VPS/GeoDNS routing.

VPN acceleration is a separate research track, not the same as site CDN. Use
GeoDNS, Anycast, or L4 TCP proxy candidates if testing SoftEther acceleration.

Country/IP decisions should come from the shared GeoPolicy service when it is
added. HAProxy consumes generated allow/deny lists, but does not own the source
of truth for geography.

Current reference material:

- `infra/edge/softether/haproxy-softether.cfg.example` for the VPN routing
  fragment.
- Historical SiteProject01/AromaFlowAI configs as reference only, not as active
  platform names.

Do not hardcode `MyPet01`, product-specific domains, or real IP addresses in
new active templates.
