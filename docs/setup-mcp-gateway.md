
# MCP Gateway Setup

This document describes how to install and prepare the MCP Gateway for local development.

## Prerequisites

- Ubuntu 22.04 (other Linux distros may work with small adjustments)
- Internet access to GitHub
- `sudo` privileges to install system packages

## Installation Steps

```bash
# 1. Clone & enter scripts
cd <your-workspace>
git clone https://github.com/IBM/mcp-context-forge.git mcpgateway
cd mcpgateway

# 2. Run the setup script
scripts/setup-mcp-gateway.sh
```

### What the setup script does

1. **OS check**
   Warns if not running Ubuntu 22.04.

2. **Python 3.11**

   * Checks `python3.11` on PATH
   * If missing, runs `scripts/install_python.sh` (must exist)

3. **System packages**

   ```bash
   sudo apt-get update -y
   sudo apt-get install -y git curl jq unzip iproute2 build-essential libffi-dev libssl-dev
   ```

4. **Clone or update repo**

   * On first run: clones at commit `1a37247c21cbeed212cbbd525376292de43a54bb`
   * On subsequent runs: `git fetch && git pull --ff-only` and optionally resets to that commit.

5. **Virtualenv**

   * Creates (or optionally recreates) `.venv` using `python3.11 -m venv`
   * Activates venv and upgrades `pip`, `setuptools`, `wheel`

6. **Python dependencies**

   * Installs editable dev extras: `pip install -e '.[dev]'` (or falls back to `-e .`)
   * If present, falls back to `requirements.txt`

7. **Environment file**

   * Copies `.env.example` → `.env` if no `.env` exists
   * You must review and edit `.env` for credentials, ports, etc.

