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
3. Apply cascade transport only when desired state intentionally changes it.
   During the L2 freeze this removes/keeps absent the cascade runtime:
   ```powershell
   .\tools\services\rollout_from_state.ps1 `
     -NodesFile .\operator\nodes.csv `
     -StateFile .\operator\state.csv `
     -OnlyService vpn_cascade
   ```
4. Verify that there are no active cascade links:
   ```powershell
   .\tools\services\check_vpn_cascade_links.ps1 -Json
   ```

Current verified status as of 2026-06-28:

- VPN ingress works on `vps1` through `vps8` after `vps8` ingress rollout.
- SoftEther L2 `vpn_cascade` is frozen and absent from desired state on
  `vps1`, `vps2`, `vps3`, and `vps4`.
- No shared `CascadeLab` links are active. Historical links are preserved in
  `lab-cascade.json` only as disabled audit material.
- No public `cascade-vpsN` SNI surface should be published by HAProxy.
- `vps7` has no active shared `CascadeLab` links after the CPU storm incident.
- `vps5` remains an orchestration candidate and VPN ingress node; `vps7` remains
  a future `vps3` duplicate/standby candidate for L3 HA work.
- `vps8` is a Selectel RU services standby with mandatory VPN ingress only; no
  production service route is moved to it yet. Provider names such as
  `adminvps` and `selectel` are placement metadata, not runtime roles.

Stop before any broader rollout if `check_vpn_cascade_links.ps1 -Json` reports
any active links, if live HAProxy still contains `cascade-vps`, or if
`softether-cascade` is running on `vps1`, `vps2`, `vps3`, or `vps4`.

Incident note: adding alternate `vps7` receiver links to the shared `CascadeLab`
fabric on 2026-06-28 caused sustained CPU spikes on `vps1`, `vps2`, `vps4`, and
`vps7`. Mitigation was to stop `vpn_cascade` on affected nodes and freeze the
entire shared L2 cascade layer in desired state. Do not use multiple active L2
receiver paths as HA; future HA must be L3 policy routing.

`service,vpn_cascade` and `edge_route,vpn_cascade` are intentionally separate,
but both are absent during the freeze. `service,vpn_cascade` means the node runs
local cascade runtime and may manage outgoing links. `edge_route,vpn_cascade`
means HAProxy publishes public `cascade-vpsN` SNI on `443/992/5555`.
When `edge_route,vpn_cascade` is absent, HAProxy must not contain
`cascade-vpsN`, `is_cascade*`, or `be_cascade*` on any of those ports; the
shared `5555` listener may remain only for `vpn-vpsN` SoftEther edge
management.

When all public cascade aliases are retired, remove the whole
`vpn_cascade` section from `operator/haproxy/routes.yml` and rerun only
`edge_haproxy`. Otherwise HAProxy can keep a stale `cascade-vpsN` SNI route on
`443/992/5555` even when the public route is no longer desired.
`cascade-vpsN:5555` must not route anywhere while the freeze is active.

If SoftEther Server Manager reports "Source IP Restriction List of the Virtual
Hub", first verify which SNI target was used. `vpn-vpsN:5555` should reach
`softether-edge`; `cascade-vpsN:5555` should not be published while the
SoftEther L2 freeze is active. Keep management allowlisting centralized in HAProxy
`vpn_mgmt_ips.lst`; hub-level Source IP restrictions must not drift between VPS
unless that is an explicit emergency lockout.

### Edge Banlist Canary

`edge_banlist` first proved `vps2` in `observe`, then `enforce`, with scanner
IPs written to `generated_blocked_ips.lst` and no socket errors. The next
fleet rollout intentionally returns the shared config to `observe` and enables
the timer on all active edge aliases `vps1..vps8`. In `observe`, it reads
HAProxy stick-tables and writes `/var/log/ai-service-platform/edge_banlist.log`,
but it must not write generated bans or restart HAProxy.

Verify the canary after rollout:

```powershell
ssh -i .\operator\vps2\admin_key useradmin@vps2.mine-craft.su `
  "systemctl is-active edge-banlist.timer; systemctl is-enabled edge-banlist.timer; sudo tail -20 /var/log/ai-service-platform/edge_banlist.log"
```

Verify the socket lifecycle separately:

```powershell
ssh -i .\operator\vps2\admin_key useradmin@vps2.mine-craft.su `
  "test -S /opt/ai-service-platform/edge_haproxy/run/admin.sock && echo 'show table st_tcp_rates' | sudo socat - UNIX-CONNECT:/opt/ai-service-platform/edge_haproxy/run/admin.sock | head -20"
```

Only switch `operator/edge_banlist/config.yml` back to `enforce` after reviewing
the fleet observe logs from every edge alias and confirming that candidates do
not include operator, VPN, node, or service IPs.

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

The safe post-incident stage is no active `vps7` receiver link in shared
`CascadeLab`. Keep `vps7` as VPN ingress and future L3 HA candidate only.

Do not add `vps7-to-vps3`: that would make `vps7` an ingress/transit toward
`vps3`, not a duplicate receiver for `vps3`.

If a future isolated or loop-free design makes `vps7` an active cascade
receiver again, roll out in this order:

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

Stop if the new `vps7` TCP, SNI, admin, or cascade-link checks fail. Do not
publish `cascade-vps7` SNI routes unless a separate, loop-free rollout
explicitly makes `vps7` an active cascade alias again.

For the current post-incident state, check only the safe active links:

```powershell
.\tools\services\check_vpn_cascade_links.ps1 -Json -OnlyActive
```

Expected active links after the freeze are none. Do not add `vps1-to-vps3`,
`vps2-to-vps3`, `vps4-to-vps3`, `vps1-to-vps7`, `vps2-to-vps7`, or
`vps4-to-vps7` in the shared `CascadeLab` L2 fabric.

If `vps7` is ever reintroduced as a loop-free cascade receiver after explicit
design review, keep `vps7` in the same `service,vpn_cascade` row/batch as
ingress aliases while they have active links to `vps7`. The role prepares
egress-side users before configuring ingress-side links within one Ansible play;
splitting receiver and ingress aliases into different rollout batches can make
an ingress try the link before `vps7` is ready.

While the L2 freeze is active, SoftEther Server Manager should not show active
Cascade Connections on the former cascade nodes. Historical connection
definitions may remain in `lab-cascade.json`, but they must stay disabled and
must not be recreated by automation.

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

Active/probe cascade links in the same `CascadeLab` must also be loop-free as an
undirected graph. Directed acyclic graphs are not enough for SoftEther L2 bridge
fabric safety: `vps1>vps3 + vps2>vps3 + vps1>vps7 + vps2>vps7` is directed
acyclic, but it forms the undirected loop `vps1 -- vps3 -- vps2 -- vps7 --
vps1`.

### Future `vps1` Dual-Cascade HA

Keep SoftEther cascade as loop-free L2 transport only. Future active-active HA
for `vps1` must live at L3: GeoIP selects a destination pool, the pool contains
healthy receiver candidates such as `vps3` and `vps7`, and `policy_gateway`
chooses a path by destination hash with health fallback. The first canary must
apply only exact target IP routes and must include rollback before any default
or broad country routing is considered.

### Reinstall `vps1` As Provider Diagnostic

Use this only as a controlled provider/OS residue experiment. Before reinstall,
`vps1` must be present only in `edge_haproxy`, `vpn_edge`, and
`edge_route,vpn_ingress`. It must not be present in `policy_gateway`,
`minecraft`, or any present `vpn_cascade`/`cascade_topology` row. Historical
`vps1` fallback/cascade files are audit material only and must not be
reactivated.

After reinstalling `vps1` in the provider panel, update `operator/nodes.csv`
if the public IP changed, add the temporary `root_password`, and bootstrap as a
fresh provider instance with local key overwrite:

```powershell
.\tools\bootstrap\bootstrap_all_from_windows.ps1 `
  -AutoAcceptHostKey `
  -ForceOverwriteKeys
```

Then restore only mandatory VPN ingress:

```powershell
.\tools\services\rollout_from_state.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -OnlyService edge_haproxy

.\tools\services\rollout_from_state.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv `
  -OnlyService vpn_edge
```

Acceptance: `vps1` root password is cleared, admin-key SSH works, platform
baseline directories/logrotate exist, `vpn-vps1:443/992/5555` is reachable,
`softether-cascade` and `policy-router` are not running, and live HAProxy has
no `cascade-vps`, `is_cascade`, or `be_cascade`. If `cascade-vps1` still
TCP-connects but TLS/SNI fails, that is expected shared-IP HAProxy behavior; to
force timeout, remove or disable the `cascade-vps1` DNS record during the L2
freeze.

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

The L2 cascade freeze does not automatically move `minecraft` or any other
public edge route from `vps2`; edge duties still move only through explicit
`state.csv` route changes.

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
