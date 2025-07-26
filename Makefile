# Makefile for matrix-hub
# Common developer tasks: setup env, run API, docs, lint/format, tests, DB migrations,
# and MCP-Gateway lifecycle (install/start/verify/stop).

SHELL := /bin/sh

# -------------------------------------------------------------------
# Configurable variables (override via environment or on the CLI)
# -------------------------------------------------------------------
PY 					?= python3
VENV_DIR 			?= .venv
UVICORN 			?= uvicorn
APP 				?= src.app:app
HOST 				?= 0.0.0.0
PORT 				?= 7300

RUFF 				?= ruff
PYTEST 				?= pytest
ALEMBIC 			?= alembic
ALEMBIC_INI 		?= alembic.ini
MKDOCS 				?= mkdocs
ENV_FILE 			?= .env

# Scripts & bash
BASH 				?= bash
SCRIPTS_DIR 		?= scripts

# MCP Gateway convenience
GATEWAY_PROJECT_DIR ?= mcpgateway
GATEWAY_HOST 		?= 0.0.0.0
GATEWAY_PORT 		?= 4444

# Load variables from .env for each command (if file exists)
# set -a exports all sourced variables into the environment.
ENV := set -a; [ -f $(ENV_FILE) ] && . $(ENV_FILE); set +a;

# Alembic - use ini if present
ALEMBIC_CFG := $(if $(wildcard $(ALEMBIC_INI)),-c $(ALEMBIC_INI),)

# Activate venv
activate = . $(VENV_DIR)/bin/activate

# -------------------------------------------------------------------
# Help
# -------------------------------------------------------------------
.PHONY: help
help:
	@echo "matrix-hub Makefile"
	@echo ""
	@echo "App:"
	@echo "  setup           Create virtualenv and install all dependencies"
	@echo "  dev             Run API with auto-reload"
	@echo "  run             Run API in foreground"
	@echo "  dev-sh          Run via scripts/run_dev.sh (loads .env, reload)"
	@echo "  prod-sh         Run via scripts/run_prod.sh (gunicorn/uvicorn)"
	@echo ""
	@echo "Docs:"
	@echo "  docs            Serve documentation with mkdocs (live reload)"
	@echo "  build-docs      Build static docs site"
	@echo "  docs-deploy     Publish docs to GitHub Pages (mkdocs gh-deploy)"
	@echo ""
	@echo "Quality:"
	@echo "  lint            Run Ruff static checks"
	@echo "  fmt             Auto-fix with Ruff"
	@echo "  test            Run tests with pytest"
	@echo ""
	@echo "DB (Alembic):"
	@echo "  migrate         Create Alembic revision (usage: make migrate m=\"msg\")"
	@echo "  upgrade         Apply Alembic migrations to head"
	@echo ""
	@echo "MCP-Gateway (local Python mode):"
	@echo "  deps            Install OS & Python deps (scripts/install-dependencies.sh)"
	@echo "  gateway-install   One-shot install & run (scripts/install_mcp_gateway.sh)"
	@echo "  gateway-setup     Clone/venv/install (scripts/setup-mcp-gateway.sh)"
	@echo "  gateway-start     Start gateway (scripts/start-mcp-gateway.sh)"
	@echo "  gateway-verify    Verify servers API (scripts/verify_servers.sh)"
	@echo "  gateway-stop      Stop gateway (scripts/stop-mcp-gateway.sh)"
	@echo ""
#	@echo "Variables (override like VAR=value make target):"
#	@echo "  HOST=$(HOST) PORT=$(PORT) VENV_DIR=$(VENV_DIR) GATEWAY_HOST=$(GATEWAY_HOST) GATEWAY_PORT=$(GATEWAY_PORT)"
#	@echo ""

# -------------------------------------------------------------------
# Environment setup
# -------------------------------------------------------------------
.PHONY: setup
setup:
	@test -d $(VENV_DIR) || $(PY) -m venv $(VENV_DIR)
	@echo "Activating virtualenv and installing dependencies..."
	@$(activate) && pip install --upgrade pip setuptools wheel
	@$(activate) && pip install ."[dev]"
	@echo "Setup complete. To activate:\n\tsource $(VENV_DIR)/bin/activate"

# -------------------------------------------------------------------
# App
# -------------------------------------------------------------------
.PHONY: dev
dev: setup
	@$(ENV) \
	$(activate) && \
	$(UVICORN) $(APP) --reload --host $${HOST:-$(HOST)} --port $${PORT:-$(PORT)} --proxy-headers

.PHONY: run
run: setup
	@$(ENV) \
	$(activate) && \
	$(UVICORN) $(APP) --host $${HOST:-$(HOST)} --port $${PORT:-$(PORT)} --proxy-headers

.PHONY: dev-sh
dev-sh:
	@$(BASH) $(SCRIPTS_DIR)/run_dev.sh

.PHONY: prod-sh
prod-sh:
	@$(BASH) $(SCRIPTS_DIR)/run_prod.sh

# -------------------------------------------------------------------
# Documentation
# -------------------------------------------------------------------
.PHONY: docs
docs: setup
	@$(ENV) \
	$(activate) && \
	$(MKDOCS) serve --dev-addr="$${HOST:-$(HOST)}:$${PORT:-$(PORT)}"

.PHONY: build-docs
build-docs: setup
	@$(activate) && $(MKDOCS) build

.PHONY: docs-deploy
docs-deploy: setup
	@$(activate) && $(MKDOCS) gh-deploy --force

# -------------------------------------------------------------------
# Quality
# -------------------------------------------------------------------
.PHONY: lint
lint:
	@$(activate) && $(RUFF) check src tests

.PHONY: fmt
fmt:
	@$(activate) && $(RUFF) check --fix src tests

# -------------------------------------------------------------------
# Tests
# -------------------------------------------------------------------
.PHONY: test
test: setup
	@$(ENV) \
	$(activate) && $(PYTEST) -q

# -------------------------------------------------------------------
# Database migrations (Alembic)
# -------------------------------------------------------------------
.PHONY: migrate
migrate: setup
	@[ -n "$(m)" ] || (echo "Usage: make migrate m=\"your message\""; exit 2)
	@$(ENV) \
	$(activate) && $(ALEMBIC) $(ALEMBIC_CFG) revision --autogenerate -m "$(m)"

.PHONY: upgrade
upgrade: setup
	@$(ENV) \
	$(activate) && $(ALEMBIC) $(ALEMBIC_CFG) upgrade head

# -------------------------------------------------------------------
# MCP-Gateway lifecycle (scripts)
# -------------------------------------------------------------------
.PHONY: deps
deps:
	@$(BASH) $(SCRIPTS_DIR)/install-dependencies.sh

.PHONY: gateway-install
gateway-install:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) HOST=$(GATEWAY_HOST) PORT=$(GATEWAY_PORT) \
	$(BASH) $(SCRIPTS_DIR)/install_mcp_gateway.sh

.PHONY: gateway-setup
gateway-setup:
	@$(BASH) $(SCRIPTS_DIR)/setup-mcp-gateway.sh

.PHONY: gateway-start
gateway-start:
	@$(BASH) $(SCRIPTS_DIR)/start-mcp-gateway.sh

.PHONY: gateway-verify
gateway-verify:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) $(BASH) $(SCRIPTS_DIR)/verify_servers.sh

.PHONY: gateway-stop
gateway-stop:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) $(BASH) $(SCRIPTS_DIR)/stop-mcp-gateway.sh