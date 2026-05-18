# Step-by-step: VPS3 management bootstrap

Эта инструкция фиксирует правильный порядок первичной инициализации платформы:

1. Сначала поднимается `VPS3` как management/control node.
2. Затем `VPS1` и `VPS2` готовятся как managed nodes.
3. После этого Ansible с VPS3 доводит ОС до платформенного состояния.
4. GitHub Actions deploy-access к `ai-retail-dev/preprod` остаётся временным удобным мостом, а не главным способом управления инфраструктурой.

## 1. Bootstrap VPS3

Подключись к VPS3 как `root` или пользователь с `sudo`, положи туда скрипт:

```text
tools/bootstrap/setup_vps.sh
```

Запусти:

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

После bootstrap VPS3 возьми public key из блока:

```text
=== Ansible control public key for VPS1/VPS2 authorized_keys ===
```

Добавь этот public key на VPS1 и VPS2 в `authorized_keys` пользователя, через которого VPS3 будет управлять нодами.

Рекомендуемый минимальный вариант:

```bash
sudo -u ansible mkdir -p /home/ansible/.ssh
sudo -u ansible nano /home/ansible/.ssh/authorized_keys
sudo chmod 700 /home/ansible/.ssh
sudo chmod 600 /home/ansible/.ssh/authorized_keys
```

Если на managed node нет пользователя `ansible`, создай его или повторно запусти bootstrap с нужным `ANSIBLE_USER`.

## 4. Подготовить inventory/vault вне репозитория

Реальный `inventory.ini` с IP и ключами не коммитится.

Используй пример:

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

Secrets для Ansible хранятся в Ansible Vault, SOPS или другом encrypted source, но не в repo.

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
