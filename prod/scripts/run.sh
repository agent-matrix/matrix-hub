#!/bin/bash
# Fetch and run the installer helper (00). It will pull 01/02 from the repo and guide you.
curl -O https://raw.githubusercontent.com/agent-matrix/matrix-hub/refs/heads/master/prod/scripts/00_install_prod.sh && chmod +x 00_install_prod.sh && ./00_install_prod.sh