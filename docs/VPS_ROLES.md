# Platform Nodes, Roles And Service State

Платформа разделяет две вещи:

- `nodes.csv` — какие VPS существуют и как к ним подключаться.
- `state.csv` — какие роли и сервисы должны быть активны на этих VPS.

`vps1`, `vps2`, `vps3` — короткие operator aliases текущей схемы. Это не platform roles.

## Operator Files

Real operator files хранятся вне git:

```text
operator/nodes.csv
operator/state.csv
```

На control/orchestration node они синхронизируются как:

```text
/opt/ai-service-platform/operator/nodes.csv
/opt/ai-service-platform/operator/state.csv
```

Безопасные шаблоны:

```text
infra/ansible/nodes.example.csv
infra/ansible/state.example.csv
```

## nodes.csv

Header:

```csv
current_alias,endpoint,connection,ansible_group,roles,root_password
```

Смысл:

- `current_alias` — короткий ключ узла, например `vps1`.
- `endpoint` — DNS/IP для operator bootstrap; real value не коммитится.
- `connection` — `ssh` для bootstrap с операторской машины, `local` только на control node.
- `ansible_group` — базовая группа узла для старых/fallback сценариев.
- `roles` — базовые capabilities узла, например `production+vpn-edge`.
- `root_password` — временный пароль только для первого bootstrap; runner очищает его после успеха.

`root_password` не копируется на control node: sync всегда отправляет sanitized CSV.

## state.csv

Header:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
```

Пример:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
role,production,prod,vps1,,,present
role,preprod,backup,vps2,,,present
role,backup,backup,vps2,,,present
role,orchestration,management,vps3,,,present
service,vpn,vpn_edges,vps1+vps2+vps3,,,present
```

Смысл:

- `kind=role` — назначение узла, например `orchestration`.
- `kind=service` — устанавливаемый platform service, например `vpn`.
- `active_aliases` — где роль/сервис сейчас должны быть активны.
- `candidate_aliases` — узлы-кандидаты для миграции или подготовки.
- `old_aliases` — прежние узлы на rollback window.
- `state` — желаемое состояние: `present`, `absent`, `purged`.

Внутри alias-полей несколько значений разделяются через `+`.

## state Values

`present` означает: роль или сервис должны существовать.

Для VPN:

```csv
service,vpn,vpn_edges,vps1+vps2+vps3,,,present
```

означает: VPN должен быть развернут на `vps1`, `vps2`, `vps3`.

`absent` означает: сервис не должен быть активен, но данные не удаляются. Реальное отключение выполняется только явной командой `service vpn absent`.

`purged` означает: данные можно удалить, но только явной командой `service vpn purge --confirm-purge`.

Изменение CSV само по себе не запускает разрушительные действия.

## Control Node

Control node выбирается по `state.csv`:

```csv
role,orchestration,management,vps3,,,present
```

Правила:

- должен быть ровно один active alias для `role,orchestration`;
- резервный orchestration node указывается в `candidate_aliases`;
- перенос control role делается изменением `state.csv`, а не hardcode alias `vps3`.

Пример подготовки резерва:

```csv
role,orchestration,management,vps3,vps4,,present
```

Здесь `vps3` остается active, а `vps4` является candidate.

## Inventory Generation

`create_inventory.sh` берет:

- endpoint/connection из `nodes.csv`;
- группы active/candidate/old из `state.csv`.

Пример:

```bash
sudo bash tools/bootstrap/create_inventory.sh \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --include vps1,vps2,vps3
```

Результат:

- active `production` попадает в `[prod]`;
- active `vpn` попадает в `[vpn_edges]`;
- candidate aliases попадают в `[candidate_*]`;
- old aliases попадают в `[old_*]`.

## VPN Service

VPN — первый platform service после infrastructure preparation.

Он управляется строкой:

```csv
service,vpn,vpn_edges,vps1+vps2+vps3,,,present
```

Проверить план:

```bash
bash tools/services/service.sh vpn plan \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv
```

Применить осторожно на одном узле:

```bash
bash tools/services/service.sh vpn apply \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1 \
  --check
```

Удаление сервиса не автоматическое:

```bash
bash tools/services/service.sh vpn absent --limit vps1
bash tools/services/service.sh vpn purge --limit vps1 --confirm-purge
```

## Current Physical Placement

Минимальная физическая информация остается в `services.yml`: страна, город и датацентр. Real endpoints остаются в operator-local CSV.

Текущая схема:

| Alias | Country | City | Datacenter |
| --- | --- | --- | --- |
| `vps1` | Netherlands | Amsterdam | Qupra DC2 |
| `vps2` | Kazakhstan | Almaty | Ahost |
| `vps3` | Russia | Moscow | IXcellerate |
