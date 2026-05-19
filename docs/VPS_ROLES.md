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
