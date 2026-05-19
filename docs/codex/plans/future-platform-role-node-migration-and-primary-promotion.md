# Future runbook: platform role node migration and primary promotion

Эта инструкция описывает будущую миграцию любого physical node, который
исполняет platform role. Сейчас ничего не мигрируем.

## 1. Модель

`platform_role` — назначение узла: `production-runtime`,
`preprod-hot-standby-backup`, `management-monitoring-orchestration` или
`vpn-only-edge`.

`physical_node` — конкретный VPS в стране, городе и датацентре.

`VPS1`, `VPS2`, `VPS3` — current aliases текущей схемы, а не настоящие роли.

Для одиночной роли primary определяется так:

```yaml
platform_roles:
  production-runtime:
    active_node: vps-nl-qupra-01
    candidate_node: null
    old_node: null
```

Для multi-node роли:

```yaml
platform_roles:
  vpn-only-edge:
    active_nodes: []
    candidate_nodes: []
    old_nodes: []
```

## 2. Когда менять repo

Если меняется только IP/DNS active node, а страна, город и датацентр остаются
тем же operational target, обычно достаточно обновить real inventory, DNS/CDN и
allowlist вне repo.

Если меняется страна, город, датацентр или назначение узла, нужно обновить:

- `services.yml`;
- `docs/VPS_ROLES.md`;
- связанные docs про SoftEther, GeoPolicy, CDN или backup, если там есть
  assumptions по стране или routing.

IP, DNS, private keys, `.env`, provider id, тариф и generated inventory не
коммитятся.

## 3. Подготовить candidate physical node

Создать новый VPS и не выключать старый active node.

С active management node скопировать на candidate два файла:

```text
setup_vps.sh
ansible_control.managed_nodes.pub
```

На candidate положить public key сюда:

```text
/tmp/ansible_control.managed_nodes.pub
```

Запустить bootstrap target, который соответствует текущему alias/назначению:

```bash
sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash setup_vps.sh vps1-prod
```

Для `preprod-hot-standby-backup` используется `vps2-preprod`. Для будущих
role-based targets команда будет заменена на более нейтральную.

После bootstrap удалить временный public key файл:

```bash
rm -f /tmp/ansible_control.managed_nodes.pub
```

С management node проверить SSH:

```bash
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@<CANDIDATE_PUBLIC_IP_OR_DNS> 'hostname && whoami'
```

## 4. Provision candidate

В real inventory добавить candidate-группу, не заменяя active-группу:

```ini
[candidate_prod]
prod_candidate ansible_host=<CANDIDATE_PUBLIC_IP_OR_DNS> ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control
```

С management node:

```bash
ansible -i inventory.ini candidate_prod -m ping
ansible-playbook -i inventory.ini infra/ansible/site.yml --limit candidate_prod --check
ansible-playbook -i inventory.ini infra/ansible/site.yml --limit candidate_prod
```

Если текущие playbooks пока ожидают только группы `prod`, `backup` или
`management`, использовать отдельный operator inventory для candidate и не
менять active-группу до promotion.

## 5. Подготовить данные и runtime

Для `production-runtime`:

- сделать свежий backup/snapshot active node;
- синхронизировать media/uploads/volumes;
- подготовить runtime env из секретного хранилища;
- восстановить или перевыпустить TLS;
- восстановить SoftEther config/volumes, если узел участвует в VPN;
- проверить `docker compose config`.

Для `preprod-hot-standby-backup`:

- проверить backup storage и restore сценарий;
- проверить standby/failover assumptions;
- убедиться, что preprod runtime не конфликтует с backup duties.

Для `vpn-only-edge`:

- проверить HAProxy TCP entrypoints;
- проверить SoftEther TCP listeners;
- проверить monitoring и backup SoftEther config.

## 6. Особый случай: migration management role

`management-monitoring-orchestration` переносится осторожнее, потому что это
control node.

До promotion нового management node нужно перенести или заново подготовить:

- Ansible control private/public key;
- real inventory и vault/SOPS data вне repo;
- monitoring state;
- Semaphore state, если он уже используется;
- known_hosts и доступ к managed nodes.

После bootstrap candidate management node должен уметь подключаться к active
managed nodes:

```bash
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@<MANAGED_NODE_PUBLIC_IP_OR_DNS> 'hostname && whoami'
```

Старый management node не выключать до проверки Ansible, monitoring и backup
orchestration на новом.

## 7. Promote candidate

В maintenance/freeze window:

1. Остановить запись или включить maintenance, если роль обслуживает stateful
   production traffic.
2. Выполнить финальную синхронизацию данных.
3. Проверить readiness candidate.
4. Обновить `platform_roles.<role>.active_node` в плановом изменении repo, если
   меняется страна/город/датацентр или physical node metadata.
5. В real inventory заменить active-группу на candidate.
6. Переключить DNS/CDN origin/edge routing, если роль принимает внешний трафик.
7. Старый active node сохранить как `old_node` или old inventory group на
   rollback window.

## 8. Проверка после promotion

С management node и локально проверить:

```bash
ansible -i inventory.ini all -m ping
```

Дополнительно проверить:

- application healthcheck для runtime roles;
- HAProxy/Nginx logs;
- DB primary/standby status, если применимо;
- TLS;
- SoftEther TCP endpoints;
- monitoring и backup jobs.

## 9. Rollback window

Старый active node не удалять сразу.

Если проблема критическая:

1. Остановить запись на новом active node.
2. Вернуть DNS/CDN origin/edge routing на old node.
3. Вернуть old node в active inventory group.
4. Проверить healthcheck.
5. Разобрать причину на candidate.

Если новый active node стабилен в течение rollback window:

- удалить old node из active inventory;
- убрать старые monitoring targets и allowlist;
- обновить backup scopes;
- удалить старый сервер у провайдера только после отдельного подтверждения.

## Важные ограничения

- Не менять active-группу до готовности candidate.
- Не удалять old node до успешного healthcheck и rollback window.
- Не коммитить реальные IP, private keys, `.env`, inventory, provider
  credentials, тарифы или provider ids.
- Production deploy и primary promotion не делать без отдельного явного решения.
