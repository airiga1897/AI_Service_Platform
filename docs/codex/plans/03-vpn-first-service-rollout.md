# Step-by-step: VPN Edge First Service Rollout

После infrastructure preparation первым service rollout остаётся VPN path:

1. `edge_haproxy` - TCP edge перед VPN и будущими сайтами.
2. `vpn_edge` - SoftEther user ingress за HAProxy.

Service naming is semantic, not positional:

- `edge_haproxy` - edge proxy implemented with HAProxy.
- `vpn_edge` - SoftEther user VPN ingress behind the edge proxy.
- `vpn_cascade` - separate SoftEther cascade/site-to-site service.

Product deploy остаётся позже.

## Edge Network Contract

Static container IP используется только для edge/L4 contract endpoints:

```text
ai_service_edge 172.20.0.0/24
softether-edge  172.20.0.2
edge-haproxy    172.20.0.3
```

HAProxy routes SoftEther backends на `172.20.0.2`. `edge-haproxy` имеет свой fixed IP `172.20.0.3`, чтобы не конфликтовать с SoftEther в общей edge-сети.

Будущие frontend/backend/data services должны идти через Docker DNS names и network aliases, а не через static IP, пока не появится настоящий L3/L4 contract.

## Source Of Truth

`nodes.csv` - только адресная книга:

```csv
current_alias,endpoint,connection,root_password
vps1,vps01.example.com,ssh,
vps2,vps02.example.com,ssh,
vps3,vps03.example.com,ssh,
```

`state.csv` - роли, сервисы и lifecycle:

```csv
kind,name,ansible_group,active_aliases,candidate_aliases,old_aliases,state
platform_role,orchestration,orchestration,vps3,,,present
service,edge_haproxy,edge_haproxy,vps1,,,present
service,vpn_edge,vpn_edges,vps1+vps2+vps3,,,present
edge_route,vpn_ingress,vpn_ingress,vps1,,,present
edge_route,minecraft,minecraft_edge,vps4,,,present
service,vpn_cascade,vpn_cascades,,,,absent
```

`vpn_cascade` is separate from user VPN ingress and is not required for the
VPN edge-first rollout.

## HAProxy Operator Lists

Operator-local files:

```text
operator/haproxy/lists/vpn_mgmt_ips.lst
operator/haproxy/lists/blocked_ips.lst
```

Initial `vpn_mgmt_ips.lst`:

```text
91.204.75.25
95.31.25.30
```

`vpn_mgmt_ips.lst` controls access to SoftEther management port `5555/tcp`. If missing or empty, `5555/tcp` is closed for everyone.

## Rollout Command

Обычный запуск с operator machine:

```powershell
.\tools\services\rollout_from_state.ps1 `
  -NodesFile .\operator\nodes.csv `
  -StateFile .\operator\state.csv
```

WSL/Linux equivalent:

```bash
bash tools/services/rollout_from_state.sh \
  --nodes-file ./operator/nodes.csv \
  --state-file ./operator/state.csv
```

Скрипт делает:

1. sync на active orchestration node;
2. verify;
3. читает все `kind=service`;
4. для `present` делает `plan`, `apply --check`, `apply`;
5. для `absent` делает `plan`, `absent`;
6. для `purged` делает `plan`, `purge`;
7. читает `kind=edge_route` и переотрисовывает `edge_haproxy` для aliases с active routes.

Изменение `state.csv` само ничего не запускает.

## HAProxy Lifecycle

Запустить на `vps1`:

```csv
service,edge_haproxy,edge_haproxy,vps1,,,present
```

Остановить, сохранив config/data:

```csv
service,edge_haproxy,edge_haproxy,vps1,,,absent
```

Удалить runtime data явно:

```csv
service,edge_haproxy,edge_haproxy,vps1,,,purged
```

## VPN Edge Config

`vpn_edge` использует operator-only seed:

```text
operator/softether/edge/vpn_server.config
```

Это opaque secret state file. В v1 он копируется как baseline и не редактируется строковыми заменами.

After first install, remote `vpn_server.config` is mutable SoftEther runtime state.
Normal `vpn_edge present` rollout seeds this file only when it is missing and does
not overwrite an existing config.

To intentionally replace the live SoftEther config, use an explicit reseed action
for one alias:

```powershell
.\tools\services\rollout_from_state.ps1 -ReseedVpnEdge vps4
```

WSL/Linux:

```bash
bash tools/services/rollout_from_state.sh --reseed-vpn-edge vps4
```

Low-level debug escape hatch:

```powershell
.\tools\services\service_remote.ps1 vpn_edge reseed -Limit vps4
```

`reseed` requires an installed `vpn_edge`, backs up the current remote config,
copies `operator/softether/edge/vpn_server.config`, restarts `softether-edge`,
and prints the backup path. Granular `vpncmd`-based updates are future work.

## HAProxy Routes Config

Route settings хранятся вне git:

```text
operator/haproxy/routes.yml
```

Example:

```text
infra/ansible/haproxy.routes.example.yml
```

`vpn_edge` - это SoftEther container service. `vpn_ingress` - это HAProxy route к нему:

```csv
service,vpn_edge,vpn_edges,vps1,,,present
edge_route,vpn_ingress,vpn_ingress,vps1,,,present
```

VPN DNS:

```text
vpn-vps1.mine-craft.su -> vps1
vpn-vps2.mine-craft.su -> vps2
vpn-vps3.mine-craft.su -> vps3
```

`mainsrv01.mine-craft.su` управляется через Minecraft route:

```csv
edge_route,minecraft,minecraft_edge,vps4,,,present
```

Когда route включён, HAProxy публикует `25565/tcp` и `25575/tcp`; `newnout01` используется как primary backend, `mainserv01.netcraze.pro` как fallback backend. Minecraft upstream может наследоваться из `minecraft.defaults.backends` в `operator/haproxy/routes.yml`; `per_alias` нужен только для override конкретного edge alias.

Если для alias также включён `edge_route,vpn_ingress`, `minecraft.per_alias.<alias>.vpn_sni` может добавить публичное Minecraft имя в VPN SNI allowlist на `443/tcp`. Для текущего managed alias:

```yaml
minecraft:
  per_alias:
    vps4:
      vpn_sni:
        - mainsrv01.mine-craft.su
```

## TCP Contract

Current TCP ports:

- `443/tcp` - SNI routing, VPN domain to `softether-edge:443`;
- `992/tcp` - SoftEther through HAProxy;
- `5555/tcp` - SoftEther management, allowlist only.

UDP и cascade/site-to-site остаются future work.
