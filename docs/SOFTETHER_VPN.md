# SoftEther VPN

SoftEther VPN — первоклассный edge-компонент платформы. Его нельзя удалять или
трактовать как случайное legacy-состояние при миграции с runtime-имён
MyPet01/AromaFlowAI.

SoftEther относится к слою инфраструктуры. Продуктовые рантаймы вроде
`aromaflow-work`, `aromaflow-demo`, `ai-retail-mvp` и `ai-retail-dev` могут
маршрутизироваться через общий edge, но не владеют VPN-сервисом.

Целевое состояние: SoftEther работает на каждом active VPN/edge alias из
`state.csv`, например `vps1`, `vps2` или `vps3`.

Существующая сохранённая установка — только TCP. UDP-протоколы VPN — будущая
опция, а не обязательные текущие listener-ы.

В дальнейшем можно добавлять новые VPN-only edge-узлы без географических
assumptions в документации. На таких узлах работают HAProxy TCP entrypoints,
SoftEther, мониторинг и бэкап VPN-конфигурации, но они не хостят продуктовые
рантаймы, продуктовые БД или продуктовые workflow-ы деплоя.

Обычный сайтовый CDN — не транспорт SoftEther по умолчанию, потому что VPN —
не обычный HTTP-трафик сайтов. Будущее ускорение можно отдельно тестировать
через GeoDNS, Anycast или L4 TCP proxy для `443/tcp` и `992/tcp`.
Управление на `5555/tcp` должно оставаться напрямую и в allowlist.

## Роль платформы

- HAProxy владеет публичными TCP entrypoints и направляет VPN-трафик в
  контейнер SoftEther внутри Docker-сети.
- На `443/tcp` HAProxy умеет разделять трафик сайтов и VPN по доменному
  имени, потому что видит TLS SNI.
- По UDP маршрутизация по доменному имени в этой схеме не доступна; UDP-пакеты
  маршрутизируются по IP и порту, если UDP-протоколы будут включены позже.
- Nginx/Certbot владеют обновлением сертификатов; SoftEther потребляет
  скопированные файлы сертификатов из общего TLS-каталога.
- Конфигурация и логи VPN — это persistent-данные платформы, и они входят в
  бэкап, восстановление, мониторинг и правила firewall.

## Текущие TCP-порты

Машинно-читаемый список — в [`services.yml`](../services.yml) под ключом `platform.edge_vpn.ports`. Таблица ниже — производное от него для людей; при расхождении источник истины — `services.yml`.

| Порт | Протокол | Назначение |
|---|---|---|
| `443` | TCP | SSTP/SSL VPN через HAProxy SNI routing |
| `992` | TCP | Альтернативный SSL endpoint SoftEther |
| `5555` | TCP | SoftEther Server Manager, IP-фильтрация |

## Будущие опциональные UDP-порты

Эти порты не активны в текущей сохранённой установке и не входят в `platform.edge_vpn.ports`. Добавлять их только после того, как соответствующие протоколы SoftEther включены и проверены; одновременно расширять `services.yml`.

| Порт | Протокол | Назначение |
|---|---|---|
| `500` | UDP | IPsec/IKE |
| `4500` | UDP | IPsec NAT-T |
| `1701` | UDP | L2TP |

## Обязательные тома

- `softether_data`: конфигурация сервера SoftEther, включая
  `vpn_server.config`.
- `softether_logs`: логи сервера SoftEther.
- `certbot_conf`: источник истины по сертификатам, владелец — Certbot.
- Каталог TLS-копий Nginx/Certbot, монтируемый read-only в SoftEther как
  `/etc/ssl/vpn`.

## Бэкап и восстановление

В скоуп бэкапа должны входить:

- `softether_data`;
- `softether_logs`, когда полезны для разбора инцидентов;
- скопированные файлы VPN-сертификатов;
- VPN-конфиг маршрутизации HAProxy и management allowlist.

Восстановление считается неполным, пока:

- контейнер SoftEther не стартанул с восстановленным томом `softether_data`;
- файлы VPN-сертификатов не присутствуют и не валидны;
- HAProxy не маршрутизирует VPN SNI на SoftEther;
- порты `443/tcp`, `992/tcp` и `5555/tcp` не маршрутизированы
  через HAProxy осознанно;
- будущие UDP-порты не открыты или не закрыты осознанно согласно набору
  включённых протоколов;
- management-порт `5555` не доступен только с разрешённых IP.

## Граница продуктовой HA

Не строить high availability AromaFlowAI или AI_E_Retail поверх SoftEther.
Доступность продуктов обеспечивается DNS, HAProxy/Nginx, частной overlay-сетью
узлов, бэкапом/восстановлением, репликацией и rollback деплоя. SoftEther — для
VPN-доступа, management-доступа и контролируемой маршрутизации egress.

## Мониторинг и безопасность

- Мониторить TCP endpoints SoftEther и здоровье контейнера.
- Предпочитать TCP healthcheck-и проверкам только по ICMP.
- Доступ к Server Manager держать под IP-фильтром.
- Включать логи SoftEther в fail2ban или алертинг только после подтверждения
  формата логов и реального поведения client IP.
- Не коммитить `vpn_server.config`, если он содержит пароли, пользователей,
  ключи или другие секреты.

## SoftEther Config Updates

`operator/softether/edge/vpn_server.config` is an install seed, not a file that
normal rollout continuously enforces. After the first successful start, the
remote `/opt/ai-service-platform/vpn_edge/softether_data/vpn_server.config`
belongs to SoftEther runtime state and may be changed by SoftEther itself.

Normal `vpn_edge present` rollout copies the seed only when the remote config is
missing. It does not overwrite the live config and does not restart
`softether-edge` because of the seed.

Retired listeners are handled as explicit one-time migrations, not continuous
rewrites. The current retired listener is `1194/tcp`: on the first rollout where
the migration marker is absent, the role backs up the live config, stops the
container, removes that listener block from the live `vpn_server.config`,
restarts the container, verifies absence, and writes a service-local
`.retired_tcp_listeners_applied` marker. Later rollouts only verify that the
retired listener did not return. This applies to both `vpn_edge` and
`vpn_cascade`.

Intentional replacement uses the explicit reseed action and must target one
alias:

```powershell
.\tools\services\rollout_from_state.ps1 -ReseedVpnEdge vps4
```

WSL/Linux equivalent:

```bash
bash tools/services/rollout_from_state.sh --reseed-vpn-edge vps4
```

The low-level debug escape hatch is:

```powershell
.\tools\services\service_remote.ps1 vpn_edge reseed -Limit vps4
```

The reseed action requires an installed `vpn_edge`, creates a timestamped backup
of the live config, copies the operator seed, restarts `softether-edge`, verifies
the container, and prints the backup path. More granular `vpncmd` updates are
reserved for a later phase.

## SoftEther Cascade Transport

`vpn_cascade` is the separate site-to-site/cascade transport service. It is not
the user VPN ingress and it does not reuse `/opt/ai-service-platform/vpn_edge`.
The rollout creates a distinct container, config volume, logs directory, backup
directory, and Docker network:

```text
/opt/ai-service-platform/vpn_cascade
ai_service_cascade 172.21.0.0/24
softether-cascade  172.21.0.2
```

The user VPN ingress and cascade transport also share a private policy network
when both services run on the same VPS:

```text
ai_service_vpn_policy 172.22.X.0/24
softether-edge        172.22.X.2
softether-cascade     172.22.X.3
cascade-router        172.23.0.X
```

`X` is generated from the numeric part of the VPS alias as `255 - N`
(`vps4` -> `172.22.251.0/24`, `vps5` -> `172.22.250.0/24`). The plan is
generated from operator state into `operator/networks.csv` by
`tools/network/generate_vpn_network_plan.ps1` or `.sh`, then synced to the
active orchestrator. Aliases that are not `vpsN` require explicit rows in
`operator/networks.override.csv`.

This network is the internal L3 dataplane handoff for selected fallback routing.
It does not enable NAT, forwarding, or non-local egress by itself; routes are
added later only from active policy profiles and accepted proposals.

To enable it, add or update a `state.csv` service row with explicit aliases:

```csv
service,vpn_cascade,vpn_cascades,vps5+vps4+vps3,,,present
```

The current lab cascade fabric uses directed links declared in a shared operator
secret. Each cascade node publishes separate cascade-only host ports and does
not occupy public edge `443/tcp`:

| Host port | Container port | Purpose |
|---|---|---|
| `8443/tcp` | `443/tcp` | primary cascade HTTPS-like transport listener |
| `8992/tcp` | `992/tcp` | fallback/test SoftEther cascade SSL listener |
| `8555/tcp` | `5555/tcp` | management, restricted by firewall |

The operator-local cascade secret is ignored by git:

```text
operator/softether/cascade/secrets/lab-cascade.json
```

It contains shared hub/user/password values plus directed links used by
`vpncmd`:

```json
{
  "version": 1,
  "state": "active",
  "hub_name": "CascadeLab",
  "hub_password": "<store outside chat>",
  "cascade_user": "cascade-peer",
  "cascade_user_password": "<store outside chat>",
  "server_password": "<store outside chat>",
  "links": [
    {
      "state": "active",
      "connection_name": "vps5-to-vps4",
      "ingress_alias": "vps5",
      "ingress_host": "vps5.mine-craft.su",
      "egress_alias": "vps4",
      "egress_host": "vps4.mine-craft.su",
      "egress_port": 8443
    },
    {
      "state": "active",
      "connection_name": "vps4-to-vps3",
      "ingress_alias": "vps4",
      "ingress_host": "vps4.mine-craft.su",
      "egress_alias": "vps3",
      "egress_host": "vps3.mine-craft.su",
      "egress_port": 8443
    }
  ]
}
```

The cascade secret passwords must be `vpncmd`-safe strings matching
`[A-Za-z0-9_-]`, normally 32-48 characters. Avoid base64 passwords containing
`/`, `+`, or `=` because `vpncmd` command parsing can treat slash-prefixed text
as command switches.

The operator seed config is per node and optional for the very first clean
bootstrap:

```text
operator/softether/cascade/<alias>/vpn_server.config
```

If the seed exists, normal `vpn_cascade present` copies it only when the remote
cascade config is missing. If the seed does not exist and the remote config is
also missing, rollout starts a clean SoftEther cascade container with an empty
`softether_data` directory, removes the default `DEFAULT` virtual hub, then
configures only the lab hub, user, and active cascade links using the JSON above.
`hub_password` is used when creating `CascadeLab`; server-admin automation still
uses `server_password`. The role sets the hub `NoEnum` option so `CascadeLab` is
not enumerated to anonymous users. Password-bearing tasks are `no_log`.

After first start, the remote
`/opt/ai-service-platform/vpn_cascade/softether_data/vpn_server.config` is
mutable runtime state. `vpn_cascade` does not publish HAProxy routes, does not
change host routing, and does not apply selective fallback routing. Controlled
routing must come later from approved policy, not directly from cascade rollout.

### Container Connectivity Model

The VPN stack uses separate Docker networks for separate traffic planes:

- `ai_service_edge` - public ingress plane. `edge-haproxy` reaches
  `softether-edge` here.
- `ai_service_vpn_policy` - internal per-node policy dataplane. `softether-edge`
  and `policy-gateway` share this network for selected traffic handoff.
  `policy-gateway` has a first-class IP from `operator/networks.csv`
  (`policy_gateway_ip`, normally `.4` in the policy subnet).
- `ai_service_cascade` - cascade service network. `softether-cascade` keeps its
  own transport runtime separate from user VPN ingress.

Do not use Docker host networking for `vpn_edge` or `vpn_cascade`. It would make
ports and firewall boundaries harder to audit and rollback.

Do not put HAProxy between `vpn_edge` and `vpn_cascade` for egress traffic.
HAProxy owns public TCP ingress and management allowlisting; after a user enters
the VPN, selected egress is IP/dataplane routing, not HAProxy frontend routing.

Do not attach `edge-haproxy` to `ai_service_vpn_policy`. Keeping HAProxy out of
the policy dataplane prevents cascade/routing experiments from becoming a public
edge blast-radius problem.

Selective fallback is L3 routed, not proxied. HAProxy and nginx do not carry VPN
fallback dataplane traffic; they remain public edge/web infrastructure. Production
SoftEther `vpn_edge` and `vpn_cascade` stay transport services; Linux route/NAT
policy belongs to the separate `policy-gateway` container.

Ordinary VPN traffic does not enter the cascade policy path:

```text
VPN client
  -> softether-edge SecureNAT
  -> default route
  -> ingress VPS internet
```

Selected fallback traffic is chosen only by exact `/32` routes inside
`softether-edge`:

```text
VPN client
  -> softether-edge selected /32 route
  -> ai_service_vpn_policy 172.22.X.0/24
  -> ingress policy-gateway route/SNAT
  -> ingress softether-cascade
  -> tap_vpnpolicy / CascadeLab transport
  -> egress softether-cascade final NAT
  -> target
```

Only approved targets from operator policy may be routed this way. Default VPN
traffic continues to use ingress-local egress during the canary stage. After the
canary is green, the default route inside `softether-edge` may be moved to
`policy-gateway`; then `policy-gateway` becomes the ordinary VPN egress router
and only selected exact target routes continue through cascade.

Ownership boundaries are strict:

- `softether-edge`: VPN ingress, SecureNAT, selected exact `/32` routes, and
  optionally the default route to `policy-gateway` after canary success.
- `softether-cascade`: stock SoftEther hub/cascade service plus runtime exact
  selected routes/NAT for the hybrid canary path.
- `policy-gateway`: ingress Linux route/NAT policy, counters, verification,
  rollback, and future ordinary default egress.
- `vpn_server.config`: SoftEther state only; selective fallback routes/NAT are
  never written there.

The gateway image is intentionally small. The tracked build recipe is
`infra/docker/policy-gateway/Dockerfile` and includes only `sh`, `iproute2`,
`iptables`, and `nftables` for v1. Normal rollout treats this image as an
internal artifact of the `policy_gateway` role: the operator uploads the service
bundle, and the active orchestration node builds the image once, saves it to an
archive, loads that same archive onto every target policy gateway VPS, verifies
matching Docker image IDs, and renders compose with the generated tag.

```powershell
.\tools\services\service_remote.ps1 policy_gateway apply `
  -Limit vps5+vps4+vps3 `
  -DetachedRemoteJob
```

This avoids requiring Docker Desktop on the operator workstation. The legacy
`tools/services/publish_policy_router_image.ps1` helper remains only as a manual
escape hatch for local build/save/load. A future GHCR path should replace only
the image delivery step by passing a digest reference through
`-PolicyRouterImageRef`.

### Cascade Roles Before Routing

SoftEther cascade direction is the direction of TCP connection initiation, not a
complete traffic policy. A cascade link object exists only on the initiator side;
the receiver sees it as an incoming hub session from `cascade-peer`.

Before adding L3 routing or NAT, model every cascade link explicitly:

- `initiator_alias` - the node that creates the SoftEther Cascade Connection;
- `receiver_alias` - the node that listens for that connection;
- `ingress_alias` - where selected client or service traffic enters the policy;
- `ingress_host` - the public endpoint used by peers and firewall allow rules
  when the ingress side is also the active local orchestrator;
- `egress_alias` - where selected traffic is allowed to leave;
- `egress_host` - the receiver endpoint used by the SoftEther Cascade
  Connection;
- `egress_port` - the receiver host port, currently `8443` for HTTPS-like
  transport.

Each cascade link carries a `state` field:

- `active` or missing - real lab link included in rollout;
- `probe` - a read-only candidate used by egress probes and reports only;
- `disabled` - ignored by probe tooling.

Before making `vps3` a cascade receiver, promote the active orchestration role
away from `vps3` to the standby `vps5`. This keeps control-plane access separate
from the node being modified as cascade egress.

#### Explicit Egress Profiles

The default egress behavior remains local to the ingress node. Selected traffic
must leave through the same VPS where it entered unless an explicit egress
profile says otherwise.

Non-RU to non-RU routing is allowed only as an operator-managed named profile,
not as automatic any-to-any mesh behavior. For example, a profile may describe a
Latvia ingress with an Uzbekistan egress when that route is intentionally needed
for a lab, geo, provider, or troubleshooting scenario.

Every egress profile must record:

- `ingress_alias` - where selected traffic enters the policy;
- `egress_alias` - where selected traffic exits;
- `transport_port` - the receiver host port used by the cascade transport;
- `reason` - why this non-local egress is enabled;
- `state` - planned, active, paused, or retired;
- `rollback` - how to return traffic to local/default egress.

Do not enable an any-to-any cascade mesh. Each profile must be individually
approved, observable, and reversible.

#### Data Storage Boundary

V1 egress profiles are operator-managed config, not database state. Store the
intended policy in operator-controlled files and keep rollout explicit. This is
intended for a small number of manually reviewed fallback profiles, not for a
large dynamic rule database.

Do not introduce a database only to store the first static profiles. A database
becomes useful when probe history, route decisions, health scores, operator
overrides, and audit events need queryable history.

AI assistance may be used at this stage only as an advisory analysis layer. It
may summarize probe results, compare candidate egress quality, explain why a
profile is unhealthy, and propose a route decision for operator review. It must
not directly apply routes, NAT, firewall, or SoftEther changes.

Design probes and decision output so they can later move into SQLite or Postgres
without changing the policy concepts:

- profile definitions remain declarative operator intent;
- probe samples are append-only observations;
- selected egress decisions record inputs, chosen alias, reason, and expiry;
- manual overrides record operator, reason, start, end, and rollback.
- AI recommendations record model/input version, evidence, confidence, and the
  operator decision that accepted or rejected the recommendation.

Future database storage should be additive. Keep operator intent in reviewed
files until there is a real need for multi-operator editing or dynamic policy
generation. Move these records to a database first:

- `probe_runs` - one run per probe batch, with started/finished timestamps and
  source node;
- `probe_samples` - per target/egress metrics such as DNS result, TCP latency,
  HTTP status, external IP, country, and error;
- `egress_decisions` - profile, candidate set, selected alias, score inputs,
  expiry, and fail-open/fail-closed outcome;
- `operator_overrides` - manual decision, reason, owner, expiry, and rollback;
- `ai_recommendations` - prompt/input hash, model, evidence summary,
  confidence, recommendation, and final operator disposition.

The first database can be local SQLite for operator-side history. Postgres is
reserved for a later shared controller or multi-node policy service.

#### Probe-Only Policy Registry

The first executable policy layer is probe-only. Operator intent lives in:

```text
operator/egress_policy/profiles.json
```

This file is local operator state, not a runtime route table. It may be empty
when no active fallback policy is currently needed. New v1 profiles use
`behavior: "fallback_on_ingress_egress_failure"`: probe ingress-local egress
first and consider cascade only when the ingress-local path fails or degrades.
Targets, domains, IP addresses, protocols, ports, ingress aliases, and fallback
egress aliases live in this operator file, not in code. Cascade link names are
derived from `lab-cascade.json`.

The canonical v1 profile shape is:

```json
{
  "name": "example_service_fallback",
  "state": "probe",
  "behavior": "fallback_on_ingress_egress_failure",
  "candidate_ingress_aliases": ["vps5"],
  "candidate_fallback_egress_aliases": ["vps4"],
  "targets": [
    { "type": "domain", "value": "example.org", "protocol": "https", "port": 443, "path": "/" },
    { "type": "domain", "value": "example.org", "protocol": "tcp", "port": 443, "path": "/" },
    { "type": "domain", "value": "example.org", "protocol": "udp", "port": 53, "path": "/" },
    { "type": "ip", "value": "192.0.2.10", "protocol": "icmp", "port": 0, "path": "/" }
  ],
  "reason": "Why this fallback candidate should be checked.",
  "rollback": "How to disable this probe-only intent."
}
```

Do not use old `desired_region_behavior`, `candidate_egress_aliases`, or
`candidate_fallback_links` fields in new policy files. The v1 contract is
explicit: `behavior`, `candidate_ingress_aliases`, and
`candidate_fallback_egress_aliases`. If strict country behavior is ever needed,
use a separate future behavior such as
`require_non_ru_egress` instead of mixing it with fallback routing.

A tracked, secret-free example is available at:

```text
docs/examples/egress_policy.profiles.example.json
```

Copy or adapt that example into `operator/egress_policy/profiles.json` on the
operator machine. Do not treat the example as active policy.

`operator/egress_policy/profiles.json` is synced to the active orchestrator with
the rest of operator intent. Probe history archives and proposal inbox files stay
operator-local and are not runtime input.

Create or replace a probe-only fallback profile without hand-editing JSON:

```powershell
.\tools\egress_policy\set_egress_policy_profile.ps1 `
  -Name example_service_fallback `
  -TargetValue example.org,www.example.org `
  -Protocol https `
  -IngressAlias vps5 `
  -FallbackEgressAlias vps4 `
  -Reason "Local ingress path is unreliable for this operator-defined target." `
  -Replace
```

The command only edits `operator/egress_policy/profiles.json`. It does not probe
remote nodes and does not change routes, NAT, firewall, HAProxy, SoftEther, or
Docker state.

Selective fallback apply assumes the post-SecureNAT edge source is `172.20.0.2`
by default. If an edge deployment uses a different source, pass `-EdgeSourceIp`
to `apply_selective_fallback_routes.ps1`.

Targets stay explicit. The tools do not automatically add wildcard subdomains,
redirect chains, or CDN networks. If an HTTP/HTTPS probe follows a redirect to a
host that is not listed in the same profile, reports and proposals show
`related_target_missing`; the operator then adds that host explicitly if it
should share the same fallback intent.

AI can contribute proposals as advisory evidence:

```powershell
.\tools\egress_policy\new_egress_ai_advisory_proposal.ps1 `
  -TargetValue example.org `
  -Protocol tcp `
  -Port 443 `
  -Summary "AI suggests reviewing this target based on observed failures."
```

AI advisory proposals are always `suggested` / `Требует решения`; they do not
modify active profiles or runtime routes.

When an accepted proposal is applied, `softether-edge` installs an exact
resolved-target `/32` route toward the local cascade IP. The ingress
`policy-router` installs a supporting return route to the edge source IP, an
exact route through `tap_vpnpolicy`, and a scoped SNAT rule from the edge source
IP to the ingress cascade router IP. The egress `policy-router` keeps a scoped
final MASQUERADE/SNAT rule for the same target IP and protocol/port (or ICMP).
This avoids broad "all HTTPS" routing and keeps the return path predictable.
Applied target IPs and NAT comments are persisted as schema v2 state under
`operator/egress_policy/applied_routes/` so rollback uses the exact state that
was changed instead of resolving the domain again.

Selective fallback apply is self-auditing. By default `apply` verifies the
runtime state it just installed: edge exact `/32` route, ingress `policy-router`
exact route through `tap_vpnpolicy`, ingress return route to the edge source IP,
ingress SNAT rule and counters, egress `policy-router` return route, egress NAT
rule and counters, and a network-namespace probe from `softether-edge` for
protocols that can be checked generically. Use `verify` to repeat that check later, and
`rollback` to remove only persisted exact route/NAT state:

```powershell
.\tools\egress_policy\apply_selective_fallback_routes.ps1 -Action plan -Id <proposal-id>
.\tools\egress_policy\apply_selective_fallback_routes.ps1 -Action apply -Id <proposal-id>
.\tools\egress_policy\apply_selective_fallback_routes.ps1 -Action verify -Id <proposal-id>
.\tools\egress_policy\apply_selective_fallback_routes.ps1 -Action rollback -Id <proposal-id>
.\tools\egress_policy\apply_selective_fallback_routes.ps1 -Action cleanup -Id <proposal-id>
```

`-SkipVerify` is available only as an operator escape hatch; normal canaries
should let `apply` verify before they are considered accepted at runtime.
`rollback` uses persisted schema v2 state. `cleanup` is a failed-canary escape
path: it recomputes the selected proposal's current exact target IPs and removes
matching edge routes plus `policy-router` route/NAT comments without touching
SoftEther config. If a failed canary used a DNS IP that is no longer returned,
pass it explicitly, for example
`-Action cleanup -Id <proposal-id> -TargetIp 212.11.151.56`.

Run a dry plan without touching remote nodes:

```powershell
.\tools\egress_policy\probe_egress_policy.ps1 -DryRun
```

Run actual probes over SSH from each selected VPS:

```powershell
.\tools\egress_policy\probe_egress_policy.ps1
```

If the shell resolves `ssh` to a wrapper instead of OpenSSH, pass the executable
explicitly:

```powershell
.\tools\egress_policy\probe_egress_policy.ps1 -SshPath <path-to-ssh>
```

Run ingress-local probes first, then cascade fallback probes only when the
ingress-local path fails or degrades:

```powershell
.\tools\egress_policy\probe_egress_policy.ps1 -PreferCascade
```

Run direct probes plus cascade-aware readiness probes when a full audit needs
both ingress-local and cascade evidence:

```powershell
.\tools\egress_policy\probe_egress_policy.ps1 -IncludeCascade
```

Run only explicit cascade routes:

```powershell
.\tools\egress_policy\probe_egress_policy.ps1 -CascadeOnly
```

Check the future selective fallback dataplane shape without switching users:

```powershell
.\tools\egress_policy\check_selective_fallback_readiness.ps1
```

This read-only check uses the same operator policy and cascade links. For each
selected profile it verifies that `softether-edge` and `softether-cascade` are
attached to `ai_service_vpn_policy` on the ingress VPS, that `policy-router`
exists and shares the `softether-cascade` network namespace, that
`tap_vpnpolicy` exists with the expected router IP, that ingress and egress
`policy-router` containers can read NAT POSTROUTING rules and counters, that the
configured cascade transport is reachable, and that the final egress VPS can
probe the target. It does not create routes, NAT, firewall rules, HAProxy routes,
Docker networks, or SoftEther config.

When there are no active egress policy profiles, probe commands intentionally
do nothing. To verify the cascade transport itself, use the dedicated read-only
health check instead:

```powershell
.\tools\services\check_vpn_cascade_links.ps1
.\tools\services\check_vpn_cascade_links.ps1 -Json
```

This command reads `operator/softether/cascade/secrets/lab-cascade.json`,
checks each directed link with SSH, verifies TCP reachability to the receiver
port, and runs read-only `CascadeStatusGet` inside `softether-cascade`. It uses
non-interactive `vpncmd` with `/IN`, `timeout`, and closed SSH stdin. Do not use
manual `vpncmd` commands that wait for password input.

Probe results are written as JSONL under:

```text
operator/egress_policy/history/
```

Archive and clear old active probe history:

```powershell
.\tools\egress_policy\clear_egress_probe_history.ps1
```

Render the latest probe history as an operator-readable table:

```powershell
.\tools\egress_policy\report_egress_probes.ps1
```

Use `-HistoryFile <path>` to inspect a specific probe run and `-Json` when
another tool should consume the report output. If active history is empty, the
report prints a friendly empty-state message; it does not inspect archive files
unless a specific archived `-HistoryFile` is provided.

Generate operator-visible proposals from probe history:

```powershell
.\tools\egress_policy\suggest_egress_policy.ps1 -DryRun
.\tools\egress_policy\suggest_egress_policy.ps1
```

The proposal inbox is exception-only. Successful green observations such as
`good_ingress_local` for a target that is already covered by policy are kept in
probe history, but they do not require operator approval and do not create a
proposal. A proposal is created only when the operator needs to decide something:
ingress-local failure with fallback available, fallback unavailable, probe error,
unstable retries, unknown target, or an inconclusive route.

Deterministic fallback proposals are auto-accepted when the target is already in
`profiles.json`, the ingress-local probe fails or degrades after all attempts,
and exactly one configured cascade fallback link succeeds. Auto-accept updates
only the proposal JSON status to `accepted` / `Принято`; it still does not apply
selective fallback routing or change runtime state.

Review the proposal inbox:

```powershell
.\tools\egress_policy\report_egress_proposals.ps1
.\tools\egress_policy\report_egress_proposals.ps1 -Id <proposal-id> -Detail
```

For a human review loop with Russian status text and simple action keys:

```powershell
.\tools\egress_policy\review_egress_proposals.ps1
```

The interactive actions are `A` accept, `R` reject, `I` ignore, `D` details,
`S` skip, and `Q` quit. These actions update only the proposal JSON decision
state. They do not apply routing, NAT, firewall, HAProxy, SoftEther, or Docker
changes.

Accept or reject a proposal decision without changing runtime policy:

```powershell
.\tools\egress_policy\set_egress_proposal_status.ps1 -Id <proposal-id> -Status accepted -Reason "approved for profile drafting"
.\tools\egress_policy\set_egress_proposal_status.ps1 -Id <proposal-id> -Status rejected -Reason "not needed"
```

Proposals are stored under `operator/egress_policy/proposals/` and are not
active policy. Suggested proposals need operator action; deterministic fallback
proposals may already be accepted automatically. In both cases, a separate
future apply-stage is required before any route is changed.

For larger target lists, keep grouped profiles. A profile describes one policy
intent, not one site. Add separate profiles only when the desired behavior,
rollback, candidate fallback links, or selective fallback routing meaning is
different.

Each record is an observation: profile, target, candidate alias, DNS result,
TCP/TLS/HTTP status, response timing, retry count, observed external IP,
observed country, and errors. Probe runs must not mutate routes, NAT, firewall,
HAProxy, SoftEther, Docker networks, or user traffic. Reports read existing
JSONL history only; they do not initiate remote probes and they are not automatic
selective fallback routing.

There are three probe levels:

- `direct` probe checks `alias -> target`;
- `cascade` readiness probe checks `ingress_alias -> egress_alias:port`,
  read-only SoftEther cascade status, then `egress_alias -> target`;
- controlled dataplane readiness probe checks the planned
  `vpn_edge -> ai_service_vpn_policy -> vpn_cascade -> cascade link -> target`
  shape before switching users.

The cascade-aware probe validates that a named cascade route is usable. It does
not prove that current VPN client traffic already uses that route.

Probe-only cascade candidates are useful for negative testing. A link with
`state: "probe"` is read by reports but must not be created by rollout. If
transport or SoftEther status is down, reports should show
`fallback_unavailable`; this is evidence for the operator, not a request to
create the link automatically.

HAProxy logs may produce `missing_ingress_route` proposals for public SNI/routes.
They must not directly produce egress-policy decisions because HAProxy cannot see
the encrypted VPN client's destination domains.

#### Isolated Transit Segments

Some fallback profiles may need a transit path through central nodes such as
`vps5` and `vps3` when the initial ingress VPS cannot reach the target egress
directly. The rollout model is a directed vector graph from `lab-cascade.json`:
v1 apply supports direct `ingress -> egress`, and the next step may distribute
selected exact `/32` routes across any explicit directed acyclic path.

For example:

```text
profile: non_ru_transit_fallback
path: ingress_non_ru -> vps5 -> vps3 -> egress_non_ru
mode: l3_routed
nat: egress_non_ru only
trigger: direct_path_unavailable
```

The `vps5 -> vps3` hop is allowed only as an explicit transit hop for the named
profile. It must not carry default/any-to-any traffic, and transit nodes must not
perform final NAT. NAT belongs only on the final `egress_alias`.

Every routed profile path must be acyclic. The same alias must not appear twice
in one path, and an active reverse profile for the same traffic class must not
be enabled at the same time.

Do not create simultaneous active reverse cascade links between the same hubs.
For example, `vps5 -> vps4` and `vps4 -> vps5` must not both be online as an L2
pair. If traffic later needs to enter on `vps4` and leave through `vps5`, add a
separate routed profile and policy instead of a second active L2-style link.
Rollout and probe tooling reject active/probe cascade graphs that contain a
directed cycle, including longer loops such as `vps5 -> vps4 -> vps3 -> vps5`.

Current cascade role policy:

- `vps5` is the ingress/fanout origin. It may initiate cascade links to
  `vps1`, `vps2`, and `vps4`.
- `vps3` is the central RU/control-side receiver. It may receive cascade links
  from `vps1`, `vps2`, and `vps4`.
- Other VPS nodes (`vps1`, `vps2`, `vps4`) are transit peers. They may receive
  from `vps5` and may initiate to `vps3` when a routed profile requires it.
- `vps5` and `vps3` must not be connected by the shared `vpn_cascade` fabric in
  either direction. If a fallback path needs that hop, use an isolated L3 transit
  segment bound to one named profile.

Allowed profile pairs:

```text
vps5 -> vps1
vps5 -> vps2
vps5 -> vps4
vps1 -> vps3
vps2 -> vps3
vps4 -> vps3
```

Forbidden profile pairs:

```text
vps5 -> vps3
vps3 -> vps5
```

These pairs are forbidden as shared cascade fabric links. They are not a ban on
future isolated L3 transit segments that are explicit, acyclic, profile-bound,
and kept separate from `CascadeLab`.

The allowed list is a catalog of possible routed profiles, not a command to make
all links active. Enable links only when the corresponding L3 route policy,
firewall rules, NAT behavior, and rollback are explicit.

Implementation order:

1. Make `vpn_cascade` link roles/profile the source of truth.
2. Keep seed snapshots as backup/debug artifacts, not as the primary workflow.
3. Add postchecks that verify initiator, receiver, host, port, and status.
4. Add L3 routing, forwarding, NAT, and rollback only after roles are explicit.

To intentionally replace an installed cascade node config with its operator
seed, use explicit reseed and a single alias:

```powershell
.\tools\services\service_remote.ps1 vpn_cascade reseed -Limit vps4
```

The reseed action requires
`operator/softether/cascade/<alias>/vpn_server.config`, backs up the live remote
config to the service backup directory, copies the seed, and restarts only the
`softether-cascade` container. Normal `apply` does not overwrite installed
SoftEther runtime config.
