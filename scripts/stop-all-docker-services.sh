#!/usr/bin/env bash
# stop-all-docker-services.sh: stops all running Docker containers

# Fetch all running container IDs
CONTAINERS=$(docker ps -q)

# If no containers are running, exit gracefully
if [ -z "$CONTAINERS" ]; then
  echo "No running Docker containers to stop."
  exit 0
fi

# Stop each running container
echo "Stopping Docker containers: $CONTAINERS"
for CONTAINER in $CONTAINERS; do
  if docker stop "$CONTAINER" >/dev/null 2>&1; then
    echo "Container $CONTAINER stopped successfully."
  else
    echo "Failed to stop container $CONTAINER."
  fi
done
