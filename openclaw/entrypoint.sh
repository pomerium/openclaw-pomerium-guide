#!/bin/sh
set -e

# Auto-detect Docker network subnets and configure trusted proxies
# Detects all non-loopback IPv4 interfaces
SUBNETS=$(ip -o -f inet addr show | grep -v "127.0.0.1" | awk '{print $4}' | tr '\n' '|')
if [ -n "$SUBNETS" ]; then
  echo "Detected Docker networks: $SUBNETS"
  # Convert to JSON array format
  JSON_ARRAY=$(echo "$SUBNETS" | sed 's/|/","/g' | sed 's/^/["/' | sed 's/$/"]/')
  su - claw -c "openclaw config set gateway.trustedProxies \"$JSON_ARRAY\" --json" 2>/dev/null || {
    echo "Warning: Could not set trustedProxies (config may not exist yet)"
  }
else
  echo "Warning: Could not detect any Docker networks"
fi

# Configure allowed origins (requires POMERIUM_CLUSTER_DOMAIN)
if [ -z "$POMERIUM_CLUSTER_DOMAIN" ]; then
  echo "Error: POMERIUM_CLUSTER_DOMAIN environment variable is required"
  exit 1
fi

NEW_ORIGIN="https://openclaw.$POMERIUM_CLUSTER_DOMAIN"
echo "Configuring allowed origins for $NEW_ORIGIN"

# Get current allowedOrigins, append if not already present
CURRENT=$(su - claw -c "openclaw config get gateway.controlUi.allowedOrigins" 2>/dev/null || echo "[]")
UPDATED=$(echo "$CURRENT" | jq -c --arg origin "$NEW_ORIGIN" 'if index($origin) then . else . + [$origin] end')

su - claw -c "openclaw config set gateway.controlUi.allowedOrigins '$UPDATED'" 2>/dev/null || {
  echo "Warning: Could not set allowedOrigins (config may not exist yet)"
}

# Ensure claw user owns its home directory contents
chown -R claw:claw /claw

# Start SSH daemon (must run as root)
/usr/sbin/sshd

# Run openclaw as claw user
exec su - claw -c "openclaw gateway --bind lan --allow-unconfigured"
