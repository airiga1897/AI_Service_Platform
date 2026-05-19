# Step-by-step: VPS3 management bootstrap

Эта инструкция фиксирует правильный порядок первичной инициализации платформы:

1. Сначала с операторской машины bootstrap-ится `vps3` как management/control node.
2. Runner автоматически сохраняет Ansible control public key в `./operator/ansible_control.managed_nodes.pub`.
3. Затем `vps1` и `vps2` bootstrap-ятся как managed nodes с этим public key.
4. Только после bootstrap всех VPS запускается отдельный Ansible-этап с VPS3.

Важно: `vps1`, `vps2`, `vps3` здесь — короткие operator aliases текущей схемы, а не настоящие platform roles. Обязанности узла задаются в CSV-колонке `roles`.

Bootstrap и Ansible не смешиваются:

| Этап | Что делает |
| --- | --- |
| Bootstrap | Пользователи, SSH keys, базовые sudo-права, каталоги, запрет root SSH |
| Ansible | Docker, firewall, fail2ban, SoftEther, edge, monitoring, backup, platform tooling |

Bootstrap runners не запускают `ansible-playbook`.

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

`root_password` используется только runner-ом для первого входа на голую VPS. На VPS копируется sanitized CSV без root password. Постоянный вход по паролю не включается.

Безопасный template без реальных адресов и паролей хранится здесь:

```text
infra/ansible/nodes.example.csv
```

Real `./operator/nodes.csv` не коммитится.

## 2. Bootstrap VPS3

VPS3 — текущий management/control node. На нем bootstrap создаёт пользователя `ansible`, private key:

```text
/home/ansible/.ssh/ansible_control
```

и public key для managed nodes:

```text
/home/ansible/.ssh/ansible_control.managed_nodes.pub
```

Private key остается только на VPS3. Public key runner автоматически скачивает на операторскую машину.

### Windows

```powershell
.\tools\bootstrap\bootstrap_from_windows.ps1 `
  -NodesFile .\operator\nodes.csv `
  -Alias vps3
```

После успешного выполнения появится файл:

```text
.\operator\ansible_control.managed_nodes.pub
```

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

### WSL/Linux/macOS

```bash
bash tools/bootstrap/bootstrap_from_unix.sh \
  --nodes-file ./operator/nodes.csv \
  --alias vps3
```

После успешного выполнения появится файл:

```text
./operator/ansible_control.managed_nodes.pub
```

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

## 3. Bootstrap VPS1/VPS2 как managed nodes

Managed VPS должны получить public key от VPS3 сразу во время bootstrap. Если ключ не передан, `setup_vps.sh` остановится до установки пакетов, создания пользователей и каталогов.

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

## 4. Проверить SSH-доступ Ansible с VPS3

Команды выполняются именно на VPS3.

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

Если SSH спрашивает `Are you sure you want to continue connecting`, ответь `yes`. Это добавит host key в `known_hosts` пользователя `ansible` на VPS3.

Если подключение не работает, проверь:

- public key есть в `/home/ansible/.ssh/authorized_keys` на managed VPS;
- пользователь `ansible` существует на managed VPS;
- права на `/home/ansible/.ssh` и `authorized_keys` корректные;
- VPS3 имеет сетевой доступ к SSH-порту VPS1/VPS2.

Recovery helper для уже подготовленной VPS:

```bash
sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash install_ansible_authorized_key.sh
```

`install_ansible_authorized_key.sh` — аварийный способ доустановить ключ, а не основной bootstrap-путь.

## 5. Подготовить inventory на VPS3

Real CSV для дальнейшего управления хранится на VPS3 вне git:

```text
/opt/ai-service-platform/operator/nodes.csv
```

Он может быть скопирован из operator-local `./operator/nodes.csv`, но без временных root passwords. Последняя колонка `root_password` должна быть пустой.

Сгенерировать inventory:

```bash
cd /opt/ai-service-platform
sudo bash tools/bootstrap/create_inventory.sh \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
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

## 6. Запустить Ansible как отдельный этап

После bootstrap и проверки SSH можно запускать Ansible с VPS3:

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

## 7. Что не делает bootstrap

Bootstrap не настраивает всю ОС и не деплоит приложения. Он не должен:

- запускать `ansible-playbook`;
- ставить и конфигурировать Docker как финальное состояние;
- настраивать SoftEther/HAProxy/Nginx;
- раскатывать `AromaFlowAI` или `AI_E_Retail`;
- включать постоянный password-login.

Все это остается задачей Ansible и следующих operational steps.
