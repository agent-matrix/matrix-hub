# Makefile for matrix-hub
# Common developer tasks: setup env, run API, docs, lint/format, tests, DB migrations,
# and MCP-Gateway lifecycle (install/start/verify/stop).

SHELL := /bin/sh

# -------------------------------------------------------------------
# Configurable variables (override via environment or on the CLI)
# -------------------------------------------------------------------
PY              ?= python3
VENV_DIR        ?= .venv
UVICORN         ?= uvicorn
APP             ?= src.app:app
HOST            ?= 0.0.0.0
PORT            ?= 7300

RUFF            ?= ruff
PYTEST          ?= pytest
ALEMBIC         ?= alembic
ALEMBIC_INI     ?= alembic.ini
MKDOCS          ?= mkdocs
ENV_FILE        ?= .env

# Scripts & bash
BASH            ?= bash
SCRIPTS_DIR     ?= scripts

# MCP Gateway convenience
GATEWAY_PROJECT_DIR ?= mcpgateway
GATEWAY_HOST        ?= 0.0.0.0
GATEWAY_PORT        ?= 4444

# Load variables from .env for each command (if file exists)
# set -a exports all sourced variables into the environment.
#ENV := set -a; [ -f $(ENV_FILE) ] && . $(ENV_FILE); set +a;
#ENV := if [ -f "$(ENV_FILE)" ]; then set -a; . "$(ENV_FILE)"; set +a; fi;
ENV := if [ -f "$(CURDIR)/$(ENV_FILE)" ]; then set -a; . "$(CURDIR)/$(ENV_FILE)"; set +a; fi;

# Alembic - use ini if present
ALEMBIC_CFG := $(if $(wildcard $(ALEMBIC_INI)),-c $(ALEMBIC_INI),)

# Activate venv
activate = . $(VENV_DIR)/bin/activate

# -------------------------------------------------------------------
# Ensure .env exists (copy from .env.example if missing)
# -------------------------------------------------------------------
.PHONY: ensure-env
ensure-env:
	@# Ensure $(ENV_FILE) exists in the project root; if not, copy from $(ENV_FILE).example
	@if [ ! -f $(ENV_FILE) ]; then \
		if [ -f $(ENV_FILE).example ]; then \
			cp $(ENV_FILE).example $(ENV_FILE); \
			echo "Created $(ENV_FILE) from $(ENV_FILE).example"; \
		else \
			echo "Warning: $(ENV_FILE) not found and no $(ENV_FILE).example to copy."; \
		fi; \
	fi

# -------------------------------------------------------------------
# Help
# -------------------------------------------------------------------
.PHONY: help
help:
	@echo "matrix-hub Makefile"
	@echo ""
	@echo "App:"
	@echo "  setup             Create virtualenv and install all dependencies"
	@echo "  index-init        Init index, create empty matrix/index.json"
	@echo "  dev               Run API with auto-reload"
	@echo "  run               Run API in foreground"
	@echo "  dev-sh            Run via scripts/run_dev.sh (loads .env, reload)"
	@echo "  prod-sh           Run via scripts/run_prod.sh (gunicorn/uvicorn)"
	@echo ""
	@echo "Catalog/Index:"
	@echo "  index-init        Create empty matrix/index.json"
	@echo "  index-add-inline  Add a LOCAL manifest file into the index"
	@echo "  index-add-url     Add a REMOTE manifest URL into the index"
	@echo ""
	@echo "  Examples:"
	@echo "    # Option A — Inline (local file)"
	@echo "    make index-add-inline MANIFEST=manifests/hello-world-sse.yaml"
	@echo ""
	@echo "    # Option B — by URL (GitHub Raw)"
	@echo "    make index-add-url \\"
	@echo "      ID=\"hello-world-sse\" VERSION=\"0.1.0\" NAME=\"Hello World (SSE)\" \\"
	@echo "      SUMMARY=\"Minimal SSE MCP server 'hello' tool\" \\"
	@echo "      MANIFEST_URL=\"https://raw.githubusercontent.com/ruslanmv/hello-mcp/main/matrix/hello-server.manifest.json\" \\"
	@echo "      HOMEPAGE=\"https://github.com/ruslanmv/hello-mcp\" \\"
	@echo "      PUBLISHER=\"ruslanmv\""
	@echo ""
	@echo "  Inspect/Serve:"
	@echo "    cat matrix/index.json | jq ."
	@echo "    make serve-index   # serves at http://localhost:8001/index.json"
	@echo ""
	@echo "Docs:"
	@echo "  docs              Serve documentation with mkdocs (live reload)"
	@echo "  build-docs        Build static docs site"
	@echo "  docs-deploy       Publish docs to GitHub Pages (mkdocs gh-deploy)"
	@echo ""
	@echo "Quality:"
	@echo "  lint              Run Ruff static checks"
	@echo "  fmt               Auto-fix with Ruff"
	@echo "  test              Run tests with pytest"
	@echo ""
	@echo "DB (Alembic):"
	@echo "  init-alembic      One-shot DB init → runs scripts/init_alembic.sh"
	@echo "  migrate           Create Alembic revision (usage: make migrate m=\"msg\")"
	@echo "  upgrade           Apply Alembic migrations to head"
	@echo ""
	@echo "MCP-Gateway (local Python mode):"
	@echo "  deps              Install OS & Python deps (scripts/install-dependencies.sh)"
	@echo "  gateway-install   One-shot install & run (scripts/install_mcp_gateway.sh)"
	@echo "  gateway-setup     Clone/venv/install (scripts/setup-mcp-gateway.sh)"
	@echo "  gateway-start     Start gateway (scripts/start-mcp-gateway.sh)"
	@echo "  gateway-token     Generate token (use as: eval \$$(make gateway-token))"
	@echo "  gateway-verify    Verify servers API (scripts/verify_servers.sh)"
	@echo "  gateway-stop      Stop gateway (scripts/stop-mcp-gateway.sh)"
	@echo ""
	@echo "Container:"
	@echo "  container-build   Build Docker image (scripts/build_container.sh)"
	@echo "  container-run     Run Docker container (scripts/run_container.sh)"
	@echo ""
	@echo "Monitoring:"
	@echo "  monitor-gateway   Periodically check MCP Gateway health on HOST:PORT (default 0.0.0.0:4444)"
	@echo "  monitor-hub       Periodically check Matrix Hub health on HOST:PORT (default 0.0.0.0:7300)"
	@echo "Logs:"
	@echo "  logs-gateway      Tail MCP Gateway logs (defaults to mcpgateway/logs/mcpgateway.log)"
	@echo "  logs-hub          Tail Matrix Hub logs (file or Docker; see script --help)"
	@echo ""
# -------------------------------------------------------------------
# Environment setup
# -------------------------------------------------------------------
#.PHONY: setup
#setup:
#	@test -d $(VENV_DIR) || $(PY) -m venv $(VENV_DIR)
#	@echo "Activating virtualenv and installing dependencies..."
#	@$(activate) && pip install --upgrade pip setuptools wheel
#	@$(activate) && pip install ."[dev]"
#	@echo "Setup complete. To activate:\n\tsource $(VENV_DIR)/bin/activate"
# This file signals that setup is complete. It depends on your requirements file.
$(VENV_DIR)/installed: pyproject.toml
	@echo "=> Stale or missing venv detected. Installing dependencies..."
	@test -d $(VENV_DIR) || $(PY) -m venv $(VENV_DIR)
	@. $(VENV_DIR)/bin/activate && pip install --upgrade pip setuptools wheel
	@. $(VENV_DIR)/bin/activate && pip install ."[dev]"
	@echo "Setup complete."
	@touch $@  # This creates the empty '.venv/installed' file

# A friendly alias to run the installation if needed.
.PHONY: setup
setup: $(VENV_DIR)/installed



# -------------------------------------------------------------------
# App
# -------------------------------------------------------------------
#.PHONY: dev
#dev: setup ensure-env
#	@$(ENV) \
#	$(activate) && \
#	$(UVICORN) $(APP) --reload --host $${HOST:-$(HOST)} --port $${PORT:-$(PORT)} --proxy-headers
# Make other commands depend on the stamp file, NOT the phony 'setup' target.
.PHONY: dev
dev: $(VENV_DIR)/installed ensure-env
	@$(ENV) \
	. $(VENV_DIR)/bin/activate && \
	$(UVICORN) $(APP) --reload --host $${HOST:-$(HOST)} --port $${PORT:-$(PORT)} --proxy-headers

.PHONY: run
run: setup ensure-env
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
docs: setup ensure-env
	@$(ENV) \
	$(activate) && \
	$(MKDOCS) serve --dev-addr="$${HOST:-$(HOST)}:$${PORT:-$(PORT)}"

.PHONY: build-docs
build-docs: setup ensure-env
	@$(activate) && $(MKDOCS) build

.PHONY: docs-deploy
docs-deploy: setup ensure-env
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
test: setup ensure-env
	@$(ENV) \
	$(activate) && $(PYTEST) -q

# -------------------------------------------------------------------
# Database migrations (Alembic)
# -------------------------------------------------------------------
.PHONY: init-alembic
init-alembic: setup ensure-env
	@echo "▶ Running initial Alembic setup…"
	@$(BASH) $(SCRIPTS_DIR)/init_alembic.sh $(if $(m),MSG="$(m)",)

.PHONY: migrate
migrate: setup ensure-env
	@[ -n "$(m)" ] || (echo "Usage: make migrate m=\"your message\""; exit 2)
	@$(ENV) \
	$(activate) && $(ALEMBIC) $(ALEMBIC_CFG) revision --autogenerate -m "$(m)"

.PHONY: upgrade
upgrade: setup ensure-env
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

.PHONY: gateway-token
gateway-token:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) $(BASH) $(SCRIPTS_DIR)/get-token-mcp-gateway.sh

.PHONY: gateway-verify
gateway-verify:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) $(BASH) $(SCRIPTS_DIR)/verify_servers.sh

.PHONY: gateway-stop
gateway-stop:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) $(BASH) $(SCRIPTS_DIR)/stop-mcp-gateway.sh


.PHONY: index-init index-add-url index-add-inline serve-index

INDEX_OUT ?= matrix/index.json

index-init:
	@python3 scripts/init.py init-empty --out $(INDEX_OUT)

index-add-url:
	@test -n "$(ID)" || (echo "ID is required"; exit 1)
	@test -n "$(VERSION)" || (echo "VERSION is required"; exit 1)
	@test -n "$(MANIFEST_URL)" || (echo "MANIFEST_URL is required"; exit 1)
	@python3 scripts/init.py add-url --out $(INDEX_OUT) \
		--id "$(ID)" --version "$(VERSION)" --name "$(NAME)" \
		--summary "$(SUMMARY)" --manifest-url "$(MANIFEST_URL)" \
		--homepage "$(HOMEPAGE)" --publisher "$(PUBLISHER)"

index-add-inline:
	@test -n "$(MANIFEST)" || (echo "MANIFEST=<path> is required"; exit 1)
	@python3 scripts/init.py add-inline --out $(INDEX_OUT) --manifest "$(MANIFEST)"

serve-index:
	@python3 -m http.server 8001




# ===================================================================
# Container image build & run (DO NOT remove/alter existing targets)
# ===================================================================

# -------- Build-time variables (override as needed) --------
IMAGE_NAME           ?= matrix-hub
IMAGE_TAG            ?= latest
HUB_INSTALL_TARGET   ?= prod      # prod | dev
SKIP_GATEWAY_SETUP   ?= 0         # 0 | 1
PLATFORM             ?=
NO_CACHE             ?= 0         # 0 | 1
PULL                 ?= 0         # 0 | 1
BUILDX               ?= 0         # 0 | 1

# -------- Run-time variables (override as needed) ----------
CONTAINER_NAME       ?= matrix-hub
APP_HOST_PORT        ?= 7300
GW_HOST_PORT         ?= 4444
DATA_VOLUME          ?= matrixhub_data
GW_VOLUME            ?=           # optional (e.g., mcpgw_data)
NETWORK_NAME         ?=
RESTART_POLICY       ?= unless-stopped
DETACH               ?= 1         # 1=detached, 0=foreground
PULL_RUNTIME         ?= 0         # docker pull before run
REPLACE              ?= 1         # stop/remove existing container if present
GW_SKIP              ?= 0         # 1 to skip embedded gateway

# Build Docker image via scripts/build_container.sh
.PHONY: container-build
container-build:
	@echo "Building container image $(IMAGE_NAME):$(IMAGE_TAG) ..."
	@$(BASH) $(SCRIPTS_DIR)/build_container.sh \
		--image "$(IMAGE_NAME)" \
		--tag "$(IMAGE_TAG)" \
		$(if $(filter dev,$(HUB_INSTALL_TARGET)),--dev,) \
		$(if $(filter 1,$(SKIP_GATEWAY_SETUP)),--skip-gateway-setup,) \
		$(if $(PLATFORM),--platform "$(PLATFORM)",) \
		$(if $(filter 1,$(NO_CACHE)),--no-cache,) \
		$(if $(filter 1,$(PULL)),--pull,) \
		$(if $(filter 1,$(BUILDX)),--buildx,)

# Run Docker container via scripts/run_container.sh
.PHONY: container-run
container-run:
	@echo "Running container $(CONTAINER_NAME) from $(IMAGE_NAME):$(IMAGE_TAG) ..."
	@$(BASH) $(SCRIPTS_DIR)/run_container.sh \
		--image "$(IMAGE_NAME)" \
		--tag "$(IMAGE_TAG)" \
		--name "$(CONTAINER_NAME)" \
		--app-port "$(APP_HOST_PORT)" \
		$(if $(filter 1,$(GW_SKIP)),--skip-gateway,--gw-port "$(GW_HOST_PORT)") \
		--env-file "$(ENV_FILE)" \
		--data-volume "$(DATA_VOLUME)" \
		$(if $(GW_VOLUME),--gw-volume "$(GW_VOLUME)",) \
		$(if $(NETWORK_NAME),--network "$(NETWORK_NAME)",) \
		--restart "$(RESTART_POLICY)" \
		$(if $(filter 1,$(DETACH)),-d,--foreground) \
		$(if $(filter 1,$(PULL_RUNTIME)),--pull,) \
		$(if $(filter 0,$(REPLACE)),--no-replace,)

# -------------------------------------------------------------------
# Monitoring (Gateway & Matrix Hub)
# -------------------------------------------------------------------
# seconds between checks (override: INTERVAL=2)
MONITOR_INTERVAL ?= 5
# optional extra flags passed to scripts (e.g., --once)
MONITOR_ARGS     ?=

.PHONY: monitor-gateway
monitor-gateway:
	@HOST=$(GATEWAY_HOST) PORT=$(GATEWAY_PORT) INTERVAL=$${INTERVAL:-$(MONITOR_INTERVAL)} \
	$(BASH) $(SCRIPTS_DIR)/monitor-gateway.sh $(MONITOR_ARGS)

.PHONY: monitor-hub
monitor-hub:
	@HOST=$${HOST:-$(HOST)} PORT=$${PORT:-$(PORT)} INTERVAL=$${INTERVAL:-$(MONITOR_INTERVAL)} \
	$(BASH) $(SCRIPTS_DIR)/monitor-matrixhub.sh $(MONITOR_ARGS)

# -------------------------------------------------------------------
# Logs (Gateway & Matrix Hub)
# -------------------------------------------------------------------

LOG_LINES ?= 200

.PHONY: logs-gateway
logs-gateway:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) LINES=$${LINES:-$(LOG_LINES)} \
	$(BASH) $(SCRIPTS_DIR)/logs-gateway.sh $(ARGS)

.PHONY: logs-hub
logs-hub:
	@CONTAINER_NAME=$${CONTAINER_NAME:-$(CONTAINER_NAME)} LINES=$${LINES:-$(LOG_LINES)} \
	$(BASH) $(SCRIPTS_DIR)/logs-hub.sh $(ARGS)
