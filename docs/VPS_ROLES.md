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
current_alias,endpoint,connection,root_password
```

Пример:

```csv
current_alias,endpoint,connection,root_password
vps1,vps01.example.com,ssh,
vps2,vps02.example.com,ssh,
vps3,vps03.example.com,ssh,
```

Смысл:

- `current_alias` - короткий ключ узла.
- `endpoint` - DNS/IP для подключения с operator machine.
- `connection` - `ssh` для operator-side bootstrap; `local` допустим только в generated inventory на orchestration node.
- `root_password` - временный пароль для fresh bootstrap; после успешного bootstrap runner очищает его локально.

В `nodes.csv` больше не пишутся `roles`, `vpn-edge`, `frontend`, `backend` и похожие capability-строки.

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
```

`kind=platform_role` - ответственность узла: `orchestration`, `monitoring`, `backup`, `production`, `preprod`, `hot_standby`.

`kind=service` - устанавливаемый или останавливаемый компонент: `edge_haproxy`, `vpn_edge`, product frontend/backend services.

`kind=edge_route` - HAProxy route внутри `edge_haproxy`. Route не запускает отдельный контейнер.

Service naming is semantic, not positional:

- `edge_haproxy` - edge proxy implemented with HAProxy.
- `vpn_edge` - SoftEther user VPN ingress behind the edge proxy.
- `vpn_ingress` - HAProxy route к `vpn_edge`.
- `minecraft` - HAProxy route для `mainsrv01.mine-craft.su`, Minecraft game и RCON.
- `vpn_cascade` - reserved future SoftEther cascade/site-to-site service.

`ansible_group` задаёт inventory-группу. `active_aliases`, `candidate_aliases`, `old_aliases` разделяются через `+`.

## Network Policy

`nodes.csv` остаётся адресной книгой VPS. В него не добавляются Docker subnet, container IP и другие runtime network поля.

`state.csv` описывает размещение и lifecycle ролей/сервисов, но не становится network registry.

В v1 фиксированные Docker IP используются только для edge/L4 platform services, где IP является частью контракта:

```text
ai_service_edge 172.20.0.0/24
softether-edge  172.20.0.2
edge-haproxy    172.20.0.3
```

Этот contract живёт в Ansible defaults edge-ролей. Если позже появятся много edge-сетей или per-node network overrides, для этого можно будет добавить отдельный `operator/networks.csv`.

Будущие `frontend`, `backend`, `postgres`, `redis`, `monitoring`, `semaphore` и product runtimes должны использовать Docker DNS names и network aliases. Static IP для них допускается только если сервис становится реальным L3/L4 contract endpoint.

## Lifecycle

`present` - роль/сервис должен быть активен на `active_aliases`.

`absent` - сервис должен быть остановлен/убран из runtime, но data/config сохраняются.

`purged` - сервисные данные можно удалить. Это destructive intent, но действие всё равно запускается только явной командой rollout.

Изменение `state.csv` само по себе ничего не запускает.

## Edge Routes

Route lifecycle живёт в `state.csv`, а route-настройки живут в operator-only файле:

```text
operator/haproxy/routes.yml
```

Example хранится в:

```text
infra/ansible/haproxy.routes.example.yml
```

`vpn_ingress` включает HAProxy routes `443/992/1194/5555` к `softether-edge`. VPN SNI задаётся точно, например `vpn-vps1.mine-craft.su`; `mainsrv01.mine-craft.su` не используется для VPN.

`minecraft` включает `25565/tcp` для Minecraft game и `25575/tcp` для RCON. В первом rollout target - `vps1`; `vps3` может стать candidate позже после проверки ресурсов.

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

`role` как legacy kind пока поддерживается скриптами, но новый документируемый вариант - `platform_role`.

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
