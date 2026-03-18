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
# Changed port to 8000 to avoid needing sudo for development
PORT              ?= 8000

RUFF              ?= ruff
PYTEST            ?= pytest
ALEMBIC           ?= alembic
ALEMBIC_INI       ?= alembic.ini
MKDOCS            ?= mkdocs
ENV_FILE          ?= .env

# Scripts & Operators
BASH              ?= bash
SCRIPTS_DIR       ?= scripts

# MCP Gateway
GATEWAY_PROJECT_DIR ?= mcpgateway
GATEWAY_HOST        ?= 0.0.0.0
GATEWAY_PORT        ?= 4444

# Load construct variables from .env
ENV := if [ -f "$(CURDIR)/$(ENV_FILE)" ]; then set -a; . "$(CURDIR)/$(ENV_FILE)"; set +a; fi;

# Alembic - use ini if present
ALEMBIC_CFG := $(if $(wildcard $(ALEMBIC_INI)),-c $(ALEMBIC_INI),)

# Activate virtual construct
activate = . $(VENV_DIR)/bin/activate

# Pre-flight Checks
.PHONY: ensure-env
ensure-env:
	@# Ensure construct reality file $(ENV_FILE) exists; if not, materialize from example.
	@if [ ! -f $(ENV_FILE) ]; then \
		if [ -f $(ENV_FILE).example ]; then \
			cp $(ENV_FILE).example $(ENV_FILE); \
			echo "$(DIM_GREEN)-> Materialized $(ENV_FILE) from template.$(RESET)"; \
		else \
			echo "$(BRIGHT_GREEN)Warning: No $(ENV_FILE) or $(ENV_FILE).example found. The construct may be unstable.$(RESET)"; \
		fi; \
	fi

# Main Directory
.PHONY: help
help:
	@echo
	@echo "$(BRIGHT_GREEN)M A T R I X - H U B ::: C O N T R O L   P R O G R A M$(RESET)"
	@echo
	@printf "$(BRIGHT_GREEN)  %-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "PROGRAM" "DESCRIPTION"
	@printf "$(BRIGHT_GREEN)  %-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "--------------------" "--------------------------------------------------------"
	@echo
	@echo "$(BRIGHT_GREEN)Core Operations$(RESET)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "install" "📦 Install dependencies (alias for setup)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "setup" "🔌 Jack in & load programs (create .venv, install deps)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "build" "🏗️  Build Docker container (alias for container-build)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "dev" "😎 Operator mode (run API with live reload)"
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "run" "▶️ Execute main program (run API in production mode)"
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
	@printf "  $(BRIGHT_GREEN)%-20s$(RESET) $(DIM_GREEN)%s$(RESET)\n" "gateway-setup" "🛠️  Construct the gateway from source"
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

# Environment Construction
$(VENV_DIR)/installed: pyproject.toml
	@echo "$(DIM_GREEN)-> Constructing reality... venv outdated or missing. Loading programs...$(RESET)"
	@test -d $(VENV_DIR) || $(PY) -m venv $(VENV_DIR)
	@. $(VENV_DIR)/bin/activate && pip install --upgrade pip setuptools wheel
	@. $(VENV_DIR)/bin/activate && pip install --upgrade ."[dev]"
	@echo "$(BRIGHT_GREEN)Setup complete. You are The One.$(RESET)"
	@touch $@

.PHONY: install setup
install: setup
setup: $(VENV_DIR)/installed

# Main Program Execution
.PHONY: dev
dev: $(VENV_DIR)/installed ensure-env
	@echo "$(DIM_GREEN)-> Entering Operator Mode... live reload enabled.$(RESET)"
	@$(BASH) $(SCRIPTS_DIR)/run_dev.sh

.PHONY: run
run: $(VENV_DIR)/installed ensure-env
	@echo "$(DIM_GREEN)-> Executing main program...$(RESET)"
	@$(BASH) $(SCRIPTS_DIR)/run_prod.sh

# Documentation Archives
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

# Quality Control Unit
.PHONY: lint fmt
lint:
	@echo "$(DIM_GREEN)-> Scanning for Agents...$(RESET)"
	@$(activate) && $(RUFF) check src tests
fmt:
	@echo "$(DIM_GREEN)-> Bending the code...$(RESET)"
	@$(activate) && $(RUFF) check --fix src tests

# Simulation & Training
.PHONY: test
test: $(VENV_DIR)/installed ensure-env
	@echo "$(DIM_GREEN)-> Entering the Dojo... initiating simulations...$(RESET)"
	@$(ENV) \
	$(activate) && $(PYTEST) -q

# Architect's Database (Alembic)
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

# Zion Gateway (MCP) Lifecycle
.PHONY: deps gateway-install gateway-setup gateway-start gateway-token gateway-verify gateway-stop
deps:
	@$(BASH) $(SCRIPTS_DIR)/install-dependencies.sh
gateway-install:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) HOST=$(GATEWAY_HOST) PORT=$(GATEWAY_PORT) \
	$(BASH) $(SCRIPTS_DIR)/install_mcp_gateway.sh
gateway-setup:
	@$(BASH) $(SCRIPTS_DIR)/setup-mcp-gateway.sh
gateway-start:
	@$(BASH) $(SCRIPTS_DIR)/start-mcp-gateway.sh
gateway-token:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) $(BASH) $(SCRIPTS_DIR)/get-token-mcp-gateway.sh
gateway-verify:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) $(BASH) $(SCRIPTS_DIR)/verify_servers.sh
gateway-stop:
	@PROJECT_DIR=$(GATEWAY_PROJECT_DIR) $(BASH) $(SCRIPTS_DIR)/stop-mcp-gateway.sh

# Index Construct Management
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

# Residual Self-Image (Container)
# Build-time variables
IMAGE_NAME            ?= matrix-hub
IMAGE_TAG             ?= latest
HUB_INSTALL_TARGET    ?= prod
SKIP_GATEWAY_SETUP    ?= 0
PLATFORM              ?=
NO_CACHE              ?= 0
PULL                  ?= 0
BUILDX                ?= 0
# Run-time variables
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
container-build:
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
container-run:
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

# Monitoring & Logs
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

# ===========================================
# Cloud Deployment (OCI)
# ===========================================
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