.PHONY: validate validate-strict render-check test check help

PYTHON ?= python3

help:
	@echo "Доступные цели:"
	@echo "  make validate        - проверить services.yml"
	@echo "  make validate-strict - проверить services.yml (предупреждения = ошибки)"
	@echo "  make render-check    - убедиться, что сгенерированные compose не разошлись"
	@echo "  make test            - прогнать smoke-тесты всех инструментов"
	@echo "  make check           - validate + render-check + test"

validate:
	$(PYTHON) tools/validate-services-yml/validate_services_yml.py

validate-strict:
	$(PYTHON) tools/validate-services-yml/validate_services_yml.py --strict

render-check:
	$(PYTHON) tools/render-compose/render_compose.py --stack all --check

test:
	$(PYTHON) -m unittest discover -s tools/validate-services-yml/tests -t .
	$(PYTHON) -m unittest discover -s tools/render-compose/tests -t .
	$(PYTHON) -m unittest discover -s tools/healthcheck/tests -t .

check: validate render-check test
