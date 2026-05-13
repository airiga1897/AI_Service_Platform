# VPS Roles

## VPS1

Production runtime. Initially hosts `aromaflow-work`; additional production stacks are added only after explicit approval.

## VPS2

Pre-production and hot-standby target. Hosts demo, MVP, and dev validation stacks when needed.

## VPS3

Optional management node for Ansible, monitoring, backup orchestration, and maintenance tooling. It is not required for application runtime.
