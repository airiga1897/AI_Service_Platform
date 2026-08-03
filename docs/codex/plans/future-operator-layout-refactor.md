# Future operator layout refactor

## Статус

Необязательный будущий рефакторинг. Текущие пути остаются каноническими:

```text
operator/nodes.csv
operator/state.csv
operator/networks.csv
operator/ansible_control.managed_nodes.pub
```

Корень `operator/` считается каталогом верхнеуровневых operator manifests:

- `nodes.csv` — адресная книга узлов;
- `state.csv` — роли и размещение сервисов;
- `networks.csv` — сгенерированная сетевая модель;
- `ansible_control.managed_nodes.pub` — публичный bootstrap-ключ active
  orchestration node для managed VPS.

Подкаталоги предназначены для конфигураций отдельных сервисов и данных
конкретных aliases. Публичный ключ не является секретом, но соответствующий
private key никогда не должен попадать в Git.

## Когда возвращаться к рефакторингу

Перенос оправдан, только если в корне `operator/` появится заметно больше
верхнеуровневых файлов, потребуется несколько независимых inventory-наборов или
будет пересматриваться bootstrap/recovery contract. Только визуальная
аккуратность не является достаточной причиной.

Возможная целевая структура:

```text
operator/
  inventory/
    nodes.csv
    state.csv
    networks.csv
  bootstrap/
    ansible_control.managed_nodes.pub
  vps1/
  vps2/
  ...
```

## Условия безопасной миграции

Перенос выполняется отдельным рубежом и одним согласованным изменением:

1. Обновить defaults и явные параметры bootstrap, service, network, egress,
   backup и audit tooling.
2. Обновить локальные и удалённые пути
   `/opt/ai-service-platform/operator/*`, bundle/sync logic и документацию.
3. Сохранить временную обратную совместимость для старых путей либо выполнить
   атомарное переключение всех consumers.
4. Проверить bootstrap нового узла, orchestration inventory, service remote,
   operator backup/restore и генерацию `networks.csv`.
5. Убедиться, что ignored secrets и private keys не стали tracked.

До отдельного принятого плана файлы вручную не перемещать: текущие пути
используются многими рабочими скриптами и являются частью operational
interface.
