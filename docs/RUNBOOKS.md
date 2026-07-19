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

### Legacy `ai-retail-dev` predeploy proof

This procedure predates role-based product placement. Do not infer a target VPS
from the environment name. Before re-enabling it, migrate the deploy workflow to
resolve its target from operator state/config as defined in
[`PLACEMENT.md`](PLACEMENT.md).

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
5. On the resolved target, the runtime env file must exist in the configured deploy directory.
6. Текущий milestone проверяет `docker compose config`; реальный `pull/up` и healthcheck будут включены следующим отдельным шагом.

Другие `instance`/`environment` в этом milestone **отклоняются** workflow'ом намеренно.

### Откат `ai-retail-dev` preprod

1. Определить предыдущий неизменяемый `image_ref` (пока вручную; lookup deploy-state по git-тегам — follow-up).
2. **Actions → Rollback** → `to_ref=<предыдущий ref>` (обязателен; пустой `to_ref` завершит workflow с ошибкой).
3. Preflight проверит ref против `services.yml`; SSH-откат — re-deploy того же compose с предыдущим `IMAGE_REF`.

`ai-retail-mvp` использует release guard: preflight/deploy отклонят refs вне паттерна `ai-retail-mvp-v*`. Текущий release — `ai-retail-mvp-v1`.

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
- No old `edge_route,vpn_cascade` SNI/backend should be published by HAProxy.
- `vps7` has no active shared `CascadeLab` links after the CPU storm incident.
- `vps5` remains an orchestration candidate and VPN ingress node; `vps7` remains
  a future `vps3` duplicate/standby candidate for L3 HA work.
- `vps8` is a Selectel RU services standby with mandatory VPN ingress only; no
  production service route is moved to it yet. Provider names such as
  `adminvps` and `selectel` are placement metadata, not runtime roles.

Stop before any broader rollout if `check_vpn_cascade_links.ps1 -Json` reports
any active L2 links, if live HAProxy still contains `is_cascade` or
`be_cascade`, or if `softether-cascade` is running on `vps1`, `vps2`, `vps3`,
or `vps4`.

Incident note: adding alternate `vps7` receiver links to the shared `CascadeLab`
fabric on 2026-06-28 caused sustained CPU spikes on `vps1`, `vps2`, `vps4`, and
`vps7`. Mitigation was to stop `vpn_cascade` on affected nodes and freeze the
entire shared L2 cascade layer in desired state. Do not use multiple active L2
receiver paths as HA; future HA must be L3 policy routing.

`service,vpn_cascade` and `edge_route,vpn_cascade` are intentionally separate,
but both are absent during the freeze. `service,vpn_cascade` means the node runs
local cascade runtime and may manage outgoing links. `edge_route,vpn_cascade`
means HAProxy publishes public `cascade-vpsN` SNI on `443/992/5555`.
When `edge_route,vpn_cascade` is absent, HAProxy must not contain `is_cascade*`
or `be_cascade*`. The `cascade-vpsN` names are retired for new transport
layers. New point-to-point transport uses `l3-vpsN.mine-craft.su` as the only
public SNI: port `443` is the transport path and port `5555` is the management
path when management is explicitly exposed. HAProxy must route those ports to
separate internal Docker networks so SoftEther management cannot be reached
through the transport source IP. For SoftEther public routes on `443`, `992`,
and `5555`, HAProxy must silent-drop not only unknown SNI and non-allowlisted
sources, but also allowed SNI whose selected backend is down; clients should see
a timeout, not a HAProxy reject or SoftEther error dialog.

When all public cascade aliases are retired, remove the whole
`vpn_cascade` section from `operator/haproxy/routes.yml` and rerun only
`edge_haproxy`. Otherwise HAProxy can keep a stale `cascade-vpsN` SNI route on
`443/992/5555` even when the public route is no longer desired.
Do not re-add a `vpn_cascade` section to `operator/haproxy/routes.yml` while the
freeze is active.

If SoftEther Server Manager reports "Source IP Restriction List of the Virtual
Hub", first verify which SNI target was used. `vpn-vpsN:5555` should reach
`softether-edge`; `l3-vpsN:5555` should reach the explicitly exposed
point-to-point SoftEther server; `cascade-vpsN` names should not route anywhere
while the L2 freeze is active. Keep management allowlisting centralized in
HAProxy `vpn_mgmt_ips.lst`.

### Roll Out Platform Network Baseline

All active VPS aliases `vps1` through `vps8` use explicit per-node platform
networks. `vpn_cascade` remains frozen/absent. PostgreSQL is
first rolled out in standalone mode on selected service aliases; `softether_l3_vps`
is then added as a separate transport test before any standby conversion.

The operator runs the long remote rollout commands manually:

```powershell
.\tools\services\rollout_from_state.ps1 -NodesFile .\operator\nodes.csv -StateFile .\operator\state.csv -OnlyService vpn_edge
.\tools\services\rollout_from_state.ps1 -NodesFile .\operator\nodes.csv -StateFile .\operator\state.csv -OnlyService platform_networks
```

Acceptance:

- On `vps1` through `vps8`, VPN ingress remains healthy through `edge-haproxy`
  and `softether-edge`. `edge-banlist` remains a systemd timer.
- No `softether-l3-*` or `softether-cascade` containers are running.
- `ai-service-postgres` may run only on aliases selected by
  `service,postgres_runtime`.
- `softether-l3-vps-*` may run only for explicitly present `softether_l3_vps` links.
- No `cascade-vps` or `l3-mgmt-vps` routes exist in HAProxy.
- For each `vpsN`, `ai_service_data_vpsN` exists at `172.30.N.0/24` and
  `ai_service_app_vpsN` exists at `172.31.N.0/24`.
- Empty retired managed networks are removed; non-empty retired networks must
  stop the rollout and be investigated instead of force-removed.
- On `vps1`, Minecraft edge continues to publish `25565/25575`.
- `check_vpn_cascade_links.ps1 -Json` still reports no selected L2 links.

SoftEther Virtual Layer-3 Switch is a documented future option, not the current
implementation. It is a built-in SoftEther router between isolated Virtual Hubs
and could be evaluated later if multiple hub-to-hub routed segments are needed.
Do not enable it without a separate design review. `softether_l3_vps` may be
present only as transport-only P2P; no Postgres replication/service route is
active until `platform_router` is implemented and verified.

### Future Platform Router Plan

`platform_networks` owns local service networks only. It must not become the
router between VPN, P2P, and application/data networks. Add a separate
`platform_router` service before exposing platform services across VPN or
between VPS aliases.

Intended responsibility:

```text
local VPN/P2P/client side
  -> local platform_router
  -> explicit allowed target route
  -> local or remote platform data/app endpoint
```

For inter-VPS traffic, the preferred path is:

```text
vps4 platform data/app
  -> vps4 platform_router
  -> L3/P2P transport
  -> vps8 platform_router
  -> vps8 platform data/app
```

The transport layer (`softether_l3_vps`, future WireGuard/IPsec, or another L3
tunnel) should only move packets between routers. It should not connect
Postgres, Redis, nginx, or app containers directly to transport namespaces.
This keeps the service contract stable if the transport implementation changes.

Guardrails for the future role:

- Routes are target-specific, for example `172.30.8.10:5432`, not broad access
  to all `172.30.8.0/24`.
- `ai_service_data_vpsN` and `ai_service_app_vpsN` remain per-node local
  networks. Inter-node reachability appears only through explicit router rules.
- VPN clients do not get direct adjacency to data networks. Access to data
  services must be mediated by router policy or a service proxy.
- Router policy must be auditable: source, destination, port, purpose, and
  owning service.
- First implementation should be canary-only, likely `vps4 <-> vps8` for
  PostgreSQL transport testing, before any fleet rollout.

### Staged PostgreSQL Runtime

First deploy PostgreSQL as independent standalone runtimes to prove the role,
container, secrets, volume, and per-node data networks:

```csv
service,postgres_runtime,postgres_runtimes,vps8+vps4,,,present
```

In `standalone` mode every alias in `active_aliases` is an independent primary.
It is not HA and must not be treated as replicated data. The current standard
container addresses are:

```text
vps8: ai_service_data_vps8 172.30.8.0/24 -> ai-service-postgres 172.30.8.10
vps4: ai_service_data_vps4 172.30.4.0/24 -> ai-service-postgres 172.30.4.10
```

Public or host `5432` must not be published. P2P routing and async standby are
separate later steps. Only after `172.30.8.10:5432` is reachable from the future
standby path should `postgres_runtime.replication_mode` move to
`async_standby`, with `vps8` as primary and `vps4` as standby.

The P2P address convention is link-scoped. Link ids follow traffic direction:
`<client/source vps><server/target vps>`. For the first PostgreSQL transport
from future standby `vps4` to primary `vps8`, link id `48` is used:

```text
172.27.48.0/24  P2P transport on vps8: HAProxy 172.27.48.3 -> platform-router 172.27.48.2
172.28.48.0/24  legacy source handoff network, not active PG datapath
172.29.48.0/24  P2P management on vps8: HAProxy 172.29.48.3 -> platform-router 172.29.48.2
172.30.8.0/24   vps8 data: standalone Postgres 172.30.8.10
172.30.4.0/24   vps4 data: standalone Postgres 172.30.4.10
172.31.8.0/24   vps8 app: future nginx/app/worker
172.31.4.0/24   vps4 app: future nginx/app/worker
10.88.48.0/24   SoftEther virtual VPN: server 10.88.48.8, clients 10.88.48.4 and 10.88.48.9
```

`l3-vps8.mine-craft.su:443` is the SoftEther P2P transport SNI.
`l3-vps8.mine-craft.su:5555` is the management SNI for the same server. Do not
add `l3-mgmt-vps8` names. The two public ports must terminate on different
internal Docker networks so management can be restricted by `adminip.txt` to the
HAProxy management-side address only.

The desired link intent and secrets for this new non-cascade L3 transport live
under `operator/softether/l3-vps`. Keep non-secret JSON examples in
`operator/softether/l3-vps/secrets/template.json`; do not create new source of
truth paths for this layer.

P2P management is public only for aliases that run the server side. In this
link, `vps8` runs `platform-router-softether-server` in the `platform-router`
network namespace. `vps4` runs `platform-router-softether-client`; client
management remains local through SSH and `vpncmd /CLIENT`.

The proven PostgreSQL service path does not use platform-router SNAT. Source
routers route `172.30.8.10/32` through `vpn_l3vps0`, and primary-side
SoftEther SecureNAT makes PostgreSQL on `vps8` observe `172.30.8.2`.
`postgres_runtime.replication_hba_cidrs_by_alias.vps8` therefore allows the
replication user from `172.30.8.2/32`. The old return-route model for
`172.27.48.2`, `10.88.48.4`, or `10.88.48.9` is no longer the desired
service-path intent.

When renaming the PostgreSQL overlay hub, keep `vpncmd AccountCreate` on the
explicit `/HUB` plus plain `/USERNAME` model. If the old hub still contains the
same client users, first roll out and verify sessions on the new hub, then
delete the retired hub as a separate cleanup. Do not make normal
`platform_router` convergence delete old hubs automatically.

The transition from standalone `vps4` to standby is intentionally destructive
and must be explicit. A normal rollout must fail if it sees initialized primary
data on a node that is now declared as standby. After fencing and backup review,
run the targeted standby reinit only for that alias:

```bash
bash tools/services/service.sh postgres_runtime apply --limit vps4 --reinit-standby
```

or, from Windows on a prepared control environment:

```powershell
.\tools\services\service.ps1 postgres_runtime apply -Limit vps4 -ReinitStandby
```

Do not pass standby reinit through broad fleet rollout commands. Reinit clears
the target data volume contents and rebuilds it from `pg_basebackup`.

### Infrastructure Runtime Layer Plan

Placement is driven by `state.csv`, not by hardcoded VPS names. Concrete aliases
are current placement only. Use `active_aliases` for the current active runtime
and `candidate_aliases` for prepared manual standby candidates.

Target runtime split:

- `postgres_runtime` - persistent DB runtime, active primary plus manual
  standby candidates.
- `redis_runtime` - cache/broker/result-backend runtime, active Redis plus
  manual standby candidates.
- `flower_runtime` - Celery observability/control runtime. It can run without
  any public route.
- project web/API runtime - project image and public/user HTTP route.
- project worker runtime - project image running Celery workers.
- project scheduler runtime - project image running Celery beat or another
  singleton scheduler.

Example state shape:

```csv
service,postgres_runtime,postgres_runtimes,<primary>,<standby+standby>,,present
service,redis_runtime,redis_runtimes,<active>,<standby+standby>,,present
service,flower_runtime,flower_runtimes,<active>,,,present
service,ai_retail_worker,ai_retail_workers,<worker aliases>,,,present
service,ai_retail_scheduler,ai_retail_schedulers,<singleton>,,,present
edge_route,flower_mgmt,flower_mgmt,,,,absent
```

Flower default is VPN-only/internal. Do not publish it just because
`flower_runtime` is present. If temporary external access is needed, add an
explicit `edge_route,flower_mgmt` row for the target aliases and route
`https://flower-vpsN.mine-craft.su` on public `443` through HAProxy to the
internal Flower backend on `8080`. Protect the route with HAProxy management
allowlists and Flower/basic auth. Remove the route when sharing is no longer
needed.

Implementation order:

1. Verify `platform_networks` on `vps1` through `vps8`.
2. Add `postgres_runtime` on the explicit per-node data networks.
3. Add `redis_runtime` with no public port and with exact app/worker allowlists.
4. Add project worker and scheduler runtimes that consume Postgres and Redis
   endpoints from platform config.
5. Add `flower_runtime` as internal management UI.
6. Add optional `flower_mgmt` public route only after internal Flower access and
   auth are verified.

Acceptance for each runtime layer:

- A present `service` row starts only the runtime it owns.
- Public exposure appears only when the matching `edge_route` row is present.
- `edge_route,flower_mgmt` absent means no public Flower SNI/backend in HAProxy.
- Worker runtimes can scale horizontally; scheduler runtimes remain singleton
  unless the project explicitly supports distributed scheduling.
- No runtime stores placement logic in role code; changing placement is a
  `state.csv` edit plus targeted rollout.

### Edge Banlist Canary

`edge_banlist` first proved `vps2` in `observe`, then `enforce`, and then
rolled out to all active edge aliases `vps1..vps8`. Current verified status:
fleet `enforce` is active, `edge-haproxy` is running on every edge alias, and
the latest logs show `errors: []`. Generated TTL bans are expected and live in
`/opt/ai-service-platform/edge_haproxy/haproxy/lists/generated_blocked_ips.lst`.

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

Before expanding thresholds or changing ban TTL, review logs from every edge
alias and confirm that candidates do not include operator, VPN, node, or service
IPs.

Repeated scanner IPs should show `count` and `ttl_seconds` in the JSON log.
Expected defaults are 3600 seconds for the first ban, doubling on later
reappearances, capped at 86400 seconds.

In `enforce`, generated-list changes must reload HAProxy through a stop,
`run/admin.sock` cleanup, and `up -d` sequence. Do not replace this with plain
`docker compose restart edge-haproxy`: HAProxy can otherwise fail to start while
trying to preserve a stale `/run/haproxy/admin.sock`.

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

### PostgreSQL `vps8` Primary / `vps4` Standby

Current target role is `vps8` as preferred PostgreSQL primary and `vps4` as
manual async standby. `state.csv` describes desired topology; it does not
promote PostgreSQL by itself. Promotion is an operational action and must be
paired with fencing of the old primary.

To build the standby after P2P transport is verified:

1. Confirm `vps4` can reach the primary endpoint on `vps8`.
2. Change postgres state from standalone to:
   ```csv
   service,postgres_runtime,postgres_runtimes,vps8,vps4,,present
   ```
3. Change `operator/postgres/config.yml` to:
   ```yaml
   replication_mode: async_standby
   primary_endpoint: 172.30.8.10
   standby_basebackup_network: container:platform-router
   replication_hba_cidrs_by_alias:
     vps8:
       - 172.30.8.2/32
   ```
   `container:platform-router` is required because the verified route from
   `vps4` to `172.30.8.10:5432` lives in the platform-router network namespace,
   not on the host default namespace.
4. Run a normal `postgres_runtime` rollout and expect it to stop if `vps4`
   still has initialized primary data.
5. After backup/fencing review, run targeted standby reinit for `vps4` with
   `--reinit-standby` / `-ReinitStandby`.
6. Verify `vps8` has `pg_is_in_recovery() = false`, `vps4` has
   `pg_is_in_recovery() = true`, `vps8` sees `vps4` in
   `pg_stat_replication`, and `vps4` has a streaming WAL receiver.

For a planned switchover from `vps8` to `vps4`:

1. Stop all application writes and confirm replication catch-up.
2. Stop PostgreSQL on `vps8` or otherwise fence it from writes.
3. Promote `vps4` manually with `pg_ctl promote` inside the Postgres container:
   ```powershell
   ssh -i .\operator\vps4\admin_key useradmin@vps4.mine-craft.su `
     "sudo docker exec -u postgres ai-service-postgres pg_ctl -D /var/lib/postgresql/data promote"
   ```
4. Verify writes on the promoted `vps4` primary.
5. Update state so `vps4` is active and `vps8` is candidate standby.
6. Rebuild `vps8` from the new primary through targeted standby reinit.

For emergency failover, promote `vps4` only after confirming `vps8` is
unreachable or fenced. Never restart the old `vps8` as primary after `vps4`
has been promoted; recover it only by rebuilding it as standby from the new
primary. Failback is a later planned switchover, not an in-place data flip.

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
no old `vpn_cascade` ACL/backend (`is_cascade` or `be_cascade`) and no
`cascade-vpsN` route. New point-to-point management uses the same
`l3-vpsN.mine-craft.su` SNI on port `5555`, not `cascade-vpsN` or
`l3-mgmt-vpsN` names. If `cascade-vps1` still TCP-connects but TLS/SNI fails,
that is expected shared-IP HAProxy behavior; to force timeout, remove or
disable the `cascade-vps1` DNS record during the L2 freeze.

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
- Role-based application failover after the legacy positional
  `backup_server` scripts are replaced. Do not run the old `failover.sh` /
  `failback.sh` as a current placement procedure.
- Продление и валидация TLS-сертификатов (Nginx + Certbot, копия для
  SoftEther).
- Инспекция HAProxy/Nginx маршрутизации (после внедрения
  `tools/render-edge`).
- Инспекция SoftEther: маршрутизация, management-доступ,
  логи (`5555/tcp` allowlist, `softether_logs`).
# Host Swap Policy

Emergency swap is managed by the `host_resources` service from
`operator/host_resources/config.yml`. The service owns only `/swapfile` and
`vm.swappiness`; it does not tune PostgreSQL or Redis memory limits.

Apply one node at a time:

```powershell
.\tools\services\service_remote.ps1 host_resources apply -Limit vps3
```

The role refuses unknown active swap sources, insufficient disk/memory
headroom, and destructive `absent`/`purge` actions. After apply, verify
`swapon --show`, `/etc/fstab`, `sysctl vm.swappiness`, and perform the first
reboot persistence rehearsal on the `vps3` canary before continuing.
