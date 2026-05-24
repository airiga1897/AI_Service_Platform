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
service,aromaflow_frontend,frontend,vps1,,,present
service,aromaflow_backend,backend,vps1,,,present
service,ai_retail_frontend,frontend,vps2,,,absent
service,ai_retail_backend,backend,vps2,,,absent
service,vpn_cascade,vpn_cascades,,,,absent
```

`kind=platform_role` - ответственность узла: `orchestration`, `monitoring`, `backup`, `production`, `preprod`, `hot_standby`.

`kind=service` - устанавливаемый или останавливаемый компонент: `edge_haproxy`, `vpn_edge`, product frontend/backend services.

`ansible_group` задаёт inventory-группу. `active_aliases`, `candidate_aliases`, `old_aliases` разделяются через `+`.

## Lifecycle

`present` - роль/сервис должен быть активен на `active_aliases`.

`absent` - сервис должен быть остановлен/убран из runtime, но data/config сохраняются.

`purged` - сервисные данные можно удалить. Это destructive intent, но действие всё равно запускается только явной командой rollout.

Изменение `state.csv` само по себе ничего не запускает.

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

## Rollout

Обычный operator flow после bootstrap:

```powershell
.\tools\services\rollout_from_state.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv
```

Скрипт делает sync на active orchestration node, verify, затем применяет поддержанные service rows из `state.csv`.
