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
ai_service_vpn_policy 172.22.0.0/24
softether-edge        172.22.0.2
softether-cascade     172.22.0.3
```

This network is an internal dataplane handoff for future policy routing. It does
not enable NAT, forwarding, or non-local egress by itself.

To enable it, add or update a `state.csv` service row with explicit aliases:

```csv
service,vpn_cascade,vpn_cascades,vps5+vps4,,,present
```

The first lab link uses `vps5` as ingress-side endpoint and `vps4` as egress-side
peer. It publishes separate cascade-only host ports and does not occupy public
edge `443/tcp`:

| Host port | Container port | Purpose |
|---|---|---|
| `8443/tcp` | `443/tcp` | primary cascade HTTPS-like transport listener |
| `8992/tcp` | `992/tcp` | fallback/test SoftEther cascade SSL listener |
| `8555/tcp` | `5555/tcp` | management, restricted by firewall |

The operator-local link secret is ignored by git:

```text
operator/softether/cascade/secrets/lab-vps5-vps4.json
```

It contains only the lab link parameters and passwords used by `vpncmd`:

```json
{
  "hub_name": "CascadeLab",
  "hub_password": "<store outside chat>",
  "cascade_user": "cascade-peer",
  "cascade_user_password": "<store outside chat>",
  "server_password": "<store outside chat>",
  "connection_name": "vps5-to-vps4",
  "ingress_alias": "vps5",
  "egress_alias": "vps4",
  "egress_host": "vps4.mine-craft.su",
  "egress_port": 8443
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
configures only the lab hub, user, and cascade connection using the JSON above.
`hub_password` is used when creating `CascadeLab`; server-admin automation still
uses `server_password`. The role sets the hub `NoEnum` option so `CascadeLab` is
not enumerated to anonymous users. Password-bearing tasks are `no_log`.

After first start, the remote
`/opt/ai-service-platform/vpn_cascade/softether_data/vpn_server.config` is
mutable runtime state. `vpn_cascade` does not publish HAProxy routes, does not
change host routing, and does not enforce egress policy. Controlled routing must
come later from approved policy, not directly from cascade rollout.

### Container Connectivity Model

The VPN stack uses separate Docker networks for separate traffic planes:

- `ai_service_edge` - public ingress plane. `edge-haproxy` reaches
  `softether-edge` here.
- `ai_service_vpn_policy` - internal policy dataplane. `softether-edge` and
  `softether-cascade` share this network for future selected traffic handoff.
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

### Cascade Roles Before Routing

SoftEther cascade direction is the direction of TCP connection initiation, not a
complete traffic policy. A cascade link object exists only on the initiator side;
the receiver sees it as an incoming hub session from `cascade-peer`.

Before adding L3 routing or NAT, model every cascade link explicitly:

- `initiator_alias` - the node that creates the SoftEther Cascade Connection;
- `receiver_alias` - the node that listens for that connection;
- `ingress_alias` - where selected client or service traffic enters the policy;
- `egress_alias` - where selected traffic is allowed to leave;
- `egress_port` - the receiver host port, currently `8443` for HTTPS-like
  transport.

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
intended for a small number of manually reviewed profiles, such as
`youtube_non_ru` plus one or two lab/fallback profiles, not for a large dynamic
rule database.

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

This file is local operator state, not a runtime route table. The first profile
is `youtube_non_ru`, which measures `youtube.com` across current VPS candidates
before any future non-RU egress enforcement is approved.

Run a dry plan without touching remote nodes:

```powershell
.\tools\egress_policy\probe_egress_policy.ps1 -DryRun
```

Run actual probes over SSH from each selected VPS:

```powershell
.\tools\egress_policy\probe_egress_policy.ps1
```

Probe results are written as JSONL under:

```text
operator/egress_policy/history/
```

Each record is an observation: profile, target, candidate alias, DNS result,
TCP/TLS/HTTP status, observed external IP, observed country, and errors. Probe
runs must not mutate routes, NAT, firewall, HAProxy, SoftEther, Docker networks,
or user traffic.

#### Isolated Transit Segments

Some non-RU to non-RU fallback profiles may need a transit path through central
nodes such as `vps5` and `vps3` when the initial ingress VPS cannot reach the
target egress directly. That traffic must be modeled as a directed L3 routed
profile, not as another shared L2 cascade link.

For example:

```text
profile: non_ru_transit_fallback
path: ingress_non_ru -> vps5 -> vps3 -> egress_non_ru
mode: l3_routed
nat: egress_non_ru only
trigger: direct_path_unavailable
```

The `vps5 -> vps3` hop is allowed only as an isolated transit segment for the
named profile. It must not be bridged into the shared `CascadeLab` fabric, must
not carry unmarked/default traffic, and must not perform NAT. NAT belongs only
on the final `egress_alias`.

Every routed profile path must be acyclic. The same alias must not appear twice
in one path, and an active reverse profile for the same traffic class must not
be enabled at the same time.

Do not create simultaneous active reverse cascade links between the same hubs.
For example, `vps5 -> vps4` and `vps4 -> vps5` must not both be online as an L2
pair. If traffic later needs to enter on `vps4` and leave through `vps5`, add a
separate routed profile and policy instead of a second active L2-style link.

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
