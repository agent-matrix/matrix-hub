# ====================================================================================
#
#   There is no spoon... only the construct.
#   This is the control program for the Matrix Hub.
#
#   TRANSMISSION >> Access available programs with 'make help'
#
# ====================================================================================

SHELL := /bin/sh

# System & Environment
BRIGHT_GREEN    := $(shell tput -T screen setaf 10)
DIM_GREEN       := $(shell tput -T screen setaf 2)
RESET           := $(shell tput -T screen sgr0)

# Configurable Constants
PY                ?= python3
VENV_DIR          ?= .venv
UVICORN           ?= uvicorn
APP               ?= src.app:app
HOST              ?= 0.0.0.0
PORT              ?= 8000

RUFF              ?= ruff
PYTEST            ?= pytest
ALEMBIC           ?= alembic
ALEMBIC_INI       ?= alembic.ini
MKDOCS            ?= mkdocs
ENV_FILE          ?= .env

BASH              ?= bash
SCRIPTS_DIR       ?= scripts

# MCP Gateway
GATEWAY_PROJECT_DIR ?= mcpgateway
GATEWAY_HOST        ?= 0.0.0.0
GATEWAY_PORT        ?= 4444
GATEWAY_DIR         := $(CURDIR)/$(GATEWAY_PROJECT_DIR)
GATEWAY_VENV_OK     := $(GATEWAY_DIR)/.venv/bin/activate

SKIP_GATEWAY        ?= 0

# WSL friendliness for uv: avoid the noisy hardlink-fallback warning when
# the project tree and uv cache are on different filesystems (typical for
# /mnt/c WSL projects). Operators can override.
export UV_LINK_MODE ?= copy

ENV := if [ -f "$(CURDIR)/$(ENV_FILE)" ]; then set -a; . "$(CURDIR)/$(ENV_FILE)"; set +a; fi;
ALEMBIC_CFG := $(if $(wildcard $(ALEMBIC_INI)),-c $(ALEMBIC_INI),)
activate = . $(VENV_DIR)/bin/activate

.PHONY: ensure-env
ensure-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		if [ -f $(ENV_FILE).example.local ]; then \
			cp $(ENV_FILE).example.local $(ENV_FILE); \
			echo "$(DIM_GREEN)-> Materialized $(ENV_FILE) from $(ENV_FILE).example.local.$(RESET)"; \
		elif [ -f $(ENV_FILE).example ]; then \
			cp $(ENV_FILE).example $(ENV_FILE); \
			echo "$(DIM_GREEN)-> Materialized $(ENV_FILE) from template.$(RESET)"; \
		else \
			echo "$(BRIGHT_GREEN)Warning: No $(ENV_FILE) or $(ENV_FILE).example found.$(RESET)"; \
		fi; \
	fi

.PHONY: fix-line-endings
fix-line-endings:
	@if find $(SCRIPTS_DIR) -name '*.sh' -print0 2>/dev/null | xargs -0 grep -lI $$'\r' 2>/dev/null | grep -q .; then \
		echo "$(DIM_GREEN)-> Stripping CRLF from $(SCRIPTS_DIR)/*.sh ...$(RESET)"; \
		find $(SCRIPTS_DIR) -name '*.sh' -print0 | xargs -0 sed -i 's/\r$$//' ; \
	fi

# Auto-install the MCP Gateway if it isn't already cloned + bootstrapped.
# Crucially we pass `--no-start --non-interactive` so install does NOT
# launch the gateway service — that's `make run`'s job. Otherwise
# `make install && make run` collides on port 4444.
.PHONY: gateway-ensure
gateway-ensure: fix-line-endings
	@if [ "$(SKIP_GATEWAY)" = "1" ]; then \
		echo "$(DIM_GREEN)-> SKIP_GATEWAY=1; not installing the MCP Gateway.$(RESET)"; \
	elif [ -f "$(GATEWAY_VENV_OK)" ]; then \
		: ; \
	else \
		if [ -d "$(GATEWAY_DIR)" ] && [ ! -f "$(GATEWAY_VENV_OK)" ]; then \
			echo "$(DIM_GREEN)-> Detected half-built gateway at $(GATEWAY_DIR); wiping for clean retry...$(RESET)"; \
			rm -rf "$(GATEWAY_DIR)"; \
		fi; \
		echo "$(DIM_GREEN)-> MCP Gateway not bootstrapped at $(GATEWAY_DIR); running one-time setup (~1-3 min)...$(RESET)"; \
		$(BASH) $(SCRIPTS_DIR)/setup-mcp-gateway.sh --no-start --non-interactive; \
	fi

.PHONY: help
help:
	@echo
	@echo "$(BRIGHT_GREEN)M A T R I X - H U B ::: C O N T R O L   P R O G R A M$(RESET)"
	@echo
	@printf "$(BRIGHT_GREEN)  %-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "PROGRAM" "DESCRIPTION"
	@printf "$(BRIGHT_GREEN)  %-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "--------------------" "--------------------------------------------------------"
	@echo
	@echo "$(BRIGHT_GREEN)Core Operations$(RESET)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "install" "📦 Full prod-ready install: Hub venv + Gateway + .env (does NOT start)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "bootstrap" "🌱 Alias for install (kept for backwards compatibility)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "setup" "🔌 Hub venv only (legacy / advanced)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "build" "🏗️  Build Docker container (alias for container-build)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "dev" "😎 Operator mode (Hub + Gateway, live reload)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "dev-hub" "🚀 Hub-only dev (skip Gateway, fast iteration)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "run" "▶️  Execute main program (Hub + Gateway, prod mode)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "run-hub" "▶️  Hub-only prod (skip Gateway)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "stop" "🛑 Stop Hub + Gateway processes (PID files + name patterns + ports)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "clean" "🧹 Remove venvs, gateway clone, caches, data (keeps .env)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "clean-all" "💣 Like clean, but ALSO removes .env and .env.bak.* files"
	@echo
	@echo "$(BRIGHT_GREEN)Index Management$(RESET)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "index-init" "🌱 Create an empty index construct"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "index-add-inline" "📦 Add a local manifest file to the index"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "index-add-url" "🔗 Add a remote manifest URL to the index"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "serve-index" "📡 Broadcast the index construct (localhost:8001)"
	@echo
	@echo "$(BRIGHT_GREEN)Quality & Testing$(RESET)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "lint" "🕶️ Scan for Agents (static checks)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "fmt" "🥄 Bend the code (auto-format)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "test" "🥋 Enter the Dojo (run simulations with pytest)"
	@echo
	@echo "$(BRIGHT_GREEN)Architect's Database (Alembic)$(RESET)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "init-alembic" "🔑 Initialize the database construct"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "migrate" "✍️ Log a change in reality (create revision)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "upgrade" "⏫ Apply all changes to reality (migrate to head)"
	@echo
	@echo "$(BRIGHT_GREEN)Zion Gateway (MCP)$(RESET)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "gateway-setup" "🛠️  Construct the gateway from source (and START it)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "gateway-start" "📡 Open gateway to Zion"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "gateway-token" "🔑 Generate access token"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "gateway-verify" "✔️  Verify gateway connection"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "gateway-stop" "🛑 Close gateway to Zion"
	@echo
	@echo "$(BRIGHT_GREEN)Residual Self-Image (Container)$(RESET)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "container-build" "🏗️  Construct a containerized reality"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "container-run" "🚢 Deploy program into the Matrix"
	@echo
	@echo "$(BRIGHT_GREEN)Cloud Deployment (OCI)$(RESET)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "deploy" "🚀 Deploy latest image to OCI production"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "deploy-tag" "🏷️  Deploy specific tag: make deploy-tag TAG=v1.2.3"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "deploy-dry" "🔍 Dry-run deploy (print commands only)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "deploy-status" "📊 Check production health & status"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "deploy-logs" "📜 Tail production container logs"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "deploy-ssh" "🔐 SSH into production instance"
	@echo
	@echo "$(BRIGHT_GREEN)Monitoring & Logs$(RESET)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "monitor-gateway" "🛰️  Monitor gateway health"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "monitor-hub" "💻 Monitor hub health"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "logs-gateway" "📜 Tail gateway logs"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "logs-hub" "🧾 Tail hub logs"
	@echo

# ============================================================================
# Hub venv construction — verbose progress, uv-aware.
# ============================================================================
$(VENV_DIR)/installed: pyproject.toml
	@echo "$(BRIGHT_GREEN)→ Building Hub venv at $(VENV_DIR)/ $(RESET)"
	@if command -v uv >/dev/null 2>&1; then \
		echo "$(DIM_GREEN)  [1/3] Creating venv via 'uv venv --python 3.11' (fast)...$(RESET)"; \
		test -d $(VENV_DIR) || uv venv --python 3.11 $(VENV_DIR); \
		echo "$(DIM_GREEN)  [2/3] Upgrading pip/setuptools/wheel via uv pip...$(RESET)"; \
		. $(VENV_DIR)/bin/activate && uv pip install --upgrade pip setuptools wheel; \
		echo "$(DIM_GREEN)  [3/3] Installing matrix-hub[dev] (~30-90s on first run)...$(RESET)"; \
		. $(VENV_DIR)/bin/activate && uv pip install --upgrade -e ".[dev]"; \
	else \
		echo "$(DIM_GREEN)  [1/3] Creating venv via 'python -m venv' ($(PY))...$(RESET)"; \
		test -d $(VENV_DIR) || $(PY) -m venv $(VENV_DIR); \
		echo "$(DIM_GREEN)  [2/3] Upgrading pip/setuptools/wheel...$(RESET)"; \
		. $(VENV_DIR)/bin/activate && pip install --upgrade pip setuptools wheel; \
		echo "$(DIM_GREEN)  [3/3] Installing matrix-hub[dev] (~60-180s on first run)...$(RESET)"; \
		. $(VENV_DIR)/bin/activate && pip install --upgrade -e ".[dev]"; \
	fi
	@echo "$(BRIGHT_GREEN)✓ Hub venv ready. You are The One.$(RESET)"
	@touch $@

# Headline target. `make install` does everything a fresh clone needs to
# be ready for `make run`. It builds and configures, but does NOT start
# any services — `make run` is the only place that does that.
.PHONY: install bootstrap setup
install: fix-line-endings $(VENV_DIR)/installed gateway-ensure ensure-env
	@echo "$(BRIGHT_GREEN)Install complete (services NOT started).$(RESET)"
	@echo "$(DIM_GREEN)  make run         — Hub + Gateway, prod mode$(RESET)"
	@echo "$(DIM_GREEN)  make dev         — Hub + Gateway, live reload$(RESET)"
	@echo "$(DIM_GREEN)  make run-hub     — Hub only (skip Gateway)$(RESET)"
	@echo "$(DIM_GREEN)  make stop        — stop everything$(RESET)"

bootstrap: install
setup: $(VENV_DIR)/installed

# ============================================================================
# Stop everything (Hub + Gateway). Tries three signals in order:
#   1. PID files written by start scripts (mcpgateway.pid, .gunicorn pid).
#   2. SIGTERM by process-name pattern (covers gunicorn workers,
#      uvicorn, mcpgateway CLI, run_prod.sh / run_dev.sh wrappers).
#   3. After a 2 s grace, force-kill anything still listening on our
#      well-known ports (443, 4444, $(PORT)).
# Idempotent and safe to run when nothing is up.
# ============================================================================
.PHONY: stop
# IMPORTANT — pgrep / pkill `-f <pattern>` is a self-match landmine.
# A shell that runs `pkill -f 'mcpgateway --host'` has the literal
# substring "mcpgateway --host" in its OWN command line, so pkill -f
# matches and kills the recipe's own parent shell — operator saw
# `make: *** [stop] Terminated` mid-recipe and the port-cleanup never ran.
#
# So we use `pgrep -x <basename>` (exact match against the executable's
# argv[0] basename) which is immune to argv contents AND to whatever
# other shells happen to be sitting around. We only fall back to `-f`
# for the run_prod.sh / run_dev.sh wrappers, with the [r]un_prod regex
# bracket trick to keep pgrep from self-matching.
stop:
	@echo "$(DIM_GREEN)-> Stopping Matrix Hub + MCP Gateway processes...$(RESET)"
	@# (1) PID file from setup-mcp-gateway.sh
	@if [ -f $(GATEWAY_PROJECT_DIR)/mcpgateway.pid ]; then \
		pid=$$(cat $(GATEWAY_PROJECT_DIR)/mcpgateway.pid 2>/dev/null); \
		if [ -n "$$pid" ] && kill -0 "$$pid" 2>/dev/null; then \
			echo "  killing mcpgateway from PID file: $$pid"; \
			kill "$$pid" 2>/dev/null || true; \
		fi; \
		rm -f $(GATEWAY_PROJECT_DIR)/mcpgateway.pid; \
	fi
	@# (2) Exact-basename matches (immune to argv self-match).
	@for name in mcpgateway gunicorn uvicorn supervisord; do \
		pids=$$(pgrep -x "$$name" 2>/dev/null | tr '\n' ' '); \
		if [ -n "$$pids" ]; then \
			echo "  TERM $$name: $$pids"; \
			pkill -TERM -x "$$name" 2>/dev/null || true; \
		fi; \
	done
	@# (3) Wrapper scripts (use [r] regex trick to dodge self-match).
	@for pat in '[r]un_prod\.sh' '[r]un_dev\.sh'; do \
		pids=$$(pgrep -f "$$pat" 2>/dev/null | tr '\n' ' '); \
		if [ -n "$$pids" ]; then \
			echo "  TERM [$$pat]: $$pids"; \
			pkill -TERM -f "$$pat" 2>/dev/null || true; \
		fi; \
	done
	@sleep 2
	@if command -v lsof >/dev/null 2>&1; then \
		for port in 443 4444 $(PORT); do \
			pids=$$(lsof -nP -iTCP:$$port -sTCP:LISTEN -t 2>/dev/null); \
			if [ -n "$$pids" ]; then \
				echo "  KILL -9 leftover on :$$port: $$pids"; \
				echo "$$pids" | xargs -r kill -9 2>/dev/null || true; \
			fi; \
		done; \
	elif command -v fuser >/dev/null 2>&1; then \
		for port in 443 4444 $(PORT); do \
			fuser -k -KILL "$$port/tcp" 2>/dev/null || true; \
		done; \
	fi
	@echo "$(BRIGHT_GREEN)✓ Stopped.$(RESET)"

# ============================================================================
# Tear-down
# ============================================================================
.PHONY: clean clean-all
clean: stop
	@echo "$(DIM_GREEN)-> Removing Hub venv ($(VENV_DIR)/), gateway clone ($(GATEWAY_PROJECT_DIR)/), data, and Python caches...$(RESET)"
	@rm -rf $(VENV_DIR)
	@rm -rf $(GATEWAY_PROJECT_DIR)
	@rm -rf data
	@rm -rf .pytest_cache .ruff_cache .mypy_cache build dist
	@find . -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -type d -name '*.egg-info' -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -type f -name '*.pyc' -delete 2>/dev/null || true
	@echo "$(BRIGHT_GREEN)Clean complete. .env preserved. Run \`make install\` to rebuild.$(RESET)"

clean-all: clean
	@echo "$(DIM_GREEN)-> Also removing $(ENV_FILE) and $(ENV_FILE).bak.* ...$(RESET)"
	@rm -f $(ENV_FILE)
	@rm -f $(ENV_FILE).bak.* 2>/dev/null || true
	@echo "$(BRIGHT_GREEN)Full reset complete. Run \`make install\` to start over.$(RESET)"

# Main Program Execution
.PHONY: dev dev-hub run run-hub
dev: $(VENV_DIR)/installed ensure-env gateway-ensure
	@echo "$(DIM_GREEN)-> Entering Operator Mode... live reload enabled.$(RESET)"
	@$(BASH) $(SCRIPTS_DIR)/run_dev.sh

dev-hub: $(VENV_DIR)/installed ensure-env fix-line-endings
	@echo "$(DIM_GREEN)-> Hub-only dev mode (Gateway skipped).$(RESET)"
	@GATEWAY_SKIP_START=1 $(BASH) $(SCRIPTS_DIR)/run_dev.sh

run: $(VENV_DIR)/installed ensure-env gateway-ensure
	@echo "$(DIM_GREEN)-> Executing main program...$(RESET)"
	@$(BASH) $(SCRIPTS_DIR)/run_prod.sh

run-hub: $(VENV_DIR)/installed ensure-env fix-line-endings
	@echo "$(DIM_GREEN)-> Hub-only prod mode (Gateway skipped).$(RESET)"
	@GATEWAY_SKIP_START=1 $(BASH) $(SCRIPTS_DIR)/run_prod.sh

.PHONY: docs build-docs docs-deploy
docs: $(VENV_DIR)/installed ensure-env
	@echo "$(DIM_GREEN)-> Accessing the Architect's records...$(RESET)"
	@$(ENV) \
	$(activate) && \
	$(MKDOCS) serve --dev-addr="$${HOST:-$(HOST)}:$${PORT:-$(PORT)}"
build-docs: $(VENV_DIR)/installed ensure-env
	@echo "$(DIM_GREEN)-> Compiling the Architect's records...$(RESET)"
	@$(activate) && $(MKDOCS) build
docs-deploy: $(VENV_DIR)/installed ensure-env
	@echo "$(DIM_GREEN)-> Broadcasting records to Zion's mainframe...$(RESET)"
	@$(activate) && $(MKDOCS) gh-deploy --force

.PHONY: lint fmt
lint:
	@echo "$(DIM_GREEN)-> Scanning for Agents...$(RESET)"
	@$(activate) && $(RUFF) check src tests
fmt:
	@echo "$(DIM_GREEN)-> Bending the code...$(RESET)"
	@$(activate) && $(RUFF) check --fix src tests

.PHONY: test
test: $(VENV_DIR)/installed ensure-env
	@echo "$(DIM_GREEN)-> Entering the Dojo... initiating simulations...$(RESET)"
	@$(ENV) \
	$(activate) && $(PYTEST) -q

.PHONY: init-alembic
init-alembic: $(VENV_DIR)/installed ensure-env
	@echo "$(DIM_GREEN)-> Initializing the database construct...$(RESET)"
	@$(BASH) $(SCRIPTS_DIR)/init_alembic.sh $(if $(m),MSG="$(m)",)

.PHONY: migrate
migrate: $(VENV_DIR)/installed ensure-env
	@[ -n "$(m)" ] || (echo "$(BRIGHT_GREEN)Operator, provide a log entry: make migrate m=\"your message\"$(RESET)"; exit 2)
	@echo "$(DIM_GREEN)-> Logging a change in reality: $(m)...$(RESET)"
	@$(ENV) \
	$(activate) && $(ALEMBIC) $(ALEMBIC_CFG) revision --autogenerate -m "$(m)"

.PHONY: upgrade
upgrade: $(VENV_DIR)/installed ensure-env
	@echo "$(DIM_GREEN)-> Applying all changes to reality...$(RESET)"
	@$(ENV) \
	$(activate) && $(ALEMBIC) $(ALEMBIC_CFG) upgrade head

# Idempotent schema repair for production Postgres DBs whose
# alembic_version drifted past a deleted revision (symptom:
# "column entity.manifest_blob_ref does not exist" → 502). Reads
# DATABASE_URL from .env. Use `make repair-db DRY=1` to preview.
.PHONY: repair-db
repair-db: $(VENV_DIR)/installed ensure-env
	@echo "$(DIM_GREEN)-> Repairing DB schema (idempotent)...$(RESET)"
	@$(activate) && $(VENV_DIR)/bin/python $(SCRIPTS_DIR)/repair_db.py $(if $(DRY),--dry-run,)

# Zion Gateway (MCP) Lifecycle
.PHONY: deps gateway-install gateway-setup gateway-start gateway-token gateway-verify gateway-stop
deps: fix-line-endings
	@$(BASH) $(SCRIPTS_DIR)/install-dependencies.sh
gateway-install: fix-line-endings
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) HOST=$(GATEWAY_HOST) PORT=$(GATEWAY_PORT) \
	$(BASH) $(SCRIPTS_DIR)/install_mcp_gateway.sh
# Manual standalone gateway-setup STARTS the gateway (matching the
# pre-Makefile-orchestration behavior). For the Make-driven install path,
# `gateway-ensure` calls the same script with --no-start.
gateway-setup: fix-line-endings
	@$(BASH) $(SCRIPTS_DIR)/setup-mcp-gateway.sh --non-interactive
gateway-start: fix-line-endings
	@$(BASH) $(SCRIPTS_DIR)/start-mcp-gateway.sh
gateway-token: fix-line-endings
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) $(BASH) $(SCRIPTS_DIR)/get-token-mcp-gateway.sh
gateway-verify: fix-line-endings
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) $(BASH) $(SCRIPTS_DIR)/verify_servers.sh
gateway-stop: fix-line-endings
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
	@echo "$(DIM_GREEN)-> Broadcasting index construct at http://localhost:8001/index.json...$(RESET)"
	@python3 -m http.server 8001

IMAGE_NAME            ?= matrix-hub
IMAGE_TAG             ?= latest
HUB_INSTALL_TARGET    ?= prod
SKIP_GATEWAY_SETUP    ?= 0
PLATFORM              ?=
NO_CACHE              ?= 0
PULL                  ?= 0
BUILDX                ?= 0
CONTAINER_NAME        ?= matrix-hub
APP_HOST_PORT         ?= 443
GW_HOST_PORT          ?= 4444
DATA_VOLUME           ?= matrixhub_data
GW_VOLUME             ?=
NETWORK_NAME          ?=
RESTART_POLICY        ?= unless-stopped
DETACH                ?= 1
PULL_RUNTIME          ?= 0
REPLACE               ?= 1
GW_SKIP               ?= 0

.PHONY: build container-build
build: container-build
container-build: fix-line-endings
	@echo "$(DIM_GREEN)-> Compiling residual self-image into container $(IMAGE_NAME):$(IMAGE_TAG)...$(RESET)"
	@$(BASH) $(SCRIPTS_DIR)/build_container.sh \
		--image "$(IMAGE_NAME)" \
		--tag "$(IMAGE_TAG)" \
		$(if $(filter dev,$(HUB_INSTALL_TARGET)),--dev,) \
		$(if $(filter 1,$(SKIP_GATEWAY_SETUP)),--skip-gateway-setup,) \
		$(if $(PLATFORM),--platform "$(PLATFORM)",) \
		$(if $(filter 1,$(NO_CACHE)),--no-cache,) \
		$(if $(filter 1,$(PULL)),--pull,) \
		$(if $(filter 1,$(BUILDX)),--buildx,)

.PHONY: container-run
container-run: fix-line-endings
	@echo "$(DIM_GREEN)-> Deploying program $(CONTAINER_NAME) into the Matrix...$(RESET)"
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

MONITOR_INTERVAL ?= 5
MONITOR_ARGS     ?=
LOG_LINES ?= 200

.PHONY: monitor-gateway monitor-hub logs-gateway logs-hub
monitor-gateway:
	@HOST=$(GATEWAY_HOST) PORT=$(GATEWAY_PORT) INTERVAL=$${INTERVAL:-$(MONITOR_INTERVAL)} \
	$(BASH) $(SCRIPTS_DIR)/monitor-gateway.sh $(MONITOR_ARGS)
monitor-hub:
	@HOST=$${HOST:-$(HOST)} PORT=$${PORT:-$(PORT)} INTERVAL=$${INTERVAL:-$(MONITOR_INTERVAL)} \
	$(BASH) $(SCRIPTS_DIR)/monitor-matrixhub.sh $(MONITOR_ARGS)
logs-gateway:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) LINES=$${LINES:-$(LOG_LINES)} \
	$(BASH) $(SCRIPTS_DIR)/logs-gateway.sh $(ARGS)
logs-hub:
	@CONTAINER_NAME=$${CONTAINER_NAME:-$(CONTAINER_NAME)} LINES=$${LINES:-$(LOG_LINES)} \
	$(BASH) $(SCRIPTS_DIR)/logs-hub.sh $(ARGS)

OCI_HOST        ?= 129.213.165.60
OCI_USER        ?= opc
OCI_SSH_KEY     ?= ~/.ssh/id_rsa
DEPLOY_IMAGE    ?= ruslanmv/matrix-hub
DEPLOY_TAG      ?= latest
DEPLOY_CONTAINER ?= matrix-hub

.PHONY: deploy deploy-tag deploy-dry deploy-status deploy-logs deploy-ssh deploy-setup

deploy:
	@echo "$(BRIGHT_GREEN)Deploying $(DEPLOY_IMAGE):$(DEPLOY_TAG) to OCI $(OCI_HOST)...$(RESET)"
	@IMAGE_TAG=$(DEPLOY_TAG) DOCKER_IMAGE=$(DEPLOY_IMAGE) CONTAINER_NAME=$(DEPLOY_CONTAINER) \
	 OCI_HOST=$(OCI_HOST) OCI_USER=$(OCI_USER) OCI_SSH_KEY=$(OCI_SSH_KEY) \
	 $(BASH) $(SCRIPTS_DIR)/deploy_oci.sh

deploy-tag:
	@test -n "$(TAG)" || (echo "Usage: make deploy-tag TAG=v1.2.3"; exit 2)
	@echo "$(BRIGHT_GREEN)Deploying $(DEPLOY_IMAGE):$(TAG) to OCI $(OCI_HOST)...$(RESET)"
	@IMAGE_TAG=$(TAG) DOCKER_IMAGE=$(DEPLOY_IMAGE) CONTAINER_NAME=$(DEPLOY_CONTAINER) \
	 OCI_HOST=$(OCI_HOST) OCI_USER=$(OCI_USER) OCI_SSH_KEY=$(OCI_SSH_KEY) \
	 $(BASH) $(SCRIPTS_DIR)/deploy_oci.sh

deploy-dry:
	@echo "$(DIM_GREEN)Dry-run deployment (no changes will be made)...$(RESET)"
	@DRY_RUN=1 IMAGE_TAG=$(DEPLOY_TAG) DOCKER_IMAGE=$(DEPLOY_IMAGE) CONTAINER_NAME=$(DEPLOY_CONTAINER) \
	 OCI_HOST=$(OCI_HOST) OCI_USER=$(OCI_USER) OCI_SSH_KEY=$(OCI_SSH_KEY) \
	 $(BASH) $(SCRIPTS_DIR)/deploy_oci.sh

deploy-status:
	@echo "$(DIM_GREEN)Checking production health...$(RESET)"
	@ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $(OCI_SSH_KEY) $(OCI_USER)@$(OCI_HOST) \
	 'echo "=== Container ===" && docker ps --filter name=$(DEPLOY_CONTAINER) --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" && echo "" && echo "=== Health ===" && curl -s http://127.0.0.1:443/health?check_db=true && echo "" && echo "=== Resources ===" && docker stats $(DEPLOY_CONTAINER) --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"'

deploy-logs:
	@echo "$(DIM_GREEN)Tailing production logs...$(RESET)"
	@ssh -o StrictHostKeyChecking=no -i $(OCI_SSH_KEY) $(OCI_USER)@$(OCI_HOST) \
	 "docker logs -f --tail $${LINES:-200} $(DEPLOY_CONTAINER)"

deploy-ssh:
	@echo "$(DIM_GREEN)Connecting to OCI instance...$(RESET)"
	@ssh -o StrictHostKeyChecking=no -i $(OCI_SSH_KEY) $(OCI_USER)@$(OCI_HOST)

deploy-setup:
	@echo "$(DIM_GREEN)Setting up OCI instance for first deployment...$(RESET)"
	@ssh -o StrictHostKeyChecking=no -i $(OCI_SSH_KEY) $(OCI_USER)@$(OCI_HOST) bash -s <<'SETUP'
	set -euo pipefail
	echo "=== Installing Docker ==="
	if ! command -v docker &>/dev/null; then
	  sudo yum install -y docker || sudo apt-get install -y docker.io
	  sudo systemctl enable --now docker
	  sudo usermod -aG docker $$(whoami)
	  echo "Docker installed. Please log out and back in, then re-run deploy-setup."
	  exit 0
	fi
	echo "Docker: $$(docker --version)"
	echo "=== Creating directories ==="
	mkdir -p ~/matrix-hub
	if [ ! -f ~/matrix-hub/.env ]; then
	  echo "WARNING: ~/matrix-hub/.env not found. Create it before deploying."
	  echo "Copy .env.prod from the repo and adjust DATABASE_URL and other settings."
	fi
	echo "=== Opening firewall ports ==="
	sudo firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
	sudo firewall-cmd --permanent --add-port=4444/tcp 2>/dev/null || sudo iptables -A INPUT -p tcp --dport 4444 -j ACCEPT 2>/dev/null || true
	sudo firewall-cmd --reload 2>/dev/null || true
	echo "=== Setup complete ==="
	SETUP
