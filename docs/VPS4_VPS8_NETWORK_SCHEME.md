# vps4 -> vps8 Network Scheme

This diagram captures the planned container and network layout for PostgreSQL
transport testing between `vps4` and `vps8`.

```mermaid
flowchart LR
  subgraph V4["vps4"]
    V4_EH["edge-haproxy<br/>172.20.0.3 edge<br/>172.24.0.3 edge_mgmt"]
    V4_SE["softether-edge<br/>172.20.0.2 edge<br/>172.24.0.2 edge_mgmt"]

    V4_PG["ai-service-postgres<br/>172.30.4.10 data"]
    V4_APP["future app/nginx/worker<br/>172.31.4.x app"]

    V4_PR["platform-router planned<br/>172.28.48.3 p2p_client<br/>172.30.4.2 data<br/>172.31.4.2 app"]
    V4_P2P["softether-l3-vps-client<br/>172.28.48.2 p2p_client<br/>10.88.48.2 vpn"]
  end

  subgraph V8["vps8"]
    V8_EH["edge-haproxy<br/>172.20.0.3 edge<br/>172.24.0.3 edge_mgmt<br/>172.27.48.3 p2p_transport<br/>172.29.48.3 p2p_mgmt"]
    V8_SE["softether-edge<br/>172.20.0.2 edge<br/>172.24.0.2 edge_mgmt"]

    V8_P2P["softether-l3-vps-server<br/>172.27.48.2 p2p_transport<br/>172.29.48.2 p2p_mgmt<br/>10.88.48.1 vpn"]
    V8_PR["platform-router planned<br/>172.27.48.4 p2p_transport<br/>172.30.8.2 data<br/>172.31.8.2 app"]

    V8_PG["ai-service-postgres<br/>172.30.8.10 data"]
    V8_APP["future app/nginx/worker<br/>172.31.8.x app"]
  end

  Internet["Internet / operator"]
  Internet -->|"vpn-vps4:443/992/5555"| V4_EH
  Internet -->|"vpn-vps8:443/992/5555"| V8_EH
  Internet -->|"l3-vps8:443 transport"| V8_EH
  Internet -->|"l3-vps8:5555 management"| V8_EH

  V8_EH -->|"443 -> 172.27.48.2"| V8_P2P
  V8_EH -->|"5555 -> 172.29.48.2"| V8_P2P

  V4_P2P <-->|"SoftEther VPN<br/>10.88.48.2 <-> 10.88.48.1"| V8_P2P

  V4_PG -->|"future replication path"| V4_PR
  V4_APP --> V4_PR
  V4_PR --> V4_P2P

  V8_P2P --> V8_PR
  V8_PR -->|"5432"| V8_PG
  V8_PR --> V8_APP
```

## Notes

- `softether-l3-vps-*` is transport only.
- Platform services must not attach directly to transport networks.
- Inter-VPS service reachability should use:

```text
platform service -> platform_router -> L3/P2P transport -> platform_router -> platform service
```

- Public P2P management is exposed only on aliases running a P2P server.
  For the first link, that is `l3-vps8.mine-craft.su:5555`.
