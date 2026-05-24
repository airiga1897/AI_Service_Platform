# Step-by-step: control/orchestration bootstrap

Этот документ описывает первый инфраструктурный шаг: подготовить VPS после fresh OS install, выбрать active orchestration node из `state.csv`, синхронизировать operator-файлы, создать `inventory.ini` и выполнить verify.

`vps1`, `vps2`, `vps3` - это operator aliases. Реальный управляющий узел выбирается не по имени `vps3`, а по строке `platform_role,orchestration` в `operator/state.csv`.

## 1. Operator files

На операторской машине должны быть ignored-файлы:

```text
operator/nodes.csv
operator/state.csv
```

`operator/nodes.csv` - только адресная книга и временный root password для первого bootstrap:

```csv
current_alias,endpoint,connection,root_password
vps1,vps01.example.com,ssh,<temporary-root-password>
vps2,vps02.example.com,ssh,<temporary-root-password>
vps3,vps03.example.com,ssh,<temporary-root-password>
```

`operator/state.csv` - желаемая картина ролей и сервисов:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
platform_role,orchestration,orchestration,vps3,,,present
platform_role,monitoring,monitoring,vps3,,,present
platform_role,backup,backup,vps2,,,present
service,edge_haproxy,edge_haproxy,vps1,,,present
service,vpn_edge,vpn_edges,vps1+vps2+vps3,,,present
service,vpn_cascade,vpn_cascades,,,,absent
```

`state=present/absent/purged` само по себе ничего не запускает. Запуск делает только явная команда runner-а.

## 2. Fresh bootstrap всех VPS

После reinstall OS основной запуск с Windows:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -ForceManagementKeyRefresh `
  -ForceOverwriteKeys `
  -AutoAcceptHostKey
```

Wrapper делает полный цикл:

1. Находит active orchestration node по `platform_role,orchestration`.
2. Bootstrap-ит orchestration node первым.
3. Сохраняет Ansible public key в `operator/ansible_control.managed_nodes.pub`.
4. Сохраняет keys узла в `operator/<alias>/`.
5. Bootstrap-ит остальные VPS, упомянутые в `state.csv`, как managed nodes.
6. Очищает `root_password` в `operator/nodes.csv` только после успешного bootstrap соответствующего alias.
7. Выполняет sync на orchestration node.
8. Готовит `/opt/ai-service-platform/inventory.ini`.
9. Запускает verify.

## 3. Sync на orchestration node

Основная команда sync:

```powershell
.\tools\bootstrap\sync_to_orchestration.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -AutoAcceptHostKey
```

Compatibility wrapper `sync_nodes_to_vps3.ps1` сохранён, но новая документация использует `sync_to_orchestration.ps1`.

Sync всегда отправляет на orchestration node sanitized `nodes.csv` без root passwords. Helper-скрипты проще перезаливать каждый раз, чем сверять их по содержимому: они маленькие, а риск рассинхронизации ниже.

## 4. Automatic verify

Verify выполняет:

```bash
sudo -u ansible ansible all -i /opt/ai-service-platform/inventory.ini -m ping
sudo -u ansible ansible all -i /opt/ai-service-platform/inventory.ini --become -m shell -a 'sshd -T ...'
```

Ожидаемый hardening на каждом узле:

```text
permitrootlogin no
passwordauthentication no
```

Успешный bootstrap/sync означает: inventory создан, Ansible ping прошёл, root/password SSH login выключен.

## 5. Service rollout после bootstrap

После успешной инфраструктурной подготовки обычный operator flow:

```powershell
.\tools\services\rollout_from_state.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv
```

Скрипт сам делает sync + verify, читает все `kind=service` из `state.csv` и применяет поддержанные сервисы. GitHub Actions пока не участвуют.

## 6. Reinstall одного VPS

Если переустановлен managed VPS:

1. В `operator/nodes.csv` добавь временный `root_password` только для этого alias.
2. Запусти bootstrap только этого alias:

   ```powershell
   .\tools\bootstrap\bootstrap_from_windows.ps1 `
     -NodesFile .\operator\nodes.csv `
     -StateFile .\operator\state.csv `
     -Alias vps1 `
     -AnsibleAuthorizedKeyFile .\operator\ansible_control.managed_nodes.pub `
     -Force `
     -AutoAcceptHostKey
   ```

3. Выполни sync:

   ```powershell
   .\tools\bootstrap\sync_to_orchestration.ps1 `
     -NodesFile .\operator\nodes.csv `
     -StateFile .\operator\state.csv `
     -AutoAcceptHostKey
   ```

Если переустановлен active orchestration node, его Ansible control key считается новым. Managed nodes нужно заново bootstrap-нуть или отдельно доставить новый public key.
