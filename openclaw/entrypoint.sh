#!/bin/sh
set -e

# Ensure claw user owns its home directory contents
chown -R claw:claw /claw

# Configure allowed origins
if [ -z "$POMERIUM_CLUSTER_DOMAIN" ]; then
  echo "Error: POMERIUM_CLUSTER_DOMAIN environment variable is required"
  exit 1
fi

# Change the sub domain if you don't name your from route in Pomerium "openclaw.$POMERIUM_CLUSTER_DOMAIN"
NEW_ORIGIN="https://openclaw.$POMERIUM_CLUSTER_DOMAIN"
echo "Configuring allowed origins for $NEW_ORIGIN"

CURRENT=$(su - claw -c "openclaw config get gateway.controlUi.allowedOrigins" 2>/dev/null || echo "[]")
UPDATED=$(echo "$CURRENT" | jq -c --arg origin "$NEW_ORIGIN" 'if index($origin) then . else . + [$origin] end')

su - claw -c "openclaw config set gateway.controlUi.allowedOrigins '$UPDATED'" 2>/dev/null || {
  echo "Warning: Could not set allowedOrigins (config may not exist yet)"
}

# Start SSH daemon (must run as root)
/usr/sbin/sshd

# Run openclaw as claw user
exec su - claw -c "openclaw gateway"
