# Step-by-step: VPN First Service Rollout

Этот документ фиксирует первый настоящий platform service rollout после infrastructure preparation.

Порядок остается таким:

1. Bootstrap VPS через `nodes.csv`.
2. Sync `nodes.csv` и `state.csv` на control/orchestration node.
3. Проверка Ansible connectivity.
4. GitHub deploy-access/predeploy-check.
5. Первый service rollout: SoftEther/VPN.

Product deploy пока не включается.

## 1. Source Of Truth

Для VPN используются два operator-local файла:

```text
operator/nodes.csv
operator/state.csv
```

`nodes.csv` описывает VPS и endpoints.

`state.csv` описывает желаемое состояние сервиса:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
service,vpn,vpn_edges,vps1+vps2+vps3,,,present
```

Это значит:

- сервис: `vpn`;
- Ansible group: `vpn_edges`;
- active nodes: `vps1`, `vps2`, `vps3`;
- желаемое состояние: `present`.

## 2. Подготовить Inventory

На control node:

```bash
cd /opt/ai-service-platform

sudo bash tools/bootstrap/create_inventory.sh \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --include vps1,vps2,vps3 \
  --check
```

Inventory должен содержать `vps1`, `vps2`, `vps3` в `[vpn_edges]`, если они указаны в `service,vpn`.

## 3. Посмотреть План

Windows/operator:

```powershell
.\tools\services\service.ps1 vpn plan `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv
```

Control node/Linux:

```bash
bash tools/services/service.sh vpn plan \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv
```

`plan` ничего не меняет. Он только показывает, где VPN должен быть `present`.

## 4. Первый Осторожный Apply

Первый target:

```text
vps1
```

Dry run:

```bash
bash tools/services/service.sh vpn apply \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1 \
  --check
```

Real apply:

```bash
bash tools/services/service.sh vpn apply \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1
```

После проверки `vps1` тем же способом добавляются `vps2` и `vps3`.

## 5. Remove Model

Изменение `state.csv` не удаляет сервис автоматически.

Остановить/убрать сервис без удаления данных:

```bash
bash tools/services/service.sh vpn absent \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1
```

Полностью удалить данные остановленного сервиса:

```bash
bash tools/services/service.sh vpn purge \
  --nodes-file /opt/ai-service-platform/operator/nodes.csv \
  --state-file /opt/ai-service-platform/operator/state.csv \
  --inventory /opt/ai-service-platform/inventory.ini \
  --limit vps1 \
  --confirm-purge
```

`purge` всегда требует `--confirm-purge`.

## 6. SoftEther Contract

SoftEther/VPN — platform service, не часть `AromaFlowAI` или `AI_E_Retail`.

Текущий contract:

| Port | Protocol | Purpose |
| --- | --- | --- |
| `443` | TCP | SSTP/SSL VPN через HAProxy SNI routing |
| `992` | TCP | Альтернативный SSL endpoint SoftEther |
| `1194` | TCP | OpenVPN-compatible TCP endpoint |
| `5555` | TCP | SoftEther Server Manager, только allowlist |

UDP пока не включается.

HAProxy публикует TCP-порты наружу. SoftEther остается внутри Docker network и не публикует порты напрямую.

## 7. Acceptance Checklist

- `state.csv` содержит `service,vpn,...,present`.
- `create_inventory.sh --state-file` добавляет active VPN aliases в `[vpn_edges]`.
- `service vpn plan` ничего не меняет.
- `service vpn apply --limit vps1 --check` проходит без разрушительных действий.
- SoftEther container запускается на целевом узле.
- TCP ports `443`, `992`, `1194`, `5555` работают согласно edge contract.
- `5555/tcp` закрыт для всех, кроме allowlist.
- `vpn_server.config`, private keys, реальные IP, пароли и generated inventory не попали в git.
