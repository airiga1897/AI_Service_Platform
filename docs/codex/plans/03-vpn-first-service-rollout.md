# Step-by-step: VPN First Service Rollout

Этот документ фиксирует первый настоящий platform service rollout после infrastructure preparation.
Инфраструктурная подготовка остаётся первой: VPN не ставится до bootstrap,
inventory, проверки Ansible connectivity и GitHub deploy-access/predeploy-check.

## 1. Что должно быть готово до VPN

Перед установкой SoftEther/VPN должны быть завершены:

1. `operator/nodes.csv` заполнен для свежепереустановленных VPS.
2. `vps3` bootstrap-нут как management/control node.
3. `vps1` и `vps2` bootstrap-нуты как managed nodes.
4. Bootstrap-generated keys разложены в ignored `operator/<alias>/`.
5. На VPS3 создан real `inventory.ini`.
6. Проверка Ansible connectivity прошла:

   ```bash
   cd /opt/ai-service-platform
   ansible all -i inventory.ini -m ping
   ```

7. GitHub Environment `ai-retail-dev-preprod` создан, secrets внесены, workflow Deploy прошёл как predeploy-check.

После этого можно переходить к service rollout. Первым service rollout является
SoftEther/VPN, а не product deploy.

## 2. Что уже не является blocker для VPN

Перед VPN должен быть готов только infrastructure/deploy-access слой. Реальный product rollout всё ещё откладывается:

- deploy/rollback product runtimes;
- `AromaFlowAI` и `AI_E_Retail` runtime stacks;
- management-control-plane;
- knowledge-retrieval.

Эти шаги не отменяются, но не являются blocker для первого VPN rollout.

## 3. VPN как первый platform service

SoftEther/VPN — platform service, а не product app. Он не принадлежит
`AromaFlowAI`, `AI_E_Retail` или отдельному runtime instance.

`nodes.csv` остаётся source of truth для желаемой картины. Если в `roles` узла есть
`vpn-edge`, inventory generator добавляет этот узел в Ansible group `[vpn_edges]`.
Первый rollout контролируется не удалением future-ролей из CSV, а запуском VPN service runner.

Проверить желаемое состояние без изменений:

```powershell
.\tools\services\service.ps1 vpn plan -NodesFile .\operator\nodes.csv
```

или на VPS3/Linux:

```bash
bash tools/services/service.sh vpn plan \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv
```

Первый target:

```text
vps1
```

Первый запуск:

```bash
bash tools/services/service.sh vpn apply \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1 \
  --check

bash tools/services/service.sh vpn apply \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1
```

После успешной проверки на `vps1` тот же подход распространяется на:

```text
vps2
vps3
```

VPN-only edge nodes в других странах можно будет добавлять позже через тот же
role/node подход.

## 4. TCP-only contract

На первом этапе сохраняем текущий TCP-only contract SoftEther:

| Port | Protocol | Purpose |
| --- | --- | --- |
| `443` | TCP | SSTP/SSL VPN через HAProxy SNI routing |
| `992` | TCP | Альтернативный SSL endpoint SoftEther |
| `1194` | TCP | OpenVPN-compatible TCP endpoint |
| `5555` | TCP | SoftEther Server Manager, только allowlist |

UDP пока не включается. IPsec/L2TP/OpenVPN UDP добавляются только после
отдельного решения и проверки.

## 5. Edge contract

- HAProxy публикует TCP-порты наружу.
- SoftEther остаётся внутри Docker network и не публикует TCP-порты напрямую.
- `443/tcp` может разделяться по SNI между site traffic и VPN.
- `992/tcp` и `1194/tcp` маршрутизируются в SoftEther по порту.
- `5555/tcp` маршрутизируется в SoftEther management только через allowlist.
- Реальные management allowlists, passwords, private keys и `vpn_server.config`
  не коммитятся.

## 6. Provisioning scope

Для VPN-first service rollout нужны только platform prerequisites:

- Docker;
- HAProxy;
- firewall/security prerequisites;
- SoftEther container;
- persistent volumes:
  - `softether_data`;
  - `softether_logs`;
- backup/restore rule для `softether_data` и VPN config.

Product runtime stacks не запускаются в этом milestone.

## 7. Remove model

Отсутствие `vpn-edge` в `nodes.csv` не удаляет уже установленный VPN автоматически.
Удаление всегда запускается явно.

Остановить/убрать сервис без удаления данных:

```bash
bash tools/services/service.sh vpn absent \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1
```

Полностью удалить данные остановленного сервиса можно только с явным подтверждением:

```bash
bash tools/services/service.sh vpn purge \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1 \
  --confirm-purge
```

## 8. Future tests

Отдельно позже проверяются:

- SoftEther site-to-site/cascade;
- отдельные контейнеры/volumes для user VPN ingress и site-to-site transport;
- SSH tunnel fallback для точечных TCP-сценариев;
- GeoDNS/L4 TCP proxy для nearest VPN ingress;
- UDP-протоколы SoftEther.

WireGuard не входит в базовую архитектуру.

## 9. Acceptance checklist

- `vps1` доступен из Ansible с VPS3.
- Inventory содержит `vps1`, `vps2`, `vps3` в `[vpn_edges]`, если в `nodes.csv`
  у них есть role `vpn-edge`.
- `service vpn plan` показывает desired state и ничего не меняет.
- Docker работает на `vps1`.
- HAProxy config validates.
- SoftEther container running.
- TCP ports `443`, `992`, `1194`, `5555` слушаются как ожидается.
- `5555/tcp` закрыт для всех, кроме allowlist.
- `vpn_server.config` не попал в git.
- Реальные IP, пароли, private keys, `.env` и generated inventory не попали в git.
