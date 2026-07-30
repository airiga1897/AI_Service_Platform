# Персональные VPN-учётки MyCleanBot

MyCleanBot остаётся VPN-only. Для приглашённых пользователей используется
существующий listener `l3-vps1.mine-craft.su:443` и hub
`MyCleanBotOperatorVps1`; новый порт или публичный endpoint не создаётся.

`operator_arm` — защищённая операторская учётка. Её пароль нельзя передавать
пользователям или удалять из `client_users`.

## Контракт

- на одно активное приглашение создаётся одна учётка `mcb_user_001` …
  `mcb_user_009`;
- DHCP остаётся в диапазоне `10.89.1.10–10.89.1.20`;
- platform-router разрешает этому subnet только MyCleanBot HTTPS
  `172.31.1.11:443`;
- пароль хранится только в operator-local SoftEther secret и во временном
  delivery-файле;
- delivery-файл передаётся один раз по защищённому каналу и затем удаляется
  командой `acknowledge`;
- после revoke имя удерживается tombstone 90 дней;
- приложение MyCleanBot не получает SoftEther credentials или management
  access.

Tracked-конфигурация должна содержать
`managed_client_user_prefix: mcb_user_`, лимит `9` и
`protected_client_users: [operator_arm]`, как в
`docs/examples/l3-vps1-mycleanbot.example.yml`. Роль удаляет только
отсутствующих пользователей с этим явным prefix. Перед удалением она отключает
их активные сессии. Другие hub, runtime и пользователи не затрагиваются.

## Выпуск доступа

Сначала оператор создаёт приглашение в `/operator/` и получает его числовой
ID. Команды без `--apply` только показывают план:

```powershell
python .\tools\mycleanbot\manage_vpn_users.py issue `
  --invitation-id 123 `
  --operator-dir 'D:\Projects\Codex\AI_Service_Platform\operator'

python .\tools\mycleanbot\manage_vpn_users.py issue `
  --invitation-id 123 `
  --operator-dir 'D:\Projects\Codex\AI_Service_Platform\operator' `
  --apply
```

Helper не печатает пароль. Он возвращает путь к защищённому одноразовому
delivery JSON. Файл содержит server, hub, индивидуальные username/password,
URL приложения и hosts-запись:

```text
172.31.1.11 mycleanbot.mine-craft.su
```

После регистрации пользователя привязать продуктовый логин к invitation ID:

```powershell
python .\tools\mycleanbot\manage_vpn_users.py bind `
  --invitation-id 123 --product-username user_login `
  --operator-dir 'D:\Projects\Codex\AI_Service_Platform\operator' --apply
```

После безопасной передачи реквизитов удалить delivery-файл:

```powershell
python .\tools\mycleanbot\manage_vpn_users.py acknowledge `
  --invitation-id 123 `
  --operator-dir 'D:\Projects\Codex\AI_Service_Platform\operator' --apply
```

Изменение JSON — только desired state. Затем отдельно выполняются обычные
`platform_router plan` и, после явного согласования изменения VPS, `apply` с
`-Limit vps1`. Сам helper Ansible или VPS не запускает.

## Отзыв и блокировка

Блокировка пользователя в `/operator/` останавливает его MyCleanBot worker, но
не даёт приложению административный доступ к VPN. Оператор отдельно выполняет:

```powershell
python .\tools\mycleanbot\manage_vpn_users.py revoke `
  --invitation-id 123 `
  --operator-dir 'D:\Projects\Codex\AI_Service_Platform\operator'

python .\tools\mycleanbot\manage_vpn_users.py revoke `
  --invitation-id 123 `
  --operator-dir 'D:\Projects\Codex\AI_Service_Platform\operator' --apply
```

После проверки плана `platform_router apply -Limit vps1` отключит сессии и
удалит только соответствующую `mcb_user_NNN`. Для контроля:

```powershell
python .\tools\mycleanbot\manage_vpn_users.py audit `
  --operator-dir 'D:\Projects\Codex\AI_Service_Platform\operator'

python .\tools\mycleanbot\manage_vpn_users.py prune `
  --operator-dir 'D:\Projects\Codex\AI_Service_Platform\operator'
```

`prune --apply` удаляет из локального реестра только tombstone, которым больше
90 дней. Он не изменяет VPS и не затрагивает активные учётки.
