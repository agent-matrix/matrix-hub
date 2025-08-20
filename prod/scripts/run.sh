# Fetch and run the installer helper (00). It will pull 01/02 from the repo and guide you.
curl -fsSLo 00_install_prod.sh \
  https://raw.githubusercontent.com/agent-matrix/matrix-hub/main/prod/scripts/00_install_prod.sh
chmod +x 00_install_prod.sh
./00_install_prod.sh