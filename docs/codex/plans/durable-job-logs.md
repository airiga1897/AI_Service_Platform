# Durable Detached Job Logs

Long-running remote service and bootstrap-converge commands run as detached
jobs on the active orchestration node. Transfer bundles remain in `/tmp`, but
durable job artifacts live under platform-owned paths:

- Logs: `/var/log/ai-service-platform/jobs/<job-id>.log`
- State: `/var/lib/ai-service-platform/jobs/<job-id>/`

Successful jobs remove their state directory after the operator wrapper has
observed completion. The rotated log remains for audit/debug. Failed jobs keep
both state and log so the operator can inspect `run.sh`, `pid`, `exit_code`,
`done`, and `summary.jsonl` when present.

The `platform_ops` Ansible role applies this baseline to every VPS and installs
`/etc/logrotate.d/ai-service-platform`. Operator-local run logs belong in
`logs/`; `.tmp/` is reserved for disposable test/cache scratch data.
