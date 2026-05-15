# Step-by-step: GitHub Environment ai-retail-dev-preprod

Эта инструкция нужна для первого безопасного predeploy-check сценария:

- instance: `ai-retail-dev`
- environment: `preprod`
- target: `VPS2`
- workflow: `.github/workflows/deploy.yml`

Текущий workflow пока не запускает `docker compose pull/up`. Он подключается по SSH, копирует compose-bundle на VPS2 и выполняет `docker compose config`.

## 1. Открыть настройки репозитория

1. Открой GitHub repo `airiga1897/AI_Service_Platform`.
2. Перейди в **Settings**.
3. В левом меню открой **Environments**.
4. Нажми **New environment**.

## 2. Создать Environment

1. В поле имени введи строго:

   ```text
   ai-retail-dev-preprod
   ```

2. Нажми **Configure environment**.

Важно: имя должно совпадать с workflow:

```yaml
environment:
  name: ai-retail-dev-preprod
```

## 3. Добавить Environment secrets

Внутри Environment открой раздел **Environment secrets** и добавь:

| Secret | Что хранит |
| --- | --- |
| `SSH_HOST` | IP или DNS VPS2 |
| `SSH_USER` | Linux-пользователь для деплоя |
| `SSH_KEY` | private SSH key для подключения |
| `SSH_PORT` | опционально, если SSH не на `22` |

`SSH_KEY` вставлять полностью, включая строки:

```text
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----
```

Не добавляй эти значения в repo files, `.env`, docs или issue comments.

## 4. Рекомендуемые protection rules

Для первого запуска желательно включить ручное подтверждение:

1. В Environment открой **Deployment protection rules**.
2. Включи **Required reviewers**, если доступно на текущем GitHub plan.
3. Добавь себя как reviewer.
4. Сохрани настройки.

Если required reviewers недоступны, можно оставить без protection rules, но первый запуск нужно делать вручную и внимательно смотреть logs.

## 5. Подготовить VPS2

На VPS2 должны быть:

1. Docker установлен.
2. Docker Compose plugin доступен командой:

   ```bash
   docker compose version
   ```

3. Пользователь `SSH_USER` должен иметь право запускать Docker.
4. Должен существовать runtime env-файл:

   ```bash
   /opt/stacks/ai-retail-dev-preprod/.env.ai-retail.dev
   ```

5. Каталог можно создать заранее:

   ```bash
   sudo mkdir -p /opt/stacks/ai-retail-dev-preprod
   sudo chown -R <SSH_USER>:<SSH_USER> /opt/stacks/ai-retail-dev-preprod
   ```

В `.env.ai-retail.dev` должны быть реальные переменные приложения. Их нельзя хранить в репозитории.

## 6. Проверить image ref локально

Перед запуском workflow проверь image ref:

```bash
python tools/deploy/preflight.py \
  --instance ai-retail-dev \
  --environment preprod \
  --image-ref 'ghcr.io/airiga1897/ai_e_retail:<40-char-sha>'
```

Ожидаемый результат: JSON с `vps: VPS2`, `deploy_dir: /opt/stacks/ai-retail-dev-preprod` и `env_file: .env.ai-retail.dev`.

## 7. Запустить GitHub Actions Deploy

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

## 8. Проверить успешный результат

В логах job `deploy` должно быть:

```text
Remote predeploy passed: compose bundle uploaded and docker compose config succeeded.
```

На VPS2 должны появиться файлы:

```bash
/opt/stacks/ai-retail-dev-preprod/docker-compose.yml
/opt/stacks/ai-retail-dev-preprod/.env.deploy
```

Проверить вручную на VPS2:

```bash
cd /opt/stacks/ai-retail-dev-preprod
docker compose --env-file .env.deploy -f docker-compose.yml config
```

## 9. Что делать при ошибках

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

## 10. Важное ограничение

Этот шаг не запускает контейнеры и не делает реальный rollout. Он только проверяет:

- GitHub Environment secrets;
- SSH-доступ;
- наличие runtime env-файла;
- валидность compose-конфига на VPS2.

Реальный `docker compose pull/up` включается отдельным следующим шагом.
