# VPS Roles

The target platform uses three VPS nodes. This layout comes from the historical
infrastructure roadmap and is part of the platform contract, not an incidental
deployment detail.

## VPS1

Production runtime in Latvia.

- Initial production stack: `aromaflow-work`.
- Primary application data starts here.
- Expected resource shape: 4 CPU / 4 GB RAM / 40 GB SSD.
- Additional production stacks are added only after explicit approval.
- Production changes must preserve backup, restore, TLS, edge routing, and
  rollback procedures.

## VPS2

Pre-production, hot-standby, and backup target in Kazakhstan.

- Hosts demo, MVP, and dev validation stacks when needed.
- Acts as hot standby/failover target for VPS1.
- Stores local backup copies before offsite S3 upload.
- Expected resource shape: 4 CPU / 4 GB RAM / 80 GB SSD.
- Must not silently mix preprod experiments with standby/backup responsibilities.

## VPS3

Management, monitoring, and orchestration node in Russia.

- Runs Ansible control workflows, monitoring, and backup orchestration.
- Can host Prometheus, Grafana, Loki/Promtail, Alertmanager, and Semaphore.
- Expected resource shape: 2 CPU / 2 GB RAM / 40 GB SSD.
- It is not an application runtime.
- If unavailable, VPS2 may temporarily take over recovery orchestration according
  to the failover runbook.

## External Storage

S3-compatible object storage is used for offsite backups in the 3-2-1 backup
model. Media storage migration to S3 is optional and separate from backup S3.

## VPN Presence

SoftEther is a platform VPN service on all three VPS nodes. The first preserved
setup is VPS1, but the target state is one SoftEther instance per VPS for local
client ingress and controlled country-specific egress.

Future countries may be added as VPN-only edge nodes. They should not run
product stacks; they only need the VPN edge, monitoring, firewall rules, and
backup for SoftEther configuration.
