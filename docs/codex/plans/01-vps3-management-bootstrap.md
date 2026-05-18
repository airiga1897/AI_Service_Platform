# Step-by-step: VPS3 management bootstrap

Эта инструкция фиксирует правильный порядок первичной инициализации платформы:

1. Сначала поднимается `VPS3` как management/control node.
2. Затем `VPS1` и `VPS2` готовятся как managed nodes.
3. После этого Ansible с VPS3 доводит ОС до платформенного состояния.
4. GitHub Actions deploy-access к `ai-retail-dev/preprod` остаётся временным удобным мостом, а не главным способом управления инфраструктурой.

## 1. Bootstrap VPS3

Подключись к VPS3 как `root` или пользователь с `sudo` и запусти bootstrap-скрипт. Это не ручная настройка ОС: оператор только доставляет и запускает entrypoint, а пользователи, ключи, каталоги и базовые ограничения создаются скриптом.

Скрипт из репозитория:

```text
tools/bootstrap/setup_vps.sh
```

Команда запуска на VPS3:

```bash
sudo bash setup_vps.sh vps3-management
```

По умолчанию скрипт создаёт:

| Параметр | Значение |
| --- | --- |
| target | `vps3-management` |
| deploy user | `depuser` |
| admin user | `useradmin` |
| Ansible control user | `ansible` |
| platform dir | `/opt/ai-service-platform` |

Для target `vps3-management` bootstrap также ставит минимальные пакеты `git` и `ansible`, чтобы VPS3 могла стать control-нодой без ручной установки Ansible.

В конце скрипт выведет:

- admin private key для доступа оператора к VPS3;
- deploy private key для возможных будущих GitHub/Semaphore задач;
- Ansible control private key;
- Ansible control public key, который нужно добавить на VPS1/VPS2.

Private keys нельзя сохранять в репозиторий, docs, issues или chat logs.

## 2. Bootstrap VPS1 и VPS2 как managed nodes

На VPS1:

```bash
sudo bash setup_vps.sh vps1-prod
```

На VPS2:

```bash
sudo bash setup_vps.sh vps2-preprod
```

Эти targets готовят базовых пользователей и каталоги, но не делают VPS1/VPS2 control-нодами.

## 3. Добавить Ansible control public key

Цель этого шага: разрешить VPS3 подключаться к VPS1 и VPS2 по SSH от имени пользователя `ansible`, чтобы все дальнейшие настройки выполнялись Ansible-плейбуками с management-ноды.

После bootstrap VPS3 в выводе скрипта будет блок:

```text
=== Ansible control public key for VPS1/VPS2 authorized_keys ===
```

Сразу под этим заголовком будет одна строка public key. Она обычно начинается с `ssh-ed25519` или `ssh-rsa` и заканчивается комментарием вроде `ansible-control@vps3-management`.

Скопируй **всю строку целиком**. Это public key, его можно передавать на VPS1/VPS2. Private key из блока `BEGIN ANSIBLE CONTROL KEY` на VPS1/VPS2 не копируется.

На VPS1 и VPS2 после `sudo bash setup_vps.sh vps1-prod` / `sudo bash setup_vps.sh vps2-preprod` уже должен существовать пользователь `ansible` и файл:

```text
/home/ansible/.ssh/authorized_keys
```

Добавь public key VPS3 в этот файл на **каждой** managed node.

Команда на VPS1:

```bash
ANSIBLE_CONTROL_PUBLIC_KEY='<PASTE_FULL_PUBLIC_KEY_FROM_VPS3_OUTPUT>'

sudo install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
printf '%s\n' "$ANSIBLE_CONTROL_PUBLIC_KEY" | sudo tee -a /home/ansible/.ssh/authorized_keys >/dev/null
sudo chown ansible:ansible /home/ansible/.ssh/authorized_keys
sudo chmod 600 /home/ansible/.ssh/authorized_keys
```

Та же команда на VPS2:

```bash
ANSIBLE_CONTROL_PUBLIC_KEY='<PASTE_FULL_PUBLIC_KEY_FROM_VPS3_OUTPUT>'

sudo install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
printf '%s\n' "$ANSIBLE_CONTROL_PUBLIC_KEY" | sudo tee -a /home/ansible/.ssh/authorized_keys >/dev/null
sudo chown ansible:ansible /home/ansible/.ssh/authorized_keys
sudo chmod 600 /home/ansible/.ssh/authorized_keys
```

После этого вернись на VPS3 и проверь подключение к VPS1/VPS2. Команды выполняются именно с VPS3:

```bash
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@VPS1_PUBLIC_IP 'hostname && whoami'
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@VPS2_PUBLIC_IP 'hostname && whoami'
```

Ожидаемый результат:

```text
<hostname-vps1>
ansible
<hostname-vps2>
ansible
```

Если SSH спрашивает `Are you sure you want to continue connecting`, ответь `yes`. Это добавит host key в `known_hosts` пользователя `ansible` на VPS3.

Если подключение не работает:

- проверь, что public key скопирован одной строкой без переносов внутри ключа;
- проверь, что ключ добавлен именно в `/home/ansible/.ssh/authorized_keys`;
- проверь права:

```bash
sudo ls -ld /home/ansible /home/ansible/.ssh
sudo ls -l /home/ansible/.ssh/authorized_keys
sudo tail -n 5 /home/ansible/.ssh/authorized_keys
```

- проверь, что пользователь `ansible` существует:

```bash
id ansible
```

- проверь firewall/security group: VPS3 должен иметь доступ к SSH-порту VPS1/VPS2.

Если на managed node нет пользователя `ansible`, не создавай его руками как основной путь: повторно запусти bootstrap с нужным `ANSIBLE_USER`.

Целевое состояние на будущее: этот шаг должен стать полностью скриптовым. Например, bootstrap managed node сможет принимать public key через переменную окружения:

```bash
sudo ANSIBLE_AUTHORIZED_KEY='<PASTE_FULL_PUBLIC_KEY_FROM_VPS3_OUTPUT>' bash setup_vps.sh vps1-prod
sudo ANSIBLE_AUTHORIZED_KEY='<PASTE_FULL_PUBLIC_KEY_FROM_VPS3_OUTPUT>' bash setup_vps.sh vps2-preprod
```

Пока такой режим не реализован, добавление public key — единственный временный ручной мост между bootstrap VPS3 и запуском Ansible.

Когда доступ проверен, можно быстро проверить Ansible-связность с VPS3:

```bash
cd /opt/ai-service-platform
ansible all -i inventory.ini -m ping
```

Ожидаемый смысл результата: VPS1 и VPS2 отвечают `pong`.

Если `ansible all -m ping` ещё не готов, потому что реальный `inventory.ini` не создан, переходи к следующему шагу и сначала подготовь inventory.

## 4. Подготовить inventory/vault вне репозитория

Реальный `inventory.ini` с IP и ключами не коммитится.

Основной путь: сгенерировать реальный inventory из безопасного шаблона/секретного хранилища вне repo. Пример структуры хранится здесь:

```text
infra/ansible/inventory.example.ini
```

Минимальная идея:

```ini
[prod]
VPS1_PUBLIC_IP ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control

[backup]
VPS2_PUBLIC_IP ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control

[management]
VPS3_PUBLIC_IP ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control
```

Secrets для Ansible хранятся в Ansible Vault, SOPS или другом encrypted source, но не в repo. Если на раннем этапе inventory собирается вручную, это временный операторский артефакт вне репозитория, а не часть platform source of truth.

## 5. Запустить Ansible с VPS3

На VPS3 сначала положи или склонируй platform repo в `/opt/ai-service-platform`. Реальные credentials для доступа к GitHub не коммитятся.

После этого:

```bash
cd /opt/ai-service-platform
ansible-playbook -i inventory.ini infra/ansible/site.yml --check
ansible-playbook -i inventory.ini infra/ansible/site.yml
```

Первый запуск с `--check` нужен, чтобы увидеть потенциальные изменения без применения.

## 6. Связь с GitHub Environment `ai-retail-dev-preprod`

GitHub Environment `ai-retail-dev-preprod` нужен для первого predeploy-check на VPS2:

```text
ai-retail-dev -> preprod -> VPS2
```

Он не заменяет Ansible management. В дальнейшем GitHub Actions может:

- напрямую выполнять ограниченный predeploy-check на VPS2;
- или триггерить VPS3/Semaphore, чтобы вся инфраструктурная логика оставалась на management node.

## 7. Важное ограничение

Bootstrap не является полной настройкой ОС. Он только создаёт безопасную точку входа:

- пользователи;
- SSH keys;
- базовые sudo-права;
- первичные каталоги;
- запрет root SSH.

Полная настройка ОС: Docker, firewall, fail2ban, monitoring, backup, management tooling и будущий SoftEther edge — задача Ansible.
