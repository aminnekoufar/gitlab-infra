SHELL := /bin/bash
VENV   := .venv
APB    := $(VENV)/bin/ansible-playbook
INV    := inventories/prod/hosts.yml
VAULT  := --ask-vault-pass

.PHONY: help venv deps deps-dev syntax lint render ping check deploy common gitlab runner bundle vault-encrypt vault-edit health clean

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

venv: ## ساخت محیط پایتون
	python3 -m venv $(VENV) || uv venv $(VENV)

deps: venv ## نصب وابستگی‌های کنترل‌نود از requirements.txt
	@if command -v uv >/dev/null 2>&1; then \
	  uv pip install --python $(VENV)/bin/python -q -r requirements.txt; \
	else \
	  $(VENV)/bin/python -m pip install -q --upgrade pip; \
	  $(VENV)/bin/python -m pip install -q -r requirements.txt; \
	fi

deps-dev: deps ## نصب ابزار توسعه (ansible-lint)
	@if command -v uv >/dev/null 2>&1; then \
	  uv pip install --python $(VENV)/bin/python -q -r requirements-dev.txt; \
	else \
	  $(VENV)/bin/python -m pip install -q -r requirements-dev.txt; \
	fi

syntax: ## بررسی سینتکس playbook
	$(APB) -i $(INV) site.yml --syntax-check

lint: ## بررسی ansible-lint
	$(VENV)/bin/python -m ansiblelint site.yml

render: ## رندر تمپلیت‌ها + اعتبارسنجی TOML (بدون تماس با سرور)
	$(APB) -i $(INV) tests/render.yml -e ansible_become=false
	$(VENV)/bin/python -c "import tomllib,json,pathlib;tomllib.loads(pathlib.Path('.render/config.toml').read_text());json.loads(pathlib.Path('.render/daemon.json').read_text());print('TOML ok، JSON ok')"

ping: ## تست اتصال SSH به همه هاست‌ها
	$(VENV)/bin/ansible -i $(INV) all -m ping

check: ## اجرای آزمایشی (dry-run)
	$(APB) -i $(INV) site.yml --check --diff $(VAULT)

deploy: ## اجرای کامل
	$(APB) -i $(INV) site.yml $(VAULT)

common: ## فقط baseline
	$(APB) -i $(INV) site.yml --tags common $(VAULT)

gitlab: ## فقط GitLab server
	$(APB) -i $(INV) site.yml --tags gitlab $(VAULT)

runner: ## فقط Runner
	$(APB) -i $(INV) site.yml --tags runner $(VAULT)

bundle: ## ساخت باندل آفلاین (روی ماشین با اینترنت)
	./offline/build-bundle.sh

vault-encrypt: ## رمزگذاری vault.yml
	$(VENV)/bin/ansible-vault encrypt inventories/prod/group_vars/all/vault.yml

vault-edit: ## ویرایش vault.yml رمزشده
	$(VENV)/bin/ansible-vault edit inventories/prod/group_vars/all/vault.yml

health: ## چک سریع سلامت گیت‌لب
	@curl -sk -o /dev/null -w "%{http_code}\n" https://gitlab.intra.local/-/readiness 2>/dev/null || \
	 curl -s -o /dev/null -w "%{http_code}\n" http://gitlab.intra.local/users/sign_in

clean:
	rm -rf .venv offline/dist
