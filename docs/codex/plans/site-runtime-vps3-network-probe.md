# Проверка сетевого anchor Site Runtime на vps3

## Граница этапа

Это первый implementation gate для `site_runtime`. Он проверяет только общий
network namespace, постоянный маршрут контейнера и TCP-доступность endpoint
PostgreSQL. Он не создаёт продуктовую базу, не загружает image продукта, не
запускает migrations, Redis/nginx и не публикует host port или edge route.

Probe намеренно ограничен `vps3` и использует существующий placement row
`platform_router`. Он не добавляет desired state `site_runtime`.

## Предварительные условия

- Локальный SoftEther secret `pg-vps4-vps8` содержит `client_users.vps3` с
  пользователем `p2p_app_vps3`.
- `links.yml` сопоставляет этот client с `10.88.48.3`.
- Config platform-router содержит адреса vps3 и policy
  `172.31.3.0/24 -> 172.30.8.10:5432`.
- В `state.csv` vps3 указан как candidate `platform_router`.
- Запущенный `platform-router` использует timestamped image
  `ai-service-platform/platform-router:*`; probe повторно использует этот exact
  image и ничего не pull/build на vps3.
- До запуска топология PostgreSQL исправна; standby не переинициализируется.

## Последовательность для оператора

Длительные remote-команды выполняет оператор. Узлы обрабатываются по одному;
при первой ошибке проверки процесс останавливается.

1. Проверить изменение на серверной стороне:

   ```powershell
   .\tools\services\service.ps1 platform_router plan -Limit vps8
   ```

2. Выполнить apply только для vps8, чтобы существующий SoftEther hub получил пользователя vps3:

   ```powershell
   .\tools\services\service_remote.ps1 platform_router apply -Limit vps8
   ```

3. Убедиться, что vps4/vps9 остаются подключёнными, а обе standby PostgreSQL
   продолжают streaming. При регрессии любого пути остановиться.

4. Проверить и применить только client/router vps3:

   ```powershell
   .\tools\services\service.ps1 platform_router plan -Limit vps3
   .\tools\services\service_remote.ps1 platform_router apply -Limit vps3
   ```

5. Сначала запустить probe в Ansible check mode:

   ```powershell
   .\tools\services\service_remote.ps1 site_runtime probe -Limit vps3 -Check
   ```

6. Запустить узкий probe:

   ```powershell
   .\tools\services\service_remote.ps1 site_runtime probe -Limit vps3
   ```

## Критерии приёмки

Probe должен подтвердить:

- адрес anchor `172.31.3.10` в `ai_service_app_vps3`;
- маршрут `172.30.8.10/32 via 172.31.3.2`;
- TCP-соединение с `172.30.8.10:5432` из контейнера с
  `network_mode: service:anchor`;
- тот же маршрут и TCP-результат после рестарта anchor;
- отсутствие host port bindings;
- `NET_ADMIN` только у anchor, но не у TCP probe;
- неизменную primary/standby-топологию PostgreSQL и streaming state.

Успешный probe оставляет anchor запущенным с `restart: unless-stopped` в
`/opt/ai-service-platform/site_runtime-network-probe`. До проверки и приёмки
этого gate нельзя переходить к продуктовой базе или generic runtime.

## Узкая очистка

Очистка не входит в обычную приёмку. Если probe нужно удалить, останавливается
только его compose project на vps3; platform_router, SoftEther и PostgreSQL не
изменяются:

```bash
docker compose \
  -f /opt/ai-service-platform/site_runtime-network-probe/docker-compose.yml \
  down
```

Не добавлять `--volumes`: probe не определяет named volumes.
