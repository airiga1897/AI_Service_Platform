# Эксплуатационные runbook'и

Этот файл собирает короткие, проверенные процедуры для повседневной
работы с платформенным репозиторием. Раздел «Уже работающие процедуры»
покрывает то, что прямо сейчас исполняется в этом репозитории.
Раздел «Запланированные runbook'и» — список процедур, которые будут
добавлены, когда соответствующий код/деплой появятся.

Архитектурный контекст и обоснования — в [`adr/README.md`](adr/README.md).
Источник истины для контракта — [`../services.yml`](../services.yml).

---

## Уже работающие процедуры

### 1. Локальная проверка перед коммитом

**Когда применять:** перед каждым `git commit`/`git push`, после любой
правки `services.yml`, шаблонов рендера, валидатора или тестов.

**Предусловия:**
- установлен Python 3.11;
- установлены зависимости: `python3 -m pip install pyyaml jinja2`.

**Шаги:**
```bash
make check
```

Цель `make check` запускает по очереди:
1. `make validate` — `validate_services_yml.py --strict` (предупреждения
   валидатора трактуются как ошибки).
2. `make render-check` — `render_compose.py --stack all --check`
   (фейлится, если сгенерированные `infra/stacks/*/docker-compose.*.yml`
   разошлись с текущим `services.yml`).
3. `make test` — smoke-тесты `validate-services-yml`, `render-compose`,
   `healthcheck`.

**Признак успеха:** последняя строка вывода — `OK` от unittest и нулевой
exit-код. Те же проверки выполняет `.github/workflows/validate.yml` на
каждом PR/push.

**Что делать при ошибке:**
- ошибка валидатора → читать сообщение, править `services.yml`;
- расхождение `render-check` → перерендерить затронутый стек (см. п. 2);
- падение smoke-тестов → читать traceback, искать в
  `tools/<инструмент>/tests/`.

Подробности — в [`CI_CD.md`](CI_CD.md).

---

### 2. Перерендер стека после правки `services.yml`

**Когда применять:** после любой правки `services.yml`, которая
затрагивает `runtime_instances.<имя>` (порты, env-префиксы, тома,
healthcheck, контейнеры, образы).

**Предусловия:** `make check` не показывает ошибок валидатора;
`render-check` показывает дрейф.

**Шаги:**
```bash
# перерендер одного стека
python3 tools/render-compose/render_compose.py --stack <имя>

# или сразу всех
python3 tools/render-compose/render_compose.py --stack all
```

После рендера обязательно:
```bash
make check
```

**Признак успеха:** в `infra/stacks/<имя>/docker-compose.<имя>.yml`
видны ожидаемые изменения; `make render-check` не сообщает о дрейфе;
`make check` зелёный.

**Что делать при ошибке:**
- `RenderError: missing required field 'X'` → в `services.yml` для
  выбранного инстанса не хватает поля; добавить и повторить;
- `unknown project type 'Y'` → выбран `type:`, для которого нет
  шаблона в `tools/render-compose/templates/`. Добавить шаблон или
  поправить `type:`.

---

### 3. Прогон healthcheck в `local` / `preprod` / `prod`

**Когда применять:** для быстрой проверки «жив/не жив» сайтов в
выбранном окружении. В CI сетевые healthcheck'и не выполняются — их
запускают вручную с машины, у которой есть сетевой доступ к таргетам.

**Предусловия:**
- для `local` — сайты подняты и слушают на портах из
  `runtime_instances.*.local.backend_port`;
- для `preprod`/`prod` — DNS резолвится, маршрутизация edge на месте.

**Шаги:**
```bash
# все инстансы окружения
python3 tools/healthcheck/healthcheck.py --env preprod

# конкретный инстанс, JSON-отчёт
python3 tools/healthcheck/healthcheck.py --env prod \
    --instance aromaflow-work --json
```

CLI читает `services.yml`, формирует URL по `healthcheck.path`,
делает `GET` и сравнивает фактический статус с
`healthcheck.expected_status`.

**Признак успеха:** exit-код `0`. Все цели либо `ok`, либо `skipped`
(домен-плейсхолдер для нереализованных окружений).

**Exit-коды:**
- `0` — все цели `ok`/`skipped`;
- `1` — хотя бы одна цель `fail` (HTTP-статус не совпал, таймаут,
  отказ соединения, DNS-ошибка);
- `2` — ошибка конфигурации (нет такого инстанса/окружения, плохой
  таймаут, кривой `services.yml`).

**Что делать при `fail`:**
- HTTP не тот, что ожидается → проверить, на какой `expected_status`
  заявлен инстанс в `services.yml`;
- timeout/connection refused → проверить, что соответствующий
  стек/контейнер реально запущен и слушает на ожидаемом порту/домене.

Подробности — в [`../tools/healthcheck/README.md`](../tools/healthcheck/README.md).

---

### 4. Добавление нового рантайм-инстанса (site / telegram-bot)

**Когда применять:** когда в каталог рантаймов добавляется новый
сайт или Telegram-бот.

**Предусловия:**
- решено имя инстанса (`<project>-<role>`), env-префикс
  (`<PROJECT>_<ROLE>`), VPS-таргеты для `preprod`/`prod`;
- для типа `site` — выделены непересекающиеся `local.backend_port` /
  `local.frontend_port`, имя БД, набор томов;
- для типа `telegram-bot` — выделены домены вебхука для
  `preprod`/`prod`, токен (как ENV-переменная — не коммитить).

**Шаги:**
1. Открыть `services.yml`, секция `runtime_instances`. Добавить
   новый ключ по образцу существующего инстанса того же типа. Все
   обязательные поля диктуются `future_service_template.<тип>` в этом
   же файле.
2. Прогнать валидатор:
   ```bash
   make validate
   ```
   Поправить ошибки до зелёного.
3. Если тип — `site`: перерендерить стек:
   ```bash
   python3 tools/render-compose/render_compose.py --stack <новое-имя>
   ```
4. Прогнать `make check` — должен быть зелёный.
5. Добавить `host_vars`/`group_vars` для Ansible, если задеваются
   роли `backup_client`/`backup_server` (см.
   [`../infra/ansible/README.md`](../infra/ansible/README.md)).
6. Закоммитить `services.yml` и сгенерированный compose-файл одним
   PR. CI повторит `make check`.

**Признак успеха:** PR проходит CI; `make validate --strict` не
сообщает ни об ошибках, ни о варнингах для нового инстанса.

**Что важно не забыть:**
- `domains.local` для `site` начинается с `http://localhost:<port>`;
- `domains.preprod`/`prod` — голые хосты (без схемы/порта);
- `env.prefix` должен быть `<UPPER_INSTANCE_NAME_WITH_UNDERSCORES>`
  (валидатор это проверяет);
- `data.database` — уникальное имя в `snake_case`;
- порты `local.*_port` не должны пересекаться с другими инстансами и
  не должны попадать в Replit-reserved (5000).

Архитектурное обоснование расширяемости каталога — в
[ADR-0004](adr/0004-extensible-service-catalog.md).

---

## Деплой и откат (preflight + guarded rollout)

См. также [`DEPLOYMENT.md`](DEPLOYMENT.md) и [ADR-0006](adr/0006-deploy-from-immutable-image-refs.md).

### Деплой `ai-retail-dev` в preprod (VPS2)

1. Собрать и опубликовать образ в GHCR из `AI_E_Retail` (тег по коммит-SHA).
2. Локально проверить preflight:
   ```bash
   python tools/deploy/preflight.py \
     --instance ai-retail-dev \
     --environment preprod \
     --image-ref 'ghcr.io/airiga1897/ai_e_retail:<sha>'
   ```
3. В GitHub: **Actions → Deploy** → `workflow_dispatch` с `instance=ai-retail-dev`, `environment=preprod`, `image_ref=<полный ref>`.
4. Workflow прогонит `make check` и preflight; SSH predeploy-check выполнится только при настроенных secrets (`SSH_HOST`, `SSH_USER`, `SSH_KEY`) в Environment `ai-retail-dev-preprod`.
5. На VPS2 заранее должен быть runtime env-файл `/opt/stacks/ai-retail-dev-preprod/.env.ai-retail.dev`.
6. Текущий milestone проверяет `docker compose config`; реальный `pull/up` и healthcheck будут включены следующим отдельным шагом.

Другие `instance`/`environment` в этом milestone **отклоняются** workflow'ом намеренно.

### Откат `ai-retail-dev` preprod

1. Определить предыдущий неизменяемый `image_ref` (пока вручную; lookup deploy-state по git-тегам — follow-up).
2. **Actions → Rollback** → `to_ref=<предыдущий ref>` (обязателен; пустой `to_ref` завершит workflow с ошибкой).
3. Preflight проверит ref против `services.yml`; SSH-откат — re-deploy того же compose с предыдущим `IMAGE_REF`.

`ai-retail-mvp` заморожен: preflight/deploy отклонят refs вне паттерна `ai-retail-mvp-v*`.

---

## Windows/Codex Render-Edge Test Temp ACL

If `python -m unittest discover -s tools\render-edge\tests -t .` fails on
Windows with `PermissionError` under `%TEMP%` or `.tmp\pytest-temp`, treat it as
an environment ACL issue first. The tests create subdirectories with
`tempfile.mkdtemp()` and then write files such as `haproxy.cfg`, `bad.yml`, and
`sites\*.conf`.

Recommended retry:

```powershell
$tmp = Join-Path $PWD ".tmp\pytest-temp"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:TEMP = $tmp
$env:TMP = $tmp
python -m unittest discover -s tools\render-edge\tests -t .
```

If the same `PermissionError` persists inside Codex sandbox, rerun the check
outside the sandbox/ACL restriction before treating it as a `render-edge`
regression.

---

## VPN And Cascade Staged Rollout Verification

Use this after bootstrap or after changing VPN/cascade operator state. Long
PowerShell rollout commands are run manually by the operator.

1. Apply edge routes:
   ```powershell
   .\tools\services\rollout_from_state.ps1 `
     -NodesFile .\operator\nodes.csv `
     -StateFile .\operator\state.csv `
     -OnlyService edge_haproxy
   ```
2. Apply user VPN ingress:
   ```powershell
   .\tools\services\rollout_from_state.ps1 `
     -NodesFile .\operator\nodes.csv `
     -StateFile .\operator\state.csv `
     -OnlyService vpn_edge
   ```
3. Apply cascade transport only after VPN ingress is healthy:
   ```powershell
   .\tools\services\rollout_from_state.ps1 `
     -NodesFile .\operator\nodes.csv `
     -StateFile .\operator\state.csv `
     -OnlyService vpn_cascade
   ```
4. Verify active cascade links:
   ```powershell
   .\tools\services\check_vpn_cascade_links.ps1 -Json
   ```

Current verified status as of 2026-06-28:

- VPN ingress works on `vps1` through `vps7`.
- `vpn_cascade` is active on `vps1`, `vps2`, `vps3`, and `vps4`; `vps7` is
  staged with service/SNI surface and first test receiver link.
- Verified online cascade link is `vps2-to-vps3`. `vps1-to-vps3`,
  `vps4-to-vps3`, and staged `vps1-to-vps7` are acceptance-pending until
  ingress-side SoftEther connection objects are visible and online.
- The staged `vps1-to-vps7` link uses `cascade-vps7.mine-craft.su:443` via
  HAProxy SNI. Keep `vps7` in the same `service,vpn_cascade` batch as `vps1`.
- `vps5` remains an orchestration candidate and VPN ingress node; `vps7` remains
  a future `vps3` duplicate/standby candidate, currently tested only by
  `vps1-to-vps7`.

Stop before any broader rollout if any active cascade link reports `tcp=false`,
`online=false`, or a status other than `Connection Completed`.

---

## Manual Standby Promotion

Use this when a verified standby candidate must temporarily replace an active
role. These procedures are manual by design: edit local `operator/state.csv`,
run only the affected rollout, verify, then decide whether to continue. Do not
expect automatic failover or active-active traffic distribution.

Before any promotion:

- Confirm public TCP `443`, `992`, and `5555` for the target alias.
- Confirm SoftEther Manager access on `5555` from an allowlisted operator IP.
- Confirm the target alias has `edge_haproxy`, `vpn_edge`, and
  `edge_route,vpn_ingress` present.
- If cascade is involved, run:
  ```powershell
  .\tools\services\check_vpn_cascade_links.ps1 -Json
  ```

### Promote `vps5` To Active Orchestration

Change the orchestration row from:

```csv
platform_role,orchestration,orchestration,vps6,vps5,,present
```

to:

```csv
platform_role,orchestration,orchestration,vps5,,vps6,present
```

Then run the normal state rollout from the operator machine. The runner will
sync to the new active orchestration alias and future remote service commands
will use `vps5`.

### Stage `vps7` As Alternate Receiver For `vps3`

The first safe stage is a single receiver test: keep explicit
`service,vpn_cascade` and `edge_route,vpn_cascade` rows for `vps7`, keep
`cascade-vps7.mine-craft.su` SNI in `operator/haproxy/routes.yml`, and add only
`vps1-to-vps7` to `cascade_topology` and
`operator/softether/cascade/secrets/lab-cascade.json`.

Do not add `vps7-to-vps3`: that would make `vps7` an ingress/transit toward
`vps3`, not a duplicate receiver for `vps3`.

Roll out in this order:

```powershell
.\tools\services\rollout_from_state.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -OnlyService edge_haproxy

.\tools\services\rollout_from_state.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -OnlyService vpn_cascade
```

Stop if the new `vps7` TCP, SNI, admin, or cascade-link checks fail.

After staged rollout, check only the public surface:

```powershell
Test-NetConnection cascade-vps7.mine-craft.su -Port 443
Test-NetConnection cascade-vps7.mine-craft.su -Port 5555
.\tools\services\check_vpn_cascade_links.ps1 -Json -OnlyActive
```

Expected active links are `vps1-to-vps3`, `vps2-to-vps3`, `vps4-to-vps3`, and
`vps1-to-vps7`; all four must report `online=true`. Do not add broader
`vps2-to-vps7` or `vps4-to-vps7` until the single `vps1-to-vps7` path is
stable.

Keep `vps7` in the same `service,vpn_cascade` row/batch as `vps1` while
`vps1-to-vps7` is active. The role prepares egress-side users before configuring
ingress-side links within one Ansible play; splitting `vps1` and `vps7` into
different rollout batches can make `vps1` try the link before `vps7` is ready.

If SoftEther Server Manager on `cascade-vps1` shows an empty Cascade Connections
list while `lab-cascade.json` contains `vps1-to-vps3` or `vps1-to-vps7`, rerun
`vpn_cascade` after the role version that verifies `CascadeGet` immediately
after `CascadeCreate` and after final configure. The acceptance condition is
that the connections are visible in Server Manager and
`check_vpn_cascade_links.ps1` reports all four links `online=true`.

Do not treat the connection name appearing in raw `vpncmd /IN` output as proof
that the object exists: SoftEther can echo the submitted `CascadeGet` command
before returning an error. The proof is `CascadeGet` exit code `0` plus a live
connection object in `vpn_server.config` or Server Manager.

For online checks, use the `Session Status` row from `CascadeStatusGet` as the
canonical status source. `Connection Completed (Session Established)` means the
cascade link is online; broad raw-output regex matching is only a fallback.

Retired cleanup must never delete a desired active link. Machine lists for
desired and retired cascade connections are passed as JSON, not YAML-indented
heredocs, and cleanup must fail before `CascadeDelete` if a candidate appears in
the desired set.

### Promote `vps1` Or `vps4` For `vps2` Edge Duties

Move only the affected `state.csv` rows. For example, if `minecraft` must move
from `vps2` to `vps4`, update the `edge_route,minecraft` active alias and keep
the VPN ingress rows unchanged. If route-specific HAProxy overrides are needed,
update `operator/haproxy/routes.yml` before rollout.

Roll out the affected service only:

```powershell
.\tools\services\rollout_from_state.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -OnlyService edge_haproxy
```

`vps1` and `vps4` already have active cascade links to `vps3`; those links do
not automatically move `minecraft` or any other public edge route from `vps2`.

## Запланированные runbook'и

Эти процедуры будут добавлены, когда появится соответствующий код или
автоматизация. До этого момента реальная эксплуатация выполняется
вручную с привлечением инженера.

- Ротация ENV-секретов и обновление `*_TOKEN`/`*_PASSWORD` на VPS.
- Восстановление БД из бэкапа (после стабилизации `backup_*` ролей).
- Восстановление SoftEther VPN из тома `softether_data` и резервных
  TLS-сертификатов (см. [`SOFTETHER_VPN.md`](SOFTETHER_VPN.md)).
- Failover VPS1 → VPS2 с использованием `failover.sh` /
  `failback.sh` из роли `backup_server`.
- Продление и валидация TLS-сертификатов (Nginx + Certbot, копия для
  SoftEther).
- Инспекция HAProxy/Nginx маршрутизации (после внедрения
  `tools/render-edge`).
- Инспекция SoftEther: маршрутизация, management-доступ,
  логи (`5555/tcp` allowlist, `softether_logs`).
