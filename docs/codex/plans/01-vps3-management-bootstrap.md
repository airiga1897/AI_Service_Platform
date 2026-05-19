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

Для пользователей `useradmin`, `depuser` и `ansible` пароль не используется. Bootstrap явно блокирует password-login для всех трёх; доступ должен идти только по SSH key.

Private keys нельзя сохранять в репозиторий, docs, issues или chat logs.

## 2. Bootstrap VPS1 и VPS2 как managed nodes

Для `vps1-prod` и `vps2-preprod` public key VPS3 обязателен сразу при запуске bootstrap. Если не передать `ANSIBLE_AUTHORIZED_KEY_FILE` или `ANSIBLE_AUTHORIZED_KEY`, скрипт остановится до установки пакетов, создания пользователей и каталогов.

С VPS3 скопируй на VPS1/VPS2 два файла:

```text
setup_vps.sh
ansible_control.managed_nodes.pub
```

`ansible_control.managed_nodes.pub` — это файл public key с VPS3:

```text
/home/ansible/.ssh/ansible_control.managed_nodes.pub
```

На managed VPS его удобно положить сюда:

```text
/tmp/ansible_control.managed_nodes.pub
```

На VPS1 запусти:

```bash
sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash setup_vps.sh vps1-prod
```

На VPS2 запусти:

```bash
sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash setup_vps.sh vps2-preprod
```

Эти targets готовят базовых пользователей, каталоги, пользователя `ansible`, добавляют public key VPS3 в `/home/ansible/.ssh/authorized_keys` и блокируют password-login для `useradmin`, `depuser`, `ansible`.

После успешного bootstrap временный public key файл можно удалить с VPS1/VPS2:

```bash
rm -f /tmp/ansible_control.managed_nodes.pub
```

Если удобнее передать ключ строкой, bootstrap также поддерживает переменную `ANSIBLE_AUTHORIZED_KEY`:

```bash
sudo ANSIBLE_AUTHORIZED_KEY='<PASTE_FULL_PUBLIC_KEY_FROM_VPS3_FILE_OR_OUTPUT>' bash setup_vps.sh vps1-prod
sudo ANSIBLE_AUTHORIZED_KEY='<PASTE_FULL_PUBLIC_KEY_FROM_VPS3_FILE_OR_OUTPUT>' bash setup_vps.sh vps2-preprod
```

## 3. Проверить Ansible SSH-доступ с VPS3

Цель этого шага: убедиться, что VPS3 подключается к VPS1 и VPS2 по SSH от имени пользователя `ansible`, чтобы все дальнейшие настройки выполнялись Ansible-плейбуками с management-ноды.

Public key VPS3 можно посмотреть на VPS3:

```bash
sudo -u ansible cat /home/ansible/.ssh/ansible_control.managed_nodes.pub
```

Тот же key был напечатан bootstrap-скриптом в блоке:

```text
=== Ansible control public key for VPS1/VPS2 authorized_keys ===
```

Если VPS1/VPS2 были bootstrap-нуты старой версией скрипта без `ANSIBLE_AUTHORIZED_KEY_FILE`, используй отдельный helper-скрипт как recovery.

Команда донастройки на VPS1:

```bash
sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash install_ansible_authorized_key.sh
```

Та же донастройка на VPS2:

```bash
sudo ANSIBLE_AUTHORIZED_KEY_FILE=/tmp/ansible_control.managed_nodes.pub bash install_ansible_authorized_key.sh
```

`install_ansible_authorized_key.sh` лежит в repo:

```text
tools/bootstrap/install_ansible_authorized_key.sh
```

Helper также поддерживает строковый режим:

```bash
sudo ANSIBLE_AUTHORIZED_KEY='<PASTE_FULL_PUBLIC_KEY_FROM_VPS3_FILE_OR_OUTPUT>' bash install_ansible_authorized_key.sh
```

После bootstrap или recovery вернись на VPS3 и проверь подключение к VPS1/VPS2. Команды выполняются именно с VPS3:

```bash
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@<VPS1_PUBLIC_IP_OR_DNS> 'hostname && whoami'
sudo -u ansible ssh -i /home/ansible/.ssh/ansible_control ansible@<VPS2_PUBLIC_IP_OR_DNS> 'hostname && whoami'
```

`<VPS1_PUBLIC_IP_OR_DNS>` и `<VPS2_PUBLIC_IP_OR_DNS>` — placeholder-ы. Замени их на реальный публичный IP или DNS, например `vps02.example.com`.

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

Коротко про пароли: у `ansible` на VPS1/VPS2/VPS3 не должно быть рабочего пароля для SSH. Это локальные Linux-пользователи с одинаковым именем, но управление идёт через SSH key от VPS3. Для privilege escalation используется sudo rule `NOPASSWD`, а не пароль пользователя.

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
<VPS1_PUBLIC_IP_OR_DNS> ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control

[backup]
<VPS2_PUBLIC_IP_OR_DNS> ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control

[management]
<VPS3_PUBLIC_IP_OR_DNS> ansible_user=ansible ansible_ssh_private_key_file=/home/ansible/.ssh/ansible_control
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
