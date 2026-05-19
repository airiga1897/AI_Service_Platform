# Future runbook: VPS1 provider migration and primary promotion

Эта инструкция описывает будущий перенос логической роли `VPS1` на новый
физический сервер или к другому провайдеру. Сейчас ничего не мигрируем.

## 1. Понять модель primary

`VPS1` — это логическая роль `production-runtime`, а не навсегда привязанный
сервер или IP.

Active primary определяется real inventory вне репозитория:

```ini
[prod]
vps1_prod ansible_host=<ACTIVE_VPS1_PUBLIC_IP_OR_DNS> ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control
```

Новый сервер сначала не становится primary. Его нужно добавить как candidate:

```ini
[candidate_prod]
vps1_candidate ansible_host=<NEW_VPS1_PUBLIC_IP_OR_DNS> ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control
```

Старый primary после переключения временно сохраняется для rollback:

```ini
[old_prod]
vps1_old ansible_host=<OLD_VPS1_PUBLIC_IP_OR_DNS> ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control
```

Реальный `inventory.ini`, IP, private keys, `.env` и provider credentials не
коммитятся.

## 2. Когда нужно менять repo

Если меняется только IP или провайдер, но роль, страна и ресурсы остаются
эквивалентными, обычно достаточно обновить real inventory, DNS/CDN и внешние
allowlist-и.

Если меняется страна, назначение или ожидаемые ресурсы VPS1, нужно обновить:

- `services.yml`;
- `docs/VPS_ROLES.md`;
- связанные docs про SoftEther, GeoPolicy или CDN, если там упоминается страна
  или routing-предположение.

## 3. Подготовить новый VPS1 у провайдера

Создай новый сервер у выбранного провайдера. Старый VPS1 не выключать и не
удалять.

С VPS3 скопируй на новый VPS1 два файла:

```text
setup_vps.sh
ansible_control.managed_nodes.pub
```

Public key на VPS3:

```bash
sudo -u ansible cat /home/ansible/.ssh/ansible_control.managed_nodes.pub
```

На новом VPS1 положи public key сюда:

```text
/tmp/ansible_control.managed_nodes.pub
```

## 4. Bootstrap нового VPS1

На новом VPS1:

```bash
sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash setup_vps.sh vps1-prod
```

После успешного bootstrap:

```bash
rm -f /tmp/ansible_control.managed_nodes.pub
```

С VPS3 проверить SSH:

```bash
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@<NEW_VPS1_PUBLIC_IP_OR_DNS> 'hostname && whoami'
```

Ожидаемый результат:

```text
<hostname-new-vps1>
ansible
```

## 5. Provision candidate

В real inventory добавить новый узел в `[candidate_prod]`, не заменяя active
`[prod]`.

С VPS3:

```bash
ansible -i inventory.ini candidate_prod -m ping
ansible-playbook -i inventory.ini infra/ansible/site.yml --limit candidate_prod --check
ansible-playbook -i inventory.ini infra/ansible/site.yml --limit candidate_prod
```

Если текущий playbook пока ожидает только группу `[prod]`, временно применяй
production-роли к candidate через отдельный безопасный operator inventory или
через явный playbook/limit, не меняя active `[prod]` до момента переключения.

## 6. Подготовить данные и runtime

Если старый VPS1 уже был production:

- сделать свежий backup/snapshot старого VPS1;
- синхронизировать media/uploads/volumes;
- подготовить runtime env на новом VPS1 из секретного хранилища;
- восстановить или перевыпустить TLS-сертификаты;
- восстановить SoftEther config/volumes, если VPS1 участвует в VPN;
- проверить `docker compose config`.

Если VPS1 ещё не был в production, перенос данных не нужен: достаточно
подготовить runtime-каталоги и проверить compose/config.

## 7. Подготовить переключение primary

Перед переключением:

- уменьшить TTL production DNS заранее;
- проверить CDN origin, если CDN уже используется;
- проверить firewall allowlist и monitoring targets;
- убедиться, что backup на новом VPS1 настроен;
- выбрать короткое maintenance/freeze окно для финальной синхронизации.

Важно: не допустить split-brain. В момент переключения только один узел должен
принимать запись в production БД/volume.

## 8. Promote candidate to primary

В maintenance/freeze окно:

1. Остановить запись на старом VPS1 или перевести приложение в maintenance.
2. Выполнить финальную синхронизацию данных.
3. Проверить, что новый узел готов принимать production traffic.
4. В real inventory заменить active primary:

```ini
[prod]
vps1_prod ansible_host=<NEW_VPS1_PUBLIC_IP_OR_DNS> ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control

[old_prod]
vps1_old ansible_host=<OLD_VPS1_PUBLIC_IP_OR_DNS> ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control
```

5. Переключить DNS A/AAAA/CNAME или CDN origin на новый VPS1.
6. Запустить production runtime на новом VPS1, если он ещё не запущен.

## 9. Проверить после переключения

С VPS3 и локально:

```bash
dig +short <production-domain>
ansible -i inventory.ini prod -m ping
```

Проверить:

- production healthcheck;
- HAProxy/Nginx logs;
- application logs;
- DB primary/standby status;
- TLS;
- SoftEther TCP endpoints, если включены;
- monitoring и backup jobs.

## 10. Rollback window

Старый VPS1 не удалять сразу.

Если проблема критичная:

1. Остановить запись на новом VPS1.
2. Вернуть DNS/CDN origin на старый VPS1.
3. Вернуть старый VPS1 в `[prod]`.
4. Проверить healthcheck.
5. Разобрать причину на новом VPS1.

Если новый VPS1 стабилен в течение rollback window:

- удалить старый VPS1 из active inventory;
- убрать старый IP из monitoring targets и allowlist-ов;
- обновить backup scopes;
- удалить старый сервер у провайдера;
- вернуть DNS TTL к нормальному значению.

## 11. Связь с failover/failback

Текущая платформа уже содержит failover/failback заготовки для сценария
`VPS1 -> VPS2`, но provider migration — это плановая primary promotion, а не
аварийный failover.

Разница:

- failover: старый primary недоступен, быстро промоутируем standby;
- primary promotion: старый primary доступен, данные синхронизируются
  контролируемо, переключение делается через maintenance/freeze окно.

Для PostgreSQL promotion/failback нужно отдельно подтвердить состояние
репликации, чтобы не получить split-brain.

## Важные ограничения

- Не менять `[prod]` до готовности candidate.
- Не удалять старый VPS1 до успешного healthcheck и rollback window.
- Не коммитить реальные IP, private keys, `.env`, inventory или provider
  credentials.
- Production deploy не делать без отдельного явного решения.
