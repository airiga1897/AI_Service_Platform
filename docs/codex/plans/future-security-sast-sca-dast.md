# Future plan: SAST, SCA/OSA and DAST

Пока поднимаем VPS, security-layer не внедряем в execution path. План
сохраняется для дальнейшей реализации.

## Summary

Добавить отдельный security pipeline поверх текущего `make check`, сначала в
режиме report-only. Цель — видеть риски в shell/Python/YAML/GitHub
Actions/Ansible/Docker/Compose/edge-конфигах, не ломая текущий bootstrap/deploy
поток ложными срабатываниями.

## Decisions

- Первый rollout: report-only.
- DAST target: local rendered edge, не production.
- Production/VPS endpoints не сканировать без отдельного разрешения.
- `Validate` workflow не заменять, а дополнить отдельным `Security` workflow.
- Критичные категории для будущего must-fix: secrets, critical CVE, unsafe
  GitHub Actions permissions, dangerous shell patterns.

## Planned Checks

- SAST: Semgrep, Bandit, ShellCheck.
- SCA/OSA: Dependabot, pip-audit, Trivy filesystem scan.
- Secrets: Gitleaks / Trivy secret scan.
- IaC/config: Checkov или Trivy config scan для GitHub Actions, Docker Compose,
  Ansible/YAML.
- DAST: OWASP ZAP baseline только против local rendered edge или безопасного
  staging-like endpoint.

## Notes

- Не хранить SARIF/secrets artifacts в repo.
- Если понадобится baseline/allowlist, хранить его явно и ревьюить изменения.
- `make check` должен остаться быстрым и независимым.
- Позже можно добавить `make security` как агрегатор security-проверок.
