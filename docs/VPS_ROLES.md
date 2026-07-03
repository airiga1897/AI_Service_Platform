# Platform Nodes, Roles And Service State

Платформа использует два operator-файла:

- `nodes.csv` - адресная книга VPS.
- `state.csv` - источник истины для platform roles, services и lifecycle.

`vps1`, `vps2`, `vps3` - короткие operator aliases текущей схемы. Это не platform roles.

## nodes.csv

Real файл хранится вне git:

```text
operator/nodes.csv
```

Header:

```csv
current_alias,endpoint,expected_ip,connection,ssh_port,root_password
```

Пример:

```csv
current_alias,endpoint,expected_ip,connection,ssh_port,root_password
vps1,vps01.example.com,203.0.113.11,ssh,22,
vps2,vps02.example.com,203.0.113.12,ssh,22,
vps3,vps03.example.com,203.0.113.13,ssh,22,
```

Смысл:

- `current_alias` - короткий ключ узла.
- `endpoint` - DNS/IP для подключения с operator machine.
- `connection` - `ssh` для operator-side bootstrap; `local` допустим только в generated inventory на orchestration node.
- `root_password` - временный пароль для fresh bootstrap; после успешного bootstrap runner очищает его локально.

В `nodes.csv` больше не пишутся `roles`, `vpn-edge`, `frontend`, `backend` и похожие capability-строки.

### Bootstrap Access Mode

`root_password` is only for fresh bootstrap through `root@host`. When the field
is empty, wrappers treat the node as already bootstrapped and use
`operator/<alias>/admin_key` for admin-key re-bootstrap through
`useradmin@host`.

`platform_role,orchestration` `active_aliases` and `candidate_aliases` are
management-capable nodes. Other present aliases are managed nodes.
`bootstrap_all_from_windows.ps1` can converge both categories automatically:
first orchestration candidates, then the aggregate Ansible trust bundle and
trust mesh, then managed nodes.

An orchestration candidate may also run normal edge services. For example,
`vps5` can be a standby orchestration node for `vps6` and still be an active VPN
ingress node when `state.csv` contains the matching `edge_haproxy`, `vpn_edge`,
and `edge_route,vpn_ingress` rows.

### Current Verified Role Map

As of 2026-06-27, standby is manual. No role in this map implies automatic
failover, active-active routing, or automatic movement of service rows.

Provider placement is descriptive metadata, not an automation role:

- `adminvps`: `vps1`, `vps2`, `vps4`, `vps5`, `vps7`.
- `selectel`: `vps3`, `vps6`, `vps8`.

Runtime roles are managed separately through `state.csv`:

- `vps6` is the active orchestration node; `vps5` is its standby orchestration
  candidate and also an active VPN ingress node.
- `vps3` is the former cascade receiver and remains the primary candidate for
  future RU egress policy work. `vps7` is the manual duplicate/standby
  candidate for future L3 `vps3` HA work. Neither has active shared
  `CascadeLab` links while the L2 freeze is active.
- `vps2` is the active public/service edge target, including the current
  `minecraft` route. `vps1` and `vps4` are manual duplicate/standby candidates
  for `vps2`; both are active VPN ingress nodes.
- `vps8` is the staged services-active/Postgres primary node for the first
  active/standby DB pair. `vps4` is the services-standby/Postgres standby node.
  Their replication path is the isolated `softether_l3` tunnel
  `pg-vps8-vps4`, not the frozen shared L2 cascade.
- Public `vpn_cascade` SNI/backends and local `vpn_cascade` runtime are both
  absent while the SoftEther L2 freeze is active. `cascade-vps8` and
  `cascade-vps4` may be used only as management SNI for the new `softether_l3`
  containers on `5555`.
- Every active VPS alias from `vps1` through `vps8` has the full VPN ingress
  stack in `state.csv`: `edge_haproxy`, `vpn_edge`, and
  `edge_route,vpn_ingress`.
- Every manual standby candidate must keep that VPN ingress stack healthy before
  it is considered promotable.
- Current verified cascade policy is no active shared `CascadeLab` links. The
  shared SoftEther L2 cascade fabric is frozen because alternate receiver links
  caused a likely broadcast storm. Treat `vps7` HA as future L3 policy routing
  work, not L2 mesh expansion.

## state.csv

Real файл хранится вне git:

```text
operator/state.csv
```

Header:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
```

Пример:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
platform_role,orchestration,orchestration,vps3,,,present
platform_role,monitoring,monitoring,vps3,,,present
platform_role,backup,backup,vps2,,,present
service,edge_haproxy,edge_haproxy,vps1,,,present
service,vpn_edge,vpn_edges,vps1+vps2+vps3,,,present
edge_route,vpn_ingress,vpn_ingress,vps1,,,present
edge_route,minecraft,minecraft_edge,vps1,,,absent
service,aromaflow_frontend,frontend,vps1,,,present
service,aromaflow_backend,backend,vps1,,,present
service,ai_retail_frontend,frontend,vps2,,,absent
service,ai_retail_backend,backend,vps2,,,absent
service,vpn_cascade,vpn_cascades,,,,absent
service,edge_candidate_collector,edge_candidate_collectors,vps1+vps2+vps3+vps4+vps5,,,present
```

`kind=platform_role` - ответственность узла: `orchestration`, `monitoring`, `backup`, `production`, `preprod`, `hot_standby`.

`kind=service` - устанавливаемый или останавливаемый компонент: `edge_haproxy`, `vpn_edge`, product frontend/backend services.

`kind=edge_route` - HAProxy route внутри `edge_haproxy`. Route не запускает отдельный контейнер.

Service naming is semantic, not positional:

- `postgres_runtime` - infrastructure PostgreSQL runtime. `active_aliases`
  means current primary, and `candidate_aliases` means manual standby
  candidates.
- `redis_runtime` - infrastructure Redis runtime for cache, broker, or result
  backend use. `active_aliases` means current active Redis placement, and
  `candidate_aliases` means prepared standby candidates.
- `flower_runtime` - infrastructure/control runtime for Celery observability.
  It may run without any public HAProxy route.
- `flower_mgmt` - optional HAProxy management route for Flower. Runtime
  placement and public exposure are intentionally separate: this route is
  absent by default.
- Project worker services, for example `ai_retail_worker`, run Celery workers
  from project images. They consume infrastructure endpoints but are not shared
  infrastructure themselves.
- Project scheduler services, for example `ai_retail_scheduler`, run Celery
  beat or other singleton schedulers from project images. They normally have
  exactly one active alias.
- `edge_haproxy` - edge proxy implemented with HAProxy.
- `vpn_edge` - SoftEther user VPN ingress behind the edge proxy.
- `vpn_ingress` - HAProxy route к `vpn_edge`.
- `minecraft` - HAProxy route для `mainsrv01.mine-craft.su`, Minecraft game и RCON.
- `vpn_cascade` - SoftEther cascade/site-to-site lab transport service. It is
  separate from `vpn_edge`, uses its own runtime data, and does not create an
  HAProxy public route by itself. Public `cascade-vpsN` SNI is controlled only
  by `edge_route,vpn_cascade`.
- `edge_candidate_collector` - per-VPS timer service that gathers sanitized
  HAProxy/policy/cascade candidate facts and writes local JSONL evidence. It
  does not apply routes, NAT, firewall, HAProxy, Docker, or SoftEther changes.

Every active, non-retired VPS in `nodes.csv` is expected to have the full VPN
ingress stack in `state.csv`: `service,edge_haproxy`,
`service,vpn_edge`, and `edge_route,vpn_ingress`. Exceptions must be explicit
and temporary, for example a newly bootstrapped node that is waiting for public
TCP provider forwarding checks.

`edge_candidate_collector` lifecycle is controlled only by `state.csv`. Its
output is pulled into the operator proposal inbox with:

```powershell
.\tools\egress_policy\egress_policy_remote.ps1 `
  -Command collect `
  -Args "-AllAliases"

.\tools\egress_policy\egress_policy_remote.ps1 `
  -Command collect `
  -Args "-IngressAlias vps4"
```

Generated proposals remain `suggested` until the operator accepts or rejects
them through the normal egress proposal review tools.

`ansible_group` задаёт inventory-группу. `active_aliases`, `candidate_aliases`, `old_aliases` разделяются через `+`.

### Runtime Placement Contract

Runtime placement is role-driven by `state.csv`. `active_aliases` and
`candidate_aliases` describe the current deployment, not hardcoded architecture.
Documentation may mention concrete VPS aliases as current status or examples,
but roles and automation must not bake in `vpsN` placement.

Infrastructure runtimes provide shared endpoints and lifecycle:

- `postgres_runtime` owns persistent database placement and manual standby.
- `redis_runtime` owns cache, broker, and result-backend placement plus manual
  standby.
- `flower_runtime` owns Celery observability/control placement.

Application runtimes consume infrastructure endpoints:

- web/API services serve project traffic;
- worker services run project-specific Celery workers from project images;
- scheduler services run project-specific singleton beat/cron processes.

Public exposure is controlled only by `edge_route` rows. A `service` row may
run a runtime internally without publishing it. For example,
`service,flower_runtime,...,present` does not publish Flower; only
`edge_route,flower_mgmt,...,present` may expose it through HAProxy.

Flower is VPN-only/internal by default. If temporary publication is needed, the
route uses `https://flower-vpsN.mine-craft.su` on public `443`, protected by
HAProxy management allowlists and application/basic auth, and forwards to the
internal Flower backend on `8080`.

## Network Policy

`nodes.csv` остаётся адресной книгой VPS. В него не добавляются Docker subnet, container IP и другие runtime network поля.

`state.csv` описывает размещение и lifecycle ролей/сервисов, но не становится network registry.

В v1 фиксированные Docker IP используются только для edge/L4 platform services, где IP является частью контракта:

```text
ai_service_edge 172.20.0.0/24
softether-edge  172.20.0.2
edge-haproxy    172.20.0.3

ai_service_cascade 172.21.0.0/24
softether-cascade  172.21.0.2

ai_service_vpn_policy 172.22.X.0/24
softether-edge        172.22.X.2
softether-cascade     172.22.X.3
cascade-router        172.23.0.X
```

`ai_service_vpn_policy` генерируется в `operator/networks.csv`. Для обычных
алиасов `vpsN` используется `X = 255 - N`: например, `vps1` получает
`172.22.254.0/24`, а `vps5` получает `172.22.250.0/24`. Алиасы не вида `vpsN`
должны быть явно описаны в `operator/networks.override.csv`.

Будущие `frontend`, `backend`, `postgres`, `redis`, `monitoring`, `semaphore` и product runtimes должны использовать Docker DNS names и network aliases. Static IP для них допускается только если сервис становится реальным L3/L4 contract endpoint.

## Lifecycle

`present` - роль/сервис должен быть активен на `active_aliases`.

`absent` - сервис должен быть остановлен/убран из runtime, но data/config сохраняются.

`purged` - сервисные данные можно удалить. Это destructive intent, но действие всё равно запускается только явной командой rollout.

Изменение `state.csv` само по себе ничего не запускает.

## Edge Routes

Route lifecycle живёт в `state.csv`, а route defaults/overrides живут в operator-only файле:

```text
operator/haproxy/routes.yml
```

Example хранится в:

```text
infra/ansible/haproxy.routes.example.yml
```

`vpn_ingress` включает HAProxy routes `443/992/5555` к `softether-edge`. Базовый VPN SNI задаётся точно, например `vpn-vps1.mine-craft.su`; дополнительные SNI для конкретного alias могут приходить из route-specific overrides, например `minecraft.per_alias.<alias>.vpn_sni`.

Перед rollout runner нормализует derived VPN route config: если active
`edge_route,vpn_ingress` содержит новый alias, отсутствующий в
`operator/haproxy/routes.yml`, он добавляет default SNI
`vpn-<alias>.mine-craft.su`. Existing custom SNI не перезаписывается.

`minecraft` включает `25565/tcp` для Minecraft game и `25575/tcp` для RCON. Alias включается только через `state.csv`, например:

```csv
edge_route,minecraft,minecraft_edge,vps4,,,present
```

Если `operator/haproxy/routes.yml` содержит `minecraft.defaults.backends`, alias может наследовать Minecraft upstream без `minecraft.per_alias.<alias>`. Текущий managed primary backend - `mainserv01.netcraze.pro`; отдельный `fallback` опционален и задаётся только когда есть реальный резервный backend. `per_alias` нужен только для override конкретного узла. Текущий managed target - `vps4`; `vps1` не должен держать active Minecraft route.

`minecraft.per_alias.<alias>.vpn_sni` добавляет дополнительные VPN SNI names для того же alias, если на нём также включён `edge_route,vpn_ingress`. Это не включает `443/tcp` само по себе; lifecycle VPN route всё равно живёт в `state.csv`. Пример для `vps4`:

```yaml
minecraft:
  per_alias:
    vps4:
      vpn_sni:
        - mainsrv01.mine-craft.su
```

Provider-NAT VPS require a separate public TCP readiness check. SSH reachability
through `nodes.csv` is not enough: VPN ingress is healthy only when public TCP
`443`, `992`, and `5555` reach the VPS and HAProxy counters move. A SoftEther
client NAT Traversal warning means the session bypassed the intended TCP/SNI
path and must not be accepted as production ingress readiness.

## Inventory Generation

`create_inventory.sh` берёт:

- endpoints и connection из `nodes.csv`;
- группы и назначения из `state.csv`.

Для каждого `ansible_group` создаются группы:

```text
<group>
candidate_<group>
old_<group>
```

Пример:

```bash
sudo bash tools/bootstrap/create_inventory.sh \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv
```

## Orchestration

Active orchestration node выбирается только из `state.csv`:

```csv
platform_role,orchestration,orchestration,vps3,,,present
```

Если нужно перенести управление на новый VPS, меняется `active_aliases` у этой строки. Скрипты не должны hardcode-ить `vps3`.

При первичном bootstrap роль `orchestration` должна быть `present`. `absent` означает, что active control node отсутствует, и automation не сможет выбрать, какой VPS готовить первым:

```csv
platform_role,orchestration,orchestration,vps3,,,present
```

Миграция orchestration на новый VPS делается через `candidate_aliases`, без потери active control node:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
platform_role,orchestration,orchestration,vps3,vps4,,present
```

После проверки и переноса active node меняется так:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
platform_role,orchestration,orchestration,vps4,,vps3,present
```

`role` как legacy kind пока поддерживается скриптами, но runner нормализует его
в `platform_role` перед rollout. Новый документируемый вариант -
`platform_role`.

## Rollout

Обычный operator flow после bootstrap:

```powershell
.\tools\services\rollout_from_state.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv
```

WSL/Linux equivalent:

```bash
bash tools/services/rollout_from_state.sh \
  --nodes-file ./operator/nodes.csv \
  --state-file ./operator/state.csv
```

Скрипт делает sync на active orchestration node, verify, затем применяет поддержанные service rows из `state.csv`.
