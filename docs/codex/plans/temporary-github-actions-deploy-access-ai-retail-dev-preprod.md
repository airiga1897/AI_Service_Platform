# Step-by-step: GitHub Environment ai-retail-dev-preprod

Эта инструкция нужна для первого безопасного predeploy-check сценария:

- instance: `ai-retail-dev`
- environment: `preprod`
- target: `VPS2`
- workflow: `.github/workflows/deploy.yml`

Текущий workflow пока не запускает `docker compose pull/up`. Он подключается по SSH, копирует compose-bundle на VPS2 и выполняет `docker compose config`.

Важно: это **временный deploy-access для GitHub Actions**, а не основной способ управления инфраструктурой. Нормальная platform-последовательность начинается с `VPS3` как Ansible control node; см. [`01-vps3-management-bootstrap.md`](01-vps3-management-bootstrap.md).

Главная идея: VPS и доступы не настраиваются руками. Сначала на VPS2 запускается bootstrap-скрипт в target `ai-retail-dev-preprod`, он создаёт пользователей, SSH-ключи, каталог деплоя и выводит готовые значения `SSH_HOST`, `SSH_USER`, `SSH_PORT`, `SSH_KEY`. Ручным остаётся только безопасный перенос этих секретов в GitHub Environment или эквивалентная команда через GitHub CLI.

## 1. Проверить, что VPS3 уже bootstrap/control-ready

Перед временным deploy-access на VPS2 желательно сначала подготовить VPS3:

```bash
sudo bash setup_vps.sh vps3-management
```

VPS3 должен стать Ansible control node. После этого VPS2 можно bootstrap-ить как managed node или как временный deploy target.

## 2. Запустить временный deploy-access bootstrap на VPS2

Подключись к новой VPS2 как `root` или пользователь с `sudo` и запусти bootstrap-скрипт из репозитория. Это единственный обязательный операторский вход на пустую VPS; дальше состояние создаётся скриптом.

```text
tools/bootstrap/setup_vps.sh
```

Запусти:

```bash
sudo bash setup_vps.sh ai-retail-dev-preprod
```

По умолчанию скрипт создаёт:

| Параметр | Значение |
| --- | --- |
| GitHub Environment | `ai-retail-dev-preprod` |
| deploy user | `depuser` |
| admin user | `useradmin` |
| deploy dir | `/opt/stacks/ai-retail-dev-preprod` |
| runtime env file | `/opt/stacks/ai-retail-dev-preprod/.env.ai-retail.dev` |

Если нужны другие имена пользователей или SSH-порт, их можно задать перед запуском:

```bash
sudo DEPLOY_USER=depuser ADMIN_USER=useradmin SSH_PORT=22 bash setup_vps.sh ai-retail-dev-preprod
```

Target `ai-retail-dev-preprod` является alias для первого GitHub Actions predeploy-check. Для общей подготовки VPS2 как платформенной ноды используй:

```bash
sudo bash setup_vps.sh vps2-preprod
```

## 3. Сохранить значения, которые вывел bootstrap

В конце bootstrap выведет блок:

```text
GitHub Environment: ai-retail-dev-preprod
SSH_HOST=<detected_public_ip>
SSH_USER=depuser
SSH_PORT=22
SSH_KEY=(copy private deploy key below)
```

Ниже будет напечатан приватный deploy key между маркерами:

```text
--- BEGIN SSH_KEY ---
...
--- END SSH_KEY ---
```

Сохрани эти значения только на время переноса в GitHub Environment. Приватный ключ показывается только для этого шага. Не сохраняй его в repo files, `.env`, docs, issues или chat logs.

## 4. Создать Environment через GitHub CLI

Основной путь — создать Environment и secrets командой, а не кликами в UI. На машине, где установлен и авторизован `gh`, выполни:

```bash
gh api \
  --method PUT \
  repos/airiga1897/AI_Service_Platform/environments/ai-retail-dev-preprod
```

Затем добавь secrets из вывода bootstrap:

```bash
gh secret set SSH_HOST --env ai-retail-dev-preprod --repo airiga1897/AI_Service_Platform
gh secret set SSH_USER --env ai-retail-dev-preprod --repo airiga1897/AI_Service_Platform
gh secret set SSH_PORT --env ai-retail-dev-preprod --repo airiga1897/AI_Service_Platform
gh secret set SSH_KEY --env ai-retail-dev-preprod --repo airiga1897/AI_Service_Platform
```

`gh` запросит значения интерактивно. Для `SSH_KEY` вставь приватный deploy key полностью, включая строки:

```text
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----
```

Важно: добавляй эти значения именно в **Environment secrets** окружения `ai-retail-dev-preprod`, а не в repository-level secrets.

## 5. UI fallback для Environment

Если GitHub CLI недоступен, можно сделать то же самое через UI:

1. Открой GitHub repo `airiga1897/AI_Service_Platform`.
2. Перейди в **Settings**.
3. В левом меню открой **Environments**.
4. Нажми **New environment**.
5. В поле имени введи строго:

   ```text
   ai-retail-dev-preprod
   ```

6. Нажми **Configure environment**.

Важно: имя должно совпадать с workflow:

```yaml
environment:
  name: ai-retail-dev-preprod
```

## 6. UI fallback для Environment secrets

Внутри Environment открой раздел **Environment secrets** и добавь значения, которые вывел bootstrap:

| Secret | Откуда взять |
| --- | --- |
| `SSH_HOST` | строка `SSH_HOST=<detected_public_ip>` |
| `SSH_USER` | строка `SSH_USER=depuser` |
| `SSH_KEY` | приватный ключ из блока `BEGIN SSH_KEY` / `END SSH_KEY` |
| `SSH_PORT` | строка `SSH_PORT=22`, если SSH не на стандартном порту или хочешь зафиксировать порт явно |

`SSH_KEY` вставлять полностью, включая строки:

```text
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----
```

Это fallback к CLI-командам из шага 4. В обоих вариантах секреты не должны попадать в repository-level secrets, repo files, `.env`, docs или issue comments.

## 7. Рекомендуемые protection rules

Для первого запуска желательно включить ручное подтверждение:

1. В Environment открой **Deployment protection rules**.
2. Включи **Required reviewers**, если доступно на текущем GitHub plan.
3. Добавь себя как reviewer.
4. Сохрани настройки.

Если required reviewers недоступны, можно оставить без protection rules, но первый запуск нужно делать вручную и внимательно смотреть logs.

## 8. Дозаполнить runtime env-файл на VPS2

Bootstrap создаёт placeholder:

```bash
/opt/stacks/ai-retail-dev-preprod/.env.ai-retail.dev
```

В этот файл нужно внести реальные переменные приложения на VPS2. На первом этапе это может сделать оператор, но правильное целевое состояние — заполнять файл из Ansible Vault/SOPS или другого секретного хранилища вне repo. Значения нельзя хранить в репозитории.

Минимальная контрольная проверка:

```bash
sudo ls -la /opt/stacks/ai-retail-dev-preprod
sudo test -f /opt/stacks/ai-retail-dev-preprod/.env.ai-retail.dev
```

## 9. Проверить готовность Docker

Текущий deploy-access bootstrap готовит пользователей, ключи и каталог, но полноценный provisioning ОС остаётся за Ansible с VPS3.

Перед predeploy-check на VPS2 должен работать Docker Compose plugin:

```bash
docker compose version
```

Если команды нет, сначала установи Docker через Ansible `docker` role или отдельный provisioning-шаг.

## 10. Проверить image ref локально

Перед запуском workflow проверь image ref:

```bash
python tools/deploy/preflight.py \
  --instance ai-retail-dev \
  --environment preprod \
  --image-ref 'ghcr.io/airiga1897/ai_e_retail:<40-char-sha>'
```

Ожидаемый результат: JSON с `vps: VPS2`, `deploy_dir: /opt/stacks/ai-retail-dev-preprod` и `env_file: .env.ai-retail.dev`.

## 11. Запустить GitHub Actions Deploy

1. Открой **Actions**.
2. Выбери workflow **Deploy**.
3. Нажми **Run workflow**.
4. Заполни inputs:

   ```text
   instance = ai-retail-dev
   environment = preprod
   image_ref = ghcr.io/airiga1897/ai_e_retail:<40-char-sha>
   ```

5. Запусти workflow.
6. Если включены required reviewers, подтверди deployment.

## 12. Проверить успешный результат

В логах job `deploy` должно быть:

```text
Remote predeploy passed: compose bundle uploaded and docker compose config succeeded.
```

На VPS2 должны появиться файлы:

```bash
/opt/stacks/ai-retail-dev-preprod/docker-compose.yml
/opt/stacks/ai-retail-dev-preprod/.env.deploy
```

Контрольная команда на VPS2:

```bash
cd /opt/stacks/ai-retail-dev-preprod
docker compose --env-file .env.deploy -f docker-compose.yml config
```

## 13. Что делать при ошибках

Если workflow пишет, что secrets пустые:

- проверь, что secrets добавлены именно в Environment `ai-retail-dev-preprod`;
- проверь имена: `SSH_HOST`, `SSH_USER`, `SSH_KEY`;
- если SSH не на `22`, добавь `SSH_PORT`.

Если SSH подключение падает:

- проверь IP/DNS в `SSH_HOST`;
- проверь пользователя в `SSH_USER`;
- проверь, что public key добавлен в `~/.ssh/authorized_keys` на VPS2;
- проверь firewall/security group.

Если падает `docker compose config`:

- проверь, что установлен Docker Compose plugin;
- проверь наличие `/opt/stacks/ai-retail-dev-preprod/.env.ai-retail.dev`;
- проверь права пользователя на каталог `/opt/stacks/ai-retail-dev-preprod`.

## 14. Важное ограничение

Этот шаг не запускает контейнеры и не делает реальный rollout. Он только проверяет:

- bootstrap-generated GitHub Environment secrets;
- SSH-доступ;
- наличие runtime env-файла;
- валидность compose-конфига на VPS2.

Реальный `docker compose pull/up` включается отдельным следующим шагом.
