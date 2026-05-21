# Platform roles and current VPS aliases

Платформа разделяет две сущности:

- `platform_role` — что узел делает в архитектуре.
- `physical_node` — где физически находится VPS.

`VPS1`, `VPS2` и `VPS3` — это current aliases текущей схемы. Их можно
использовать в bootstrap-командах, старых runbook и UI-обсуждениях, но они не
являются настоящими ролями. При миграции меняется `active_node` у
`platform_role`, а не смысл alias `VPS1`.

## Physical nodes

`services.yml` хранит только минимальные сведения о физическом размещении VPS:
страну, город и датацентр. IP, DNS, тариф, provider id, OS template, private
keys, `.env` и реальный `inventory.ini` не коммитятся.

Текущие physical nodes:

| Physical node | Current alias | Country | City | Datacenter |
| --- | --- | --- | --- | --- |
| `vps-nl-qupra-01` | `VPS1` | Netherlands | Amsterdam | Qupra DC2 |
| `vps-kz-ahost-01` | `VPS2` | Kazakhstan | Almaty | Ahost |
| `vps-ru-ixcellerate-01` | `VPS3` | Russia | Moscow | IXcellerate |

## Platform roles

### `production-runtime`

Текущий alias: `VPS1`.

Active physical node: `vps-nl-qupra-01`.

Ansible group: `prod`.

- Начальный production-стек: `aromaflow-work`.
- Здесь стартуют primary runtime и primary application data.
- Дополнительные production-стеки добавляются только после явного согласования.
- Изменения в production должны сохранять backup, restore, TLS, edge routing и
  rollback.

### `preprod-hot-standby-backup`

Текущий alias: `VPS2`.

Active physical node: `vps-kz-ahost-01`.

Ansible group: `backup`.

- Хостит demo, MVP и dev-валидационные стеки по необходимости.
- Выступает hot standby и failover-target для production-runtime.
- Хранит локальные копии бэкапов до offsite-выгрузки в S3.
- Не должен молча смешивать preprod-эксперименты с обязанностями
  standby/backup.

### `management-monitoring-orchestration`

Текущий alias: `VPS3`.

Active physical node: `vps-ru-ixcellerate-01`.

Ansible group: `management`.

- Запускает Ansible workflow, мониторинг и оркестрацию бэкапов.
- Может хостить Prometheus, Grafana, Loki/Promtail, Alertmanager и Semaphore.
- Не является рантаймом продуктовых приложений.
- При миграции этой роли отдельно переносится control state: Ansible key,
  inventory/vault вне repo, monitoring state и Semaphore state.

### `vpn-only-edge`

Текущий alias: отсутствует.

Ansible group: `vpn_edges`.

- Будущая multi-node роль для стран/регионов, где нужен только VPN edge.
- На таких узлах не должны работать product runtime stacks.
- Нужны HAProxy TCP entrypoints, SoftEther, monitoring agent, firewall rules и
  backup конфигурации SoftEther.

## Operator CSV and inventory generation

`current_alias` — короткий операторский ключ строки CSV: `vps1`, `vps2`,
`vps3`. Он не является platform role. `roles` задаёт обязанности узла, а
`ansible_group` задаёт группу для playbook.

`ansible_group` задаёт primary-группу узла. Capability-роли из `roles` могут добавлять
узел в дополнительные группы. Например, `vpn-edge` добавляет узел в `[vpn_edges]`,
поэтому один и тот же `vps1` может быть и в `[prod]`, и в `[vpn_edges]`.

| Role(s) in CSV | Ansible group |
| --- | --- |
| `production-runtime` | `prod` |
| `preprod+hot-standby+backup` | `backup` |
| `management+monitoring+orchestration` | `management` |
| `vpn-edge` | `vpn_edges` |
| `vpn-cascade` | future/experimental |

Real endpoints хранятся только в operator CSV на VPS3, например:

```text
/opt/ai-service-platform/operator/nodes.csv
```

Безопасный шаблон хранится в `infra/ansible/nodes.example.csv`:

```csv
current_alias,endpoint,connection,ansible_group,roles,root_password
vps1,vps01.example.com,ssh,prod,production-runtime+vpn-edge,
vps2,vps02.example.com,ssh,backup,preprod+hot-standby+backup+vpn-edge,
vps3,vps03.example.com,ssh,management,management+monitoring+orchestration+vpn-edge,
```

Для первого bootstrap с операторской машины у `vps3` должен быть реальный
DNS/IP и `connection=ssh`. Значение `local,local` допустимо только позже в
operator CSV на самой VPS3, если Ansible запускается с этой же management-ноды.

Inventory генерируется из CSV:

```bash
sudo bash tools/bootstrap/create_inventory.sh \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --include vps1,vps2,vps3
```

Тот же CSV можно использовать для bootstrap по alias:

```bash
sudo bash tools/bootstrap/setup_vps.sh --nodes-file /tmp/nodes.csv --alias vps2
```

`root_password` используется только bootstrap runner-ами для первого входа на
голую VPS. Он не попадает в generated `inventory.ini`, не нужен `setup_vps.sh`
как постоянный секрет и не копируется на VPS в real form: runner передаёт
sanitized CSV с пустой последней колонкой.

Реальные endpoint-ы и root passwords остаются только в operator `nodes.csv`.
Generated `inventory.ini` на VPS3 тоже не коммитится.

`deploy-access` не является ролью VPS. Это временная настройка workflow или
GitHub Environment для конкретного деплой-сценария.

## Migration model

Для одиночных ролей состояние хранится в `platform_roles`:

```yaml
production-runtime:
  active_node: vps-nl-qupra-01
  candidate_node: null
  old_node: null
```

Для multi-node роли `vpn-only-edge` используются списки:

```yaml
vpn-only-edge:
  active_nodes: []
  candidate_nodes: []
  old_nodes: []
```

Миграция любой роли проходит одинаково:

1. Создать новый `physical_node`.
2. Назначить его `candidate_node` или добавить в `candidate_nodes`.
3. Bootstrap/provision/healthcheck выполнить без замены active node.
4. После проверки переключить `active_node` на candidate.
5. Предыдущий active node временно сохранить как `old_node` на rollback window.

`lifecycle_state` не хранится в `physical_nodes`, чтобы не было двух источников
истины. Состояние узла определяется только тем, как на него ссылается
`platform_role`.

## External storage

S3-совместимое объектное хранилище используется для offsite-бэкапов в модели
3-2-1. Миграция медиа-хранилища в S3 — опциональна и отделена от backup S3.

## VPN presence

SoftEther — платформенный VPN-сервис на всех текущих platform nodes. Первая
сохранённая установка была на current alias `VPS1`, но целевое состояние — один
экземпляр SoftEther на каждом нужном physical node для локального ingress
клиентов и контролируемого egress по странам.
