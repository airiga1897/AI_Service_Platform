# Step-by-step: control/orchestration bootstrap

Этот документ описывает первый инфраструктурный шаг: подготовить VPS после fresh OS install, выбрать active control node по роли `orchestration`, синхронизировать operator-файлы на control node, создать `inventory.ini` и автоматически выполнить verify.

Текущая схема:

- `vps1` — production/runtime node;
- `vps2` — preprod/hot-standby/backup node;
- `vps3` — active `orchestration` control node.

`vps1`, `vps2`, `vps3` — это operator aliases. Реальный control node выбирается не по имени `vps3`, а по строке `role,orchestration` в `operator/state.csv`.

## 1. Operator files

На операторской машине должны быть ignored-файлы:

```text
operator/nodes.csv
operator/state.csv
```

`operator/nodes.csv` хранит endpoints и временные root passwords только для первого bootstrap:

```csv
current_alias,endpoint,connection,ansible_group,roles,root_password
vps1,vps01.example.com,ssh,prod,production-runtime+vpn-edge,<temporary-root-password>
vps2,vps02.example.com,ssh,backup,preprod+hot-standby+backup+vpn-edge,<temporary-root-password>
vps3,vps03.example.com,ssh,management,management+monitoring+orchestration+vpn-edge,<temporary-root-password>
```

`operator/state.csv` хранит желаемое состояние ролей и сервисов:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
role,orchestration,management,vps3,,,present
service,vpn_edge,vpn_edges,vps1+vps2+vps3,,,present
service,vpn_cascade,vpn_cascades,,,,absent
```

`state=present/absent/purged` само по себе не запускает разрушительные действия. Остановка и удаление сервисов делаются только явными service-командами.

## 2. Fresh bootstrap всех VPS с Windows

После reinstall OS всех VPS основной запуск такой:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -ForceManagementKeyRefresh `
  -ForceOverwriteKeys `
  -AutoAcceptHostKey
```

Wrapper делает полный цикл:

1. Находит active control node по `role,orchestration` в `state.csv`.
2. Bootstrap-ит control node первым.
3. Сохраняет Ansible public key в `operator/ansible_control.managed_nodes.pub`.
4. Сохраняет ключи control node в `operator/<control-alias>/`.
5. Bootstrap-ит managed nodes, передавая им Ansible public key control node.
6. Очищает `root_password` в `operator/nodes.csv` только после успешного bootstrap соответствующего alias.
7. Синхронизирует sanitized `nodes.csv`, `state.csv` и `operator/softether` на control node.
8. Готовит `/opt/ai-service-platform/inventory.ini`.
9. Автоматически запускает verify на control node.

Успешный `bootstrap_all_from_windows.ps1` теперь означает:

- sync выполнен;
- `inventory.ini` создан;
- `ansible all -i inventory.ini -m ping` прошёл;
- root/password SSH login выключен на всех узлах.

## 3. Automatic verify

Verify выполняет remote script:

```bash
sudo bash /opt/ai-service-platform/tools/bootstrap/verify_control_node.sh
```

Он проверяет:

```bash
ansible all -i /opt/ai-service-platform/inventory.ini -m ping
ansible all -i /opt/ai-service-platform/inventory.ini --become -m shell -a 'sshd -T ...'
```

На каждом узле ожидается:

```text
permitrootlogin no
passwordauthentication no
```

Если хотя бы один узел не отвечает по Ansible или возвращает `yes`, verify падает, а весь bootstrap-all считается неуспешным.

Для аварийной диагностики можно временно отключить verify:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -ForceManagementKeyRefresh `
  -ForceOverwriteKeys `
  -AutoAcceptHostKey `
  -SkipVerify
```

`-SkipVerify` не является нормальным production-path. Это только troubleshooting.

## 4. SSH hardening

Root password нужен только для первого bootstrap. После успешной подготовки:

- новая SSH-сессия под `root` должна быть запрещена;
- вход по паролю должен быть запрещён;
- `useradmin`, `depuser` и `ansible` остаются key-only;
- старая уже открытая root-сессия может не оборваться сама.

Bootstrap применяет SSH hardening через:

- `/etc/ssh/sshd_config.d/00-ai-service-platform-hardening.conf`;
- нормализацию directives в `/etc/ssh/sshd_config`;
- нормализацию conflicting directives в `/etc/ssh/sshd_config.d/*.conf`;
- `sshd -t`;
- restart `ssh` или `sshd`;
- итоговую проверку `sshd -T`.

## 5. Важные флаги

`-ForceManagementKeyRefresh` разрешает обновить локальный `operator/ansible_control.managed_nodes.pub` при bootstrap control node.

`-ForceOverwriteKeys` разрешает перезаписать operator-local keys:

```text
operator/<alias>/deploy_key
operator/<alias>/admin_key
operator/<control-alias>/ansible_control_key
operator/<control-alias>/ansible_control.managed_nodes.pub
```

`-RegenerateRemoteKeys` пересоздаёт ключи на самой VPS и требует `-ForceOverwriteKeys`.

`-AutoAcceptHostKey` нужен при ожидаемой смене SSH host key, например после reinstall OS.

`-FixKeyAcl` больше не нужен. `sync_nodes_to_vps3.ps1` автоматически исправляет слишком открытый ACL для `operator/<control-alias>/admin_key`. Флаг оставлен только для совместимости старых команд.

## 6. Reinstall одного managed VPS

Если переустановлен только `vps1` или `vps2`, control node не меняется.

Пример для `vps2`:

1. В `operator/nodes.csv` пропиши новый временный `root_password` только в строке `vps2`.
2. Запусти bootstrap только этого alias:

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -Alias vps2 `
  -AnsibleAuthorizedKeyFile .\operator\ansible_control.managed_nodes.pub `
  -OperatorDir .\operator `
  -Force `
  -AutoAcceptHostKey
```

3. После успешного bootstrap выполни sync + verify:

```powershell
.\tools\bootstrap\sync_nodes_to_vps3.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -AutoAcceptHostKey
```

## 7. Reinstall control node

Если переустановлен active `orchestration` node, старый Ansible control key больше невалиден.

Порядок:

1. В `operator/nodes.csv` пропиши новый временный `root_password` для control alias.
2. Запусти bootstrap control node:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -ForceManagementKeyRefresh `
  -ForceOverwriteKeys `
  -AutoAcceptHostKey `
  -SkipManaged
```

3. Managed VPS должны получить новый Ansible public key. После fresh reinstall managed nodes проще снова bootstrap-нуть managed aliases с новым key file.

## 8. Sync nodes/state на control node

После любого изменения `operator/nodes.csv`, `operator/state.csv` или `operator/softether` выполни:

```powershell
.\tools\bootstrap\sync_nodes_to_vps3.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -AutoAcceptHostKey
```

Sync делает:

- отправляет sanitized `nodes.csv` без root passwords;
- отправляет `state.csv`;
- отправляет `operator/softether`, если каталог существует;
- обновляет `verify_control_node.sh` на control node;
- запускает `prepare_vps3_inventory.sh`;
- запускает `verify_control_node.sh`.

## 9. Fallback/debug commands

Эти команды больше не являются основным путём. Они нужны только для диагностики.

Проверить inventory вручную:

```bash
cd /opt/ai-service-platform
ansible all -i inventory.ini -m ping
```

Проверить SSH hardening вручную:

```bash
sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication'
```

Проверить VPN plan:

```bash
tools/services/service.sh vpn_edge plan
```
