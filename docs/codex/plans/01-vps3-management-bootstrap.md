# Step-by-step: Control/Orchestration Node Bootstrap

Эта инструкция описывает первичный bootstrap платформы и повторные сценарии после переустановки ОС на одном VPS.

Главная модель:

- `nodes.csv` описывает узлы: alias, endpoint, connection, базовую Ansible-группу, capabilities и временный `root_password`.
- `state.csv` описывает желаемое состояние: active/candidate/old роли и сервисы.
- Control node выбирается не по имени `vps3`, а по строке `role,orchestration,...` в `state.csv`.

Bootstrap и Ansible не смешиваются:

| Этап | Что делает |
| --- | --- |
| Bootstrap | Пользователи, SSH keys, базовые sudo-права, каталоги, запрет root SSH |
| Ansible | Docker, firewall, fail2ban, SoftEther, edge, monitoring, backup, platform tooling |

Bootstrap runners не запускают `ansible-playbook`.

## 1. Operator Files

На операторской машине real files лежат в ignored-каталоге:

```text
operator/nodes.csv
operator/state.csv
```

`operator/` не коммитится.

### nodes.csv

Header должен быть строго таким:

```csv
current_alias,endpoint,connection,ansible_group,roles,root_password
```

Пример:

```csv
current_alias,endpoint,connection,ansible_group,roles,root_password
vps1,vps01.example.com,ssh,prod,production+vpn-edge,<TEMP_ROOT_PASSWORD_VPS1>
vps2,vps02.example.com,ssh,backup,preprod+hot-standby+backup+vpn-edge,<TEMP_ROOT_PASSWORD_VPS2>
vps3,vps03.example.com,ssh,management,management+monitoring+orchestration+vpn-edge,<TEMP_ROOT_PASSWORD_VPS3>
```

`root_password` нужен только для первого входа на свежую ОС. После успешного bootstrap конкретного alias runner очищает только его строку в локальном `operator/nodes.csv`.

### state.csv

Header должен быть строго таким:

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
role,monitoring,monitoring,vps3,,,present
service,vpn_edge,vpn_edges,vps1+vps2+vps3,,,present
service,vpn_cascade,vpn_cascades,,,,absent
```

`state=present/absent/purged` описывает желаемое состояние. Само изменение CSV не запускает разрушительные действия: `absent` и `purge` выполняются только явными service-командами.

## 2. Fresh Bootstrap Всех VPS С Windows

Основной путь после fresh reinstall OS всех узлов:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -ForceManagementKeyRefresh `
  -ForceOverwriteKeys `
  -AutoAcceptHostKey
```

Что делает wrapper:

1. Находит active control node по `role,orchestration` в `state.csv`.
2. Bootstrap-ит control node первым.
3. Сохраняет Ansible public key в `operator/ansible_control.managed_nodes.pub`.
4. Сохраняет ключи control node в `operator/<control-alias>/`.
5. Bootstrap-ит managed nodes, передавая им Ansible public key control node.
6. Очищает `root_password` после успешного bootstrap каждого alias.
7. Синхронизирует sanitized `nodes.csv` и `state.csv` на control node.
8. Готовит `/opt/ai-service-platform/inventory.ini`.

После выполнения подключись к control node и проверь:

```bash
cd /opt/ai-service-platform
ansible all -i inventory.ini -m ping
```

## 3. Значение Важных Флагов

`-ForceManagementKeyRefresh` разрешает обновить локальный `operator/ansible_control.managed_nodes.pub` при bootstrap control node.

`-ForceOverwriteKeys` разрешает перезаписать operator-local keys:

```text
operator/<alias>/deploy_key
operator/<alias>/admin_key
operator/<control-alias>/ansible_control_key
operator/<control-alias>/ansible_control.managed_nodes.pub
```

Он нужен после переустановки ОС, потому что старые ключи этого VPS уже невалидны.

`-RegenerateRemoteKeys` пересоздает ключи на самой VPS и требует `-ForceOverwriteKeys`. Используй его только если VPS не переустановлена, но ключи нужно заменить принудительно.

`-AutoAcceptHostKey` предназначен для ожидаемой смены SSH host key, например после reinstall OS. В Windows PuTTY flow он:

- удаляет старый PuTTY cached host key для endpoint;
- получает новый `SHA256:...` fingerprint;
- передает fingerprint в `plink/pscp` через `-hostkey`;
- добавляет `-no-antispoof` для `plink`.

Так prompt `Store key in cache?` не должен появляться.

## 4. PuTTY Key Notes

Windows bootstrap использует PuTTY tools:

```text
plink
pscp
puttygen
```

Bootstrap сохраняет private keys в OpenSSH-формате. Для `pscp/plink -i` нужен PuTTY `.ppk`, поэтому `sync_nodes_to_vps3.ps1` автоматически конвертирует `operator/<control-alias>/admin_key` во временный `.ppk` через `puttygen`.

Временный `.ppk`:

- создается только для sync;
- не коммитится;
- удаляется после завершения sync.

Если видишь ошибку:

```text
Unable to use key file "...admin_key" (OpenSSH SSH-2 private key (new format))
```

значит sync был запущен старой версией скрипта или без доступного `puttygen`.

## 5. Reinstall Одного Managed VPS

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

Используемые ключи:

- `root_password` из `nodes.csv` — только для первого входа на свежую ОС.
- `operator/ansible_control.managed_nodes.pub` — существующий public key control node.
- новые `operator/vps2/deploy_key` и `operator/vps2/admin_key` будут сохранены после bootstrap.

После успешного bootstrap выполни sync:

```powershell
.\tools\bootstrap\sync_nodes_to_vps3.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -AutoAcceptHostKey
```

Затем на control node:

```bash
cd /opt/ai-service-platform
ansible all -i inventory.ini -m ping
```

## 6. Reinstall Control Node

Если переустановлен active `orchestration` node, сейчас это обычно `vps3`, старый Ansible control key больше невалиден.

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

3. После этого появится новый:

```text
operator/ansible_control.managed_nodes.pub
operator/<control-alias>/ansible_control_key
operator/<control-alias>/ansible_control.managed_nodes.pub
```

4. Managed VPS должны получить новый Ansible public key. Самый простой путь — заново bootstrap-нуть managed aliases с новым key file:

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -Alias vps1 `
  -AnsibleAuthorizedKeyFile .\operator\ansible_control.managed_nodes.pub `
  -Force `
  -AutoAcceptHostKey
```

Повтори для каждого managed alias, у которого есть свежий `root_password`.

Если ОС managed VPS не переустанавливалась и root password уже недоступен, используй recovery helper на самой VPS для установки нового public key.

## 7. Sync Nodes/State На Control Node

После любого изменения `operator/nodes.csv` или `operator/state.csv` выполни:

```powershell
.\tools\bootstrap\sync_nodes_to_vps3.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -AutoAcceptHostKey
```

Sync делает:

- отправляет sanitized `nodes.csv` без root passwords;
- отправляет `state.csv`;
- конвертирует `admin_key` во временный `.ppk`;
- запускает `prepare_vps3_inventory.sh` на control node;
- удаляет временные remote/local файлы.

На control node итоговые файлы:

```text
/opt/ai-service-platform/operator/nodes.csv
/opt/ai-service-platform/operator/state.csv
/opt/ai-service-platform/inventory.ini
```

## 8. Ручные Проверки

Проверить SSH от control node к managed VPS:

```bash
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@<VPS1_PUBLIC_IP_OR_DNS> 'hostname && whoami'
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@<VPS2_PUBLIC_IP_OR_DNS> 'hostname && whoami'
```

Проверить Ansible inventory:

```bash
cd /opt/ai-service-platform
ansible all -i inventory.ini -m ping
```

`<VPS1_PUBLIC_IP_OR_DNS>` — placeholder. Не вводи его буквально.

## 9. Что Нельзя Коммитить

Не коммитятся:

- `operator/`;
- `operator/nodes.csv`;
- `operator/state.csv`;
- private keys;
- временные `.ppk`;
- root passwords;
- generated `inventory.ini`;
- real `.env`;
- `vpn_server.config`.

Безопасные шаблоны:

```text
infra/ansible/nodes.example.csv
infra/ansible/state.example.csv
infra/ansible/inventory.example.ini
```

## 10. Что Не Делает Bootstrap

Bootstrap не должен:

- запускать `ansible-playbook`;
- ставить Docker как финальное состояние;
- настраивать SoftEther/HAProxy/Nginx;
- раскатывать `AromaFlowAI` или `AI_E_Retail`;
- включать постоянный password login.

После bootstrap продолжается infrastructure preparation: GitHub deploy-access/predeploy-check, затем первый настоящий platform service rollout — SoftEther/VPN.
