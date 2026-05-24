# Step-by-step: VPN Edge First Service Rollout

После infrastructure preparation первым service rollout остаётся VPN path:

1. `edge_haproxy` - TCP edge перед VPN и будущими сайтами.
2. `vpn_edge` - SoftEther user ingress за HAProxy.

Product deploy остаётся позже.

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
service,vpn_cascade,vpn_cascades,,,,absent
```

`vpn_cascade` reserved/not implemented.

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

Скрипт делает:

1. sync на active orchestration node;
2. verify;
3. читает все `kind=service`;
4. для `present` делает `plan`, `apply --check`, `apply`;
5. для `absent` делает `plan`, `absent`;
6. для `purged` делает `plan`, `purge`.

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

## TCP Contract

Current TCP ports:

- `443/tcp` - SNI routing, VPN domain to `softether-edge:443`;
- `992/tcp` - SoftEther through HAProxy;
- `1194/tcp` - SoftEther through HAProxy;
- `5555/tcp` - SoftEther management, allowlist only.

UDP и cascade/site-to-site остаются future work.
