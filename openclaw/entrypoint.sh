#!/bin/sh
set -eu

export HOME=/claw
export OPENCLAW_STATE_DIR=/claw/.openclaw
export OPENCLAW_CONFIG_PATH=/claw/.openclaw/openclaw.json

mkdir -p /claw/.openclaw /claw/workspace
chown -R claw:claw /claw

if [ -z "${POMERIUM_CLUSTER_DOMAIN:-}" ]; then
  echo "Error: POMERIUM_CLUSTER_DOMAIN environment variable is required"
  exit 1
fi

NEW_ORIGIN="https://openclaw.$POMERIUM_CLUSTER_DOMAIN"
echo "Configuring allowed origins for $NEW_ORIGIN"

# run all openclaw commands as claw, preserving env
run_as_claw() {
  sudo -u claw -E sh -lc "$*"
}

CURRENT="$(run_as_claw "openclaw config get gateway.controlUi.allowedOrigins" 2>/dev/null || echo '[]')"
UPDATED="$(echo "$CURRENT" | jq -c --arg origin "$NEW_ORIGIN" 'if index($origin) then . else . + [$origin] end')"

run_as_claw "openclaw config set gateway.controlUi.allowedOrigins '$UPDATED'" || true
run_as_claw "openclaw config set gateway.mode local" || true
run_as_claw "openclaw config set gateway.bind loopback" || true

/usr/sbin/sshd

exec sudo -u claw -E sh -lc 'exec openclaw gateway --bind loopback --port 18789 --allow-unconfigured'
