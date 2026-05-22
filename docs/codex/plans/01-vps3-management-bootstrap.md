# Step-by-step: control/orchestration node bootstrap

Эта инструкция фиксирует правильный порядок первичной инициализации платформы:

1. Сначала с операторской машины bootstrap-ится control/orchestration node.
2. Runner автоматически сохраняет Ansible control public key в `./operator/ansible_control.managed_nodes.pub`.
3. Runner автоматически сохраняет bootstrap-generated private keys в `./operator/<alias>/`.
4. Затем `vps1` и `vps2` bootstrap-ятся как managed nodes с этим public key.
5. Только после bootstrap всех VPS запускается отдельный Ansible-этап с control node.

Важно: `vps1`, `vps2`, `vps3` здесь — короткие operator aliases текущей схемы, а не настоящие platform roles. `nodes.csv` описывает узлы, а `state.csv` описывает active/candidate/old роли и сервисы.
Текущий alias control node — `vps3`, но скрипты выбирают его по строке `role,orchestration,...` в `state.csv`.

Bootstrap и Ansible не смешиваются:

| Этап | Что делает |
| --- | --- |
| Bootstrap | Пользователи, SSH keys, базовые sudo-права, каталоги, запрет root SSH |
| Ansible | Docker, firewall, fail2ban, SoftEther, edge, monitoring, backup, platform tooling |

Bootstrap runners не запускают `ansible-playbook`.

## Fresh bootstrap после переустановки ОС

Если VPS были переустановлены, этот документ снова становится первым operational step. Старые ключи из
`operator/` нужно считать устаревшими, пока они не пересохранены из нового bootstrap output.

Текущий порядок после reinstall OS:

1. Обновить `./operator/nodes.csv`: у `vps1`, `vps2`, `vps3` должны быть реальные `endpoint`, `connection=ssh`
   и свежие временные `root_password`.
2. Обновить `./operator/state.csv`: строка `role,orchestration,...` должна иметь ровно один active alias.
3. Bootstrap control node первым. В текущей схеме это `vps3`, потому что он active для роли `orchestration`.
4. Bootstrap `vps1` и `vps2` только с новым `./operator/ansible_control.managed_nodes.pub`.
5. После каждого успешного bootstrap runner сохраняет ключи в `./operator/<alias>/`.
6. После каждого успешного bootstrap runner очищает `root_password` только в строке этого alias в `./operator/nodes.csv`.
7. Синхронизировать sanitized `nodes.csv` и `state.csv` на control node, если локальные CSV изменились.
8. Проверить SSH-доступ пользователя `ansible` с control node на `vps1`/`vps2`.
9. Создать real inventory на control node и выполнить `ansible all -i inventory.ini -m ping`.

GitHub deploy-access, VPN и product deploy не запускаются, пока этот fresh bootstrap проход не завершен успешно.

Bootstrap можно запускать повторно. Обычный повторный запуск не пересоздает уже
созданные SSH private keys и не очищает `authorized_keys`. Это важно: повторный
запуск должен чинить/дозаполнять базовую подготовку, а не ломать существующий
доступ.

Опасный emergency-режим для пересоздания ключей включается только явно:

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -Alias vps3 `
  -Force `
  -RegenerateRemoteKeys
```

или:

```bash
bash tools/bootstrap/bootstrap_from_unix.sh \
  --nodes-file ./operator/nodes.csv \
  --alias vps3 \
  --force \
  --regenerate-remote-keys
```

Разница флагов:

- `-Force` / `--force` разрешает перезаписать локальный public key файл в `./operator`.
- `-RegenerateRemoteKeys` / `--regenerate-remote-keys` передаёт на VPS `FORCE_REGENERATE_KEYS=1`.

Для management node пересоздание remote keys требует `-Force` / `--force`,
чтобы локальный public key был обновлён явно и не остался старым.
Используй этот режим только если действительно нужно заменить bootstrap-generated keys.
Даже в этом режиме `authorized_keys` не очищается автоматически.

## 1. Подготовить operator CSV

На операторской машине создай локальную ignored-папку:

```powershell
mkdir operator
```

Создай real CSV:

```text
./operator/nodes.csv
```

Header должен быть строго таким:

```csv
current_alias,endpoint,connection,ansible_group,roles,root_password
```

Пример структуры:

```csv
current_alias,endpoint,connection,ansible_group,roles,root_password
vps1,vps01.example.com,ssh,prod,production-runtime+vpn-edge,<TEMP_ROOT_PASSWORD_VPS1>
vps2,vps02.example.com,ssh,backup,preprod+hot-standby+backup+vpn-edge,<TEMP_ROOT_PASSWORD_VPS2>
vps3,vps03.example.com,ssh,management,management+monitoring+orchestration+vpn-edge,<TEMP_ROOT_PASSWORD_VPS3>
```

`root_password` используется только runner-ом для первого входа на голую VPS. После успешного bootstrap конкретного alias runner очищает пароль в локальном `./operator/nodes.csv`. Если bootstrap упал, пароль остаётся, чтобы можно было повторить запуск.

На VPS всегда копируется sanitized CSV без root password. Эта очистка на стороне VPS3 остаётся обязательной страховкой, даже если локальный CSV уже очищен. Постоянный вход по паролю не включается.

Для первого bootstrap с Windows/WSL/Linux/macOS у control node должен быть реальный DNS или IP и `connection=ssh`. Строка `vps3,local,local,...` для этого шага не подходит: `local` используется только позже, если Ansible inventory готовится и запускается прямо на control node.

Безопасный template без реальных адресов и паролей хранится здесь:

```text
infra/ansible/nodes.example.csv
infra/ansible/state.example.csv
```

Real `./operator/nodes.csv` не коммитится.

Рекомендуемая структура operator-файлов после bootstrap:

```text
operator/
  nodes.csv
  ansible_control.managed_nodes.pub
  vps1/
    deploy_key
    admin_key
  vps2/
    deploy_key
    admin_key
  vps3/
    deploy_key
    admin_key
    ansible_control_key
    ansible_control.managed_nodes.pub
```

`operator/ansible_control.managed_nodes.pub` — совместимый короткий путь для bootstrap `vps1`/`vps2`.
`operator/vps3/ansible_control.managed_nodes.pub` — тот же public key, но разложенный по alias.

Bootstrap runners автоматически сохраняют key-блоки в эту структуру после успешного remote bootstrap. Если runner завершился после успешной подготовки VPS, но до локального сохранения ключей, используй напечатанные key-блоки как emergency fallback и сохрани их вручную в те же файлы.

## 2. Основной Windows-путь: bootstrap all

На Windows основной путь — один wrapper, который сам находит control node по роли `orchestration`.
Для текущего CSV он выберет `vps3`.

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -ForceManagementKeyRefresh
```

Что делает wrapper:

1. Проверяет `nodes.csv`, `plink`, `pscp` и нужные bootstrap-скрипты.
2. Находит единственный active alias в строке `role,orchestration` из `state.csv`.
3. Bootstrap-ит control node первым.
4. Берёт `.\operator\ansible_control.managed_nodes.pub`.
5. Bootstrap-ит managed nodes. Если `-ManagedAliases` не указан, выбирает их по ролям `production-runtime`, `preprod`, `hot-standby`, `backup`, `vpn-edge`, `vpn-cascade`.
6. Синхронизирует sanitized `nodes.csv` и `state.csv` на control node.
7. Печатает следующий ручной шаг: `ansible all -i inventory.ini -m ping` на control node.

Если control node нужно указать явно:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -ControlAlias vps3 `
  -ForceManagementKeyRefresh
```

Если нужно ограничить managed nodes:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -ManagedAliases vps1,vps2 `
  -ForceManagementKeyRefresh
```

Если bootstrap уже выполнялся и нужно перезаписать operator-local ключи:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -ForceManagementKeyRefresh `
  -ForceOverwriteKeys
```

`-RegenerateRemoteKeys` используй только если нужно пересоздать ключи на самих VPS. Этот режим требует `-ForceOverwriteKeys`.

## 3. Fallback: bootstrap control node отдельной командой

Control node — текущий узел с role `orchestration`. Сейчас это alias `vps3`.
На нем bootstrap создаёт пользователя `ansible`, private key:

```text
/home/ansible/.ssh/ansible_control
```

и public key для managed nodes:

```text
/home/ansible/.ssh/ansible_control.managed_nodes.pub
```

Bootstrap-generated private key живёт на control node и автоматически сохраняется в ignored `operator/<control-alias>/` на операторской машине. Public key runner также сохраняет как короткий файл `operator/ansible_control.managed_nodes.pub`.

### Windows

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -Alias vps3 `
  -Force
```

После успешного fresh bootstrap появятся или обновятся файлы:

```text
.\operator\ansible_control.managed_nodes.pub
.\operator\vps3\deploy_key
.\operator\vps3\admin_key
.\operator\vps3\ansible_control_key
.\operator\vps3\ansible_control.managed_nodes.pub
```

`.\operator\vps3\ansible_control.managed_nodes.pub` должен совпадать с `.\operator\ansible_control.managed_nodes.pub`.
Private keys сохраняются только в ignored `operator/`, не в git.

После успешного bootstrap runner очистит `root_password` в строке control alias локального `.\operator\nodes.csv`.

Во время шага `run remote bootstrap` runner должен показать строку:

```text
AI Service Platform VPS bootstrap
```

Если после копирования файлов долго нет вывода, проверь PuTTY/plink host key
cache, SSH banner/session prompts и правильность временного root password.

Если файл уже существует, runner остановится и попросит использовать `-Force`, чтобы не перезаписать ключ случайно:

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -Alias vps3 `
  -Force
```

Если нужен другой путь для public key:

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -Alias vps3 `
  -OutputAnsibleAuthorizedKeyFile .\operator\ansible_control.managed_nodes.pub
```

Если нужен другой base directory для всех operator-local ключей:

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -Alias vps3 `
  -OperatorDir .\operator `
  -Force
```

### WSL/Linux/macOS fallback

```bash
bash tools/bootstrap/bootstrap_from_unix.sh \
  --nodes-file ./operator/nodes.csv \
  --state-file ./operator/state.csv \
  --alias vps3 \
  --force
```

После успешного fresh bootstrap появятся или обновятся файлы:

```text
./operator/ansible_control.managed_nodes.pub
./operator/vps3/deploy_key
./operator/vps3/admin_key
./operator/vps3/ansible_control_key
./operator/vps3/ansible_control.managed_nodes.pub
```

После успешного bootstrap control node runner очистит `root_password` в строке control alias локального `./operator/nodes.csv`.

Если файл уже существует, runner остановится. Для осознанной перезаписи:

```bash
bash tools/bootstrap/bootstrap_from_unix.sh \
  --nodes-file ./operator/nodes.csv \
  --alias vps3 \
  --force
```

Если нужен другой путь для public key:

```bash
bash tools/bootstrap/bootstrap_from_unix.sh \
  --nodes-file ./operator/nodes.csv \
  --alias vps3 \
  --output-ansible-authorized-key-file ./operator/ansible_control.managed_nodes.pub
```

Если нужен другой base directory для всех operator-local ключей:

```bash
bash tools/bootstrap/bootstrap_from_unix.sh \
  --nodes-file ./operator/nodes.csv \
  --alias vps3 \
  --operator-dir ./operator \
  --force
```

## 4. Fallback: bootstrap VPS1/VPS2 как managed nodes

Managed VPS должны получить public key от control node сразу во время bootstrap. Если ключ не передан, `setup_vps.sh` остановится до установки пакетов, создания пользователей и каталогов.

### Windows

Для VPS1:

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -Alias vps1 `
  -AnsibleAuthorizedKeyFile .\operator\ansible_control.managed_nodes.pub
```

Для VPS2:

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -Alias vps2 `
  -AnsibleAuthorizedKeyFile .\operator\ansible_control.managed_nodes.pub
```

### WSL/Linux/macOS

Для VPS1:

```bash
bash tools/bootstrap/bootstrap_from_unix.sh \
  --nodes-file ./operator/nodes.csv \
  --alias vps1 \
  --ansible-authorized-key-file ./operator/ansible_control.managed_nodes.pub
```

Для VPS2:

```bash
bash tools/bootstrap/bootstrap_from_unix.sh \
  --nodes-file ./operator/nodes.csv \
  --alias vps2 \
  --ansible-authorized-key-file ./operator/ansible_control.managed_nodes.pub
```

Runner копирует на VPS временные файлы:

```text
/tmp/setup_vps.sh
/tmp/nodes.csv
/tmp/ansible_control.managed_nodes.pub
```

После успешного bootstrap runner удаляет эти временные файлы.
После успешного bootstrap runner также очищает `root_password` в строке соответствующего alias в локальном `./operator/nodes.csv`.
Если bootstrap завершился ошибкой, пароль остаётся на месте для повторного запуска.

После bootstrap `vps1` и `vps2` runner автоматически сохранит private keys в operator-local alias-папки:

```text
.\operator\vps1\deploy_key
.\operator\vps1\admin_key
.\operator\vps2\deploy_key
.\operator\vps2\admin_key
```

Для GitHub Environment `ai-retail-dev-preprod` нужен deploy key именно от `vps2`:

```text
.\operator\vps2\deploy_key
```

## 5. Проверить SSH-доступ Ansible с control node

Команды выполняются именно на control node.

```bash
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@<VPS1_PUBLIC_IP_OR_DNS> 'hostname && whoami'
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@<VPS2_PUBLIC_IP_OR_DNS> 'hostname && whoami'
```

`<VPS1_PUBLIC_IP_OR_DNS>` и `<VPS2_PUBLIC_IP_OR_DNS>` — placeholders. Замени их на реальные DNS или IP, например:

```bash
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@vps01.example.com 'hostname && whoami'
```

Ожидаемый результат:

```text
<hostname>
ansible
```

Если SSH спрашивает `Are you sure you want to continue connecting`, ответь `yes`. Это добавит host key в `known_hosts` пользователя `ansible` на control node.

Если подключение не работает, проверь:

- public key есть в `/home/ansible/.ssh/authorized_keys` на managed VPS;
- пользователь `ansible` существует на managed VPS;
- права на `/home/ansible/.ssh` и `authorized_keys` корректные;
- control node имеет сетевой доступ к SSH-порту VPS1/VPS2.

Recovery helper для уже подготовленной VPS:

```bash
sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash install_ansible_authorized_key.sh
```

`install_ansible_authorized_key.sh` — аварийный способ доустановить ключ, а не основной bootstrap-путь.

## 6. Подготовить inventory на control node

Основной Windows-путь — автоматически через `bootstrap_all_from_windows.ps1`.
Во время bootstrap control node operator runner уже копирует sanitized `nodes.csv` без root passwords,
переводит control alias в `local/local`, кладёт helper-скрипты в `/opt/ai-service-platform/tools/bootstrap`
и генерирует `/opt/ai-service-platform/inventory.ini`.

После bootstrap control node должны быть готовы:

```text
/opt/ai-service-platform/operator/nodes.csv
/opt/ai-service-platform/inventory.ini
```

Важно: при bootstrap только control node проверка `ansible ping` ещё не запускается, потому что `vps1`
и `vps2` могут быть ещё не готовы.

После bootstrap `vps1`/`vps2` или после добавления нового VPS сначала синхронизируй актуальный
operator-local `nodes.csv` на control node. Sync-скрипт отправляет только sanitized CSV без root passwords,
запускает `prepare_vps3_inventory.sh` на control node и удаляет временный remote-файл.

Windows:

```powershell
.\tools\bootstrap\sync_nodes_to_vps3.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv
```

WSL/Linux/macOS:

```bash
bash tools/bootstrap/sync_nodes_to_vps3.sh \
  --nodes-file ./operator/nodes.csv \
  --state-file ./operator/state.csv \
  --ssh-key-file ./operator/vps3/admin_key
```

По умолчанию sync ищет control node по role `orchestration`, строит key path как `.\operator\<control-alias>\admin_key` и подключается как `useradmin`. Если нужен другой пользователь:

```powershell
.\tools\bootstrap\sync_nodes_to_vps3.ps1 `
  -NodesFile .\operator\nodes.csv `
  -SshUser useradmin `
  -SshKeyFile .\operator\vps3\admin_key
```

После sync запусти проверку на control node:

```bash
cd /opt/ai-service-platform
ansible all -i inventory.ini -m ping
```

Fallback, если нужно вручную пересоздать sanitized CSV и inventory на control node без sync-скрипта:

1. Передай operator-local `nodes.csv` на control node во временный файл:

```text
/tmp/nodes.csv
```

2. Выполни:

```bash
cd /opt/ai-service-platform
sudo bash tools/bootstrap/prepare_vps3_inventory.sh \
  --source-nodes-file /tmp/nodes.csv
```

Real CSV для дальнейшего управления хранится на control node вне git:

```text
/opt/ai-service-platform/operator/nodes.csv
/opt/ai-service-platform/operator/state.csv
```

Последняя колонка `root_password` в этом файле должна быть пустой. Скрипт делает это автоматически.
Даже если оператор случайно передал файл с паролями, `prepare_vps3_inventory.sh` запишет на VPS3 только sanitized copy.

Если Ansible запускается прямо на control node, строку текущего control alias в этом control-local CSV можно заменить на local connection:

```csv
vps3,local,local,management,management+monitoring+orchestration+vpn-edge,
```

Для operator-local bootstrap CSV на Windows/WSL так делать нельзя: там нужен реальный endpoint control node.
Скрипт меняет control alias на `local/local` только в sanitized копии на control node.

Fallback: сгенерировать inventory вручную:

```bash
cd /opt/ai-service-platform
sudo bash tools/bootstrap/create_inventory.sh \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --include vps1,vps2,vps3 \
  --check
```

Если проверка прошла, создать inventory:

```bash
sudo bash tools/bootstrap/create_inventory.sh \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --include vps1,vps2,vps3
```

По умолчанию будет создан:

```text
/opt/ai-service-platform/inventory.ini
```

Real `inventory.ini` не коммитится.

## 7. Запустить Ansible как отдельный этап

После bootstrap и проверки SSH можно запускать Ansible с control node:

```bash
cd /opt/ai-service-platform
ansible all -i inventory.ini -m ping
```

Ожидаемый смысл результата: managed VPS отвечают `pong`.

Затем, когда playbooks готовы:

```bash
ansible-playbook -i inventory.ini infra/ansible/site.yml --check
ansible-playbook -i inventory.ini infra/ansible/site.yml
```

Первый запуск с `--check` нужен, чтобы увидеть план изменений без применения.

## 8. Что не делает bootstrap

Bootstrap не настраивает всю ОС и не деплоит приложения. Он не должен:

- запускать `ansible-playbook`;
- ставить и конфигурировать Docker как финальное состояние;
- настраивать SoftEther/HAProxy/Nginx;
- раскатывать `AromaFlowAI` или `AI_E_Retail`;
- включать постоянный password-login.

Все это остается задачей Ansible и следующих operational steps.

После этого шага продолжается infrastructure preparation: сначала настраивается GitHub deploy-access/predeploy-check
для `ai-retail-dev-preprod`, затем первым настоящим platform service устанавливается SoftEther/VPN.
Product `pull/up` и полноценный rollback остаются отдельными следующими этапами.
