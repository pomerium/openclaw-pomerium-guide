#!/usr/bin/env bash
set -euo pipefail

# One-time helper: switch OpenClaw gateway to trusted-proxy mode
# Run this AFTER initial pairing/bootstrap is complete.

SERVICE_NAME="openclaw-gateway"
USER_HEADER="X-Pomerium-Claim-Email"

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is required"
  exit 1
fi

if ! docker compose ps "$SERVICE_NAME" >/dev/null 2>&1; then
  echo "Error: docker compose service '$SERVICE_NAME' not found"
  echo "Run this from the repository root after 'docker compose up -d'."
  exit 1
fi

CONTAINER_ID="$(docker compose ps -q "$SERVICE_NAME")"
if [ -z "$CONTAINER_ID" ]; then
  echo "Error: '$SERVICE_NAME' container is not running"
  exit 1
fi

if [ ! -f .env ]; then
  echo "Error: .env file not found in repository root"
  exit 1
fi

# shellcheck disable=SC1091
source .env

if [ -z "${POMERIUM_CLUSTER_DOMAIN:-}" ]; then
  echo "Error: POMERIUM_CLUSTER_DOMAIN is required in .env"
  exit 1
fi

echo "Applying one-time trusted-proxy gateway config..."

run_in_gateway() {
  docker exec "$CONTAINER_ID" su - claw -c "$1"
}

# Require that OpenClaw config exists first (usually after initial pairing/onboarding)
if ! run_in_gateway "openclaw config get gateway.mode" >/dev/null 2>&1; then
  echo "OpenClaw config isn't ready yet."
  echo "Finish initial pairing/onboarding first, then re-run this script."
  exit 1
fi

# Configure required trusted-proxy auth settings
run_in_gateway "openclaw config set gateway.bind lan"
run_in_gateway "openclaw config set gateway.auth.mode trusted-proxy"
run_in_gateway "openclaw config set gateway.auth.trustedProxy.userHeader '$USER_HEADER'"
run_in_gateway "openclaw config set gateway.tailscale.mode off"

# Add OpenClaw origin for Control UI
NEW_ORIGIN="https://openclaw.${POMERIUM_CLUSTER_DOMAIN}"
CURRENT="$(run_in_gateway "openclaw config get gateway.controlUi.allowedOrigins" 2>/dev/null || echo "[]")"
UPDATED="$(printf '%s' "$CURRENT" | jq -c --arg origin "$NEW_ORIGIN" 'if index($origin) then . else . + [$origin] end')"
run_in_gateway "openclaw config set gateway.controlUi.allowedOrigins '$UPDATED'"

# Configure trusted proxies from container network interfaces
SUBNETS="$(docker exec "$CONTAINER_ID" sh -lc "ip -o -f inet addr show | grep -v '127.0.0.1' | awk '{print \$4}' | tr '\n' '|'" | sed 's/|$//')"
if [ -n "$SUBNETS" ]; then
  JSON_ARRAY="[\"$(printf '%s' "$SUBNETS" | sed 's/|/\",\"/g')\"]"
  run_in_gateway "openclaw config set gateway.trustedProxies '$JSON_ARRAY' --json"
fi

echo "Done. Gateway is now configured for trusted-proxy mode."
echo "Restart recommended: docker compose restart ${SERVICE_NAME}"
