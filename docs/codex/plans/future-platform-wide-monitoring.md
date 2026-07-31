# Future platform-wide monitoring

## Decision

Monitoring is a platform capability, not a per-project stack. MyCleanBot,
AI_E_Retail, site runtimes, PostgreSQL, backup and network services must publish
signals into one platform-owned collector and alerting plane.

Product contracts may define required signals, but they must not create their
own Prometheus, Grafana, Alertmanager, Loki or exporter lifecycle.

## Placement and access

- The active `platform_role=monitoring` node owns collectors, retention,
  alert evaluation and dashboards.
- A candidate monitoring node is prepared for recovery without running a second
  writer against the same local storage.
- Prometheus, Grafana and Alertmanager management interfaces listen only on
  loopback or an explicitly approved VPN management endpoint.
- Exporters listen on private service endpoints. Cross-VPS traffic uses narrow
  `platform_router` policies; public listeners, public DNS records and new
  firewall openings are forbidden.
- Administrative SSH routing is a separate control-plane project. Monitoring
  transport must not silently change Ansible inventory or SSH ingress.

## Common discovery model

Targets come from platform desired state, not hardcoded product templates:

- `operator/state.csv` selects active/candidate platform roles and services;
- `services.yml` declares product health and ownership contracts;
- platform runtime inventory renders file-based service discovery grouped by
  VPS, service, runtime instance and environment;
- target removal is staged so a temporary rollout does not erase history or
  silence alerts.

Every target has stable labels such as `vps`, `service`, `instance`,
`environment`, `owner=platform` and `access=platform-route-only`.

## Signal classes

### Host and network

- CPU, memory, filesystem, inode and load saturation;
- Docker daemon and container runtime state;
- platform-router reachability, policy counters and transport health;
- VPN edge and HAProxy availability without exposing management ports.

### PostgreSQL

- primary/standby role, replication lag and WAL retention;
- connection saturation, locks and database size;
- disk warning at the platform threshold;
- tenant-aware availability without collecting credentials or query text.

### Product runtimes

- `/livez` for process liveness;
- `/healthz` for dependency readiness;
- expected container count and accepted immutable digest;
- worker heartbeat freshness where the product contract requires it.

MyCleanBot additionally requires the `telegram-supervisor` heartbeat, but this
is a product-labelled series in the shared monitoring plane, not a dedicated
monitoring deployment.

### Backup and recovery

- last successful backup timestamp;
- last successful scratch restore rehearsal timestamp;
- snapshot/repository check status;
- retention failures and backup destination reachability.

Only timestamps, status codes and minimal labels are collected. Database URLs,
SSH material, Telegram credentials, message text and session contents are
forbidden in metrics, labels and logs.

## MyCleanBot signals to retain

- HTTP probes for `/livez` and `/healthz`;
- `mycleanbot_backup_last_success_timestamp_seconds`;
- `mycleanbot_restore_rehearsal_last_success_timestamp_seconds`;
- fresh `telegram-supervisor` heartbeat;
- web/worker container health and accepted digest;
- PostgreSQL tenant reachability and isolation evidence.

Alert rules must use `absent(...)` as well as age thresholds so a missing metric
cannot silently look healthy.

## Migration from the exploratory endpoint

An exploratory private endpoint was tested on VPS1 at `172.31.1.12:9100`, with
a loopback-only Prometheus process on VPS6 and a narrow VPS6-to-VPS1
platform-router policy. It demonstrated:

- no host/public listener on VPS1;
- `127.0.0.1:9090` only on VPS6;
- successful platform-route scrape;
- visibility of backup and restore-rehearsal timestamps.

This experiment is not the final service design and must not be published as a
MyCleanBot-specific role. Before the shared monitoring rollout, inventory the
temporary units and policy, then either adopt them into the generic role or
remove them explicitly. Do not leave an unowned Prometheus configuration.

## Delivery gates

1. Replace mutable `latest` images in the legacy monitoring role or use pinned
   distribution packages with an explicit upgrade policy.
2. Implement generic discovery and private exporter endpoints.
3. Validate retention, cardinality and secret-redaction rules.
4. Run check-mode and a canary scrape on one VPS.
5. Verify dashboards and alerts on the active monitoring node.
6. Rehearse candidate-node recovery.
7. Converge remaining VPS nodes in batches.

This work is intentionally deferred until after the first MyCleanBot production
rollout.
