# Detached Job Logs Runbook

Use detached remote jobs for long-running service rollout and bootstrap-converge
commands. The operator wrappers print the generated job id and remote log path
when a job starts.

## Paths

- Temporary upload bundles: `/tmp/ai-service-platform.*`
- Durable job logs: `/var/log/ai-service-platform/jobs/<job-id>.log`
- Durable job state: `/var/lib/ai-service-platform/jobs/<job-id>/`
- Operator-local logs: `logs/`
- Operator-local scratch/test temp: `.tmp/`

## Completion Behavior

Successful jobs keep the rotated log and remove the state directory after the
wrapper observes completion. Failed jobs keep both the state directory and the
log for inspection.

Useful failed-job files:

- `run.sh`
- `pid`
- `exit_code`
- `done`
- `summary.jsonl`

## Baseline

The `platform_ops` Ansible role applies the directory baseline and installs
`/etc/logrotate.d/ai-service-platform` on every current and future VPS.
