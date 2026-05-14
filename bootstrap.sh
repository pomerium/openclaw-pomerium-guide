#!/usr/bin/env bash
# bootstrap.sh — Pomerium + OpenClaw deployment bootstrap.
#
# What this does:
#   Pre-bootstrap: Interactively prompts for the four required values when
#                  .env is missing or incomplete (no-op on full .env).
#   Phase 0:       Generates SSH keys, patches the cluster's SSH config +
#                  jwtClaimsHeaders in Pomerium Zero, creates the policy +
#                  SSH route + web route via the Pomerium Zero API.
#   Phase 1:       Brings up the rest of the docker compose stack
#                  (pomerium, verify).
#   Phase 2:       Configures the gateway for trusted-proxy auth directly
#                  (gateway.auth.trustedProxy + gateway.trustedProxies +
#                  auth.mode=trusted-proxy). Replaces the older token-mode
#                  -> WebSocket-pairing -> switch dance that broke in
#                  OpenClaw 2026.5.7.
#   Phase 2.5:     Prompts to pair the operator's browser device.
#
# Idempotent and resumable. Re-running picks up from the current state.
#
# Required env vars (collected interactively if missing, or set manually
# in .env):
#   POMERIUM_ZERO_TOKEN       Cluster bootstrap token
#   POMERIUM_CLUSTER_DOMAIN   e.g. fantastic-fox-1234.pomerium.app
#   POMERIUM_ZERO_API_TOKEN   API user token; generate at:
#                             https://console.pomerium.app/app/management/api-tokens
#   OPERATOR_EMAIL            Sign-in email allowed by the route policy
#
# Host prereqs: docker, docker compose, ssh-keygen. (curl + jq run inside the
# openclaw-gateway container, so the host doesn't need them.)
#
# Usage:
#   ./bootstrap.sh                       # bootstrap (default; interactive if .env missing)
#   ./bootstrap.sh status                # print current state, no changes
#   ./bootstrap.sh reset                 # destructive: clear devices + flip back to token mode
#   ./bootstrap.sh pair-browser <id> <pk>  # pair a Control UI browser device

set -euo pipefail

POMCLAW_HELPER=/opt/pomclaw/pomclaw.mjs
ZERO_API="https://console.pomerium.app/api/v0"
API_TOKENS_URL="https://console.pomerium.app/app/management/api-tokens"

banner() {
  cat <<'EOF'

   ____             ____ _
  |  _ \ ___  _ __ / ___| | __ ___      __
  | |_) / _ \| '_ \ |   | |/ _` \ \ /\ / /
  |  __/ (_) | | | | |__ | | (_| |\ V  V /
  |_|   \___/|_| |_|\____|_|\__,_| \_/\_/

  Pomerium + OpenClaw deployment bootstrap

EOF
}

# ---- pretty logs ----
log()      { printf '\033[36m[pomclaw]\033[0m %s\n' "$*" >&2; }
log_ok()   { printf '\033[32m[pomclaw]\033[0m %s\n' "$*" >&2; }
log_warn() { printf '\033[33m[pomclaw]\033[0m %s\n' "$*" >&2; }
log_err()  { printf '\033[31m[pomclaw]\033[0m %s\n' "$*" >&2; }

# ---- env loading + validation ----
load_env() {
  if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi
}

require_env() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log_err "Missing required env vars in .env: ${missing[*]}"
    log_err ""
    log_err "POMERIUM_ZERO_API_TOKEN is the API user token. Generate one at:"
    log_err "  $API_TOKENS_URL"
    log_err ""
    log_err "OPERATOR_EMAIL is the email your IdP returns for your account; it"
    log_err "is used in the route policy that controls who can reach OpenClaw."
    exit 1
  fi
}

require_tools() {
  local missing=()
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log_err "Missing required tools on the host: ${missing[*]}"
    log_err "On macOS these come with the OS or with Docker Desktop. On Linux"
    log_err "install them via your package manager."
    exit 1
  fi
}

phase_env_setup() {
  # Interactively populate .env if missing or incomplete. No-op when all four
  # required vars are already set. Non-TTY runs fall through to require_env
  # which produces the canonical "missing vars in .env" error, so CI
  # behavior is unchanged.
  #
  # Collect ALL values first, then write `.env` once. No API calls during
  # prompting: the cluster bootstrap token implies the user already created
  # the cluster, so we just ask for the four pieces in order:
  #   1. POMERIUM_ZERO_TOKEN       -- cluster bootstrap token (proves cluster exists)
  #   2. POMERIUM_ZERO_API_TOKEN   -- separate, org-scoped API user token
  #   3. POMERIUM_CLUSTER_DOMAIN   -- the cluster's *.pomerium.app FQDN
  #   4. OPERATOR_EMAIL            -- email allowed by the route policy
  if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env 2>/dev/null || true
    set +a
  fi
  local need_zero=0 need_api=0 need_domain=0 need_email=0
  [[ -z "${POMERIUM_ZERO_TOKEN:-}"     ]] && need_zero=1
  [[ -z "${POMERIUM_ZERO_API_TOKEN:-}" ]] && need_api=1
  [[ -z "${POMERIUM_CLUSTER_DOMAIN:-}" ]] && need_domain=1
  [[ -z "${OPERATOR_EMAIL:-}"          ]] && need_email=1
  if (( need_zero == 0 && need_api == 0 && need_domain == 0 && need_email == 0 )); then
    return
  fi
  if [[ ! -t 0 ]]; then
    # Let require_env produce the canonical missing-vars error.
    return
  fi

  log "==> Pre-bootstrap: collecting Pomerium Zero configuration"
  log ""
  log "You'll be asked for 4 values. Have these ready (or look them up):"
  log ""
  log "  1. Cluster bootstrap token  -- shown once during cluster onboarding."
  log "                                If lost, rotate at:"
  log "                                https://console.pomerium.app/app/clusters"
  log "                                -> three-dot menu -> Rotate Token"
  log "  2. API user token           -- DIFFERENT token; generate at:"
  log "                                $API_TOKENS_URL"
  log "                                -> Add API User"
  log "  3. Cluster domain           -- your *.pomerium.app FQDN, visible in"
  log "                                https://console.pomerium.app/app/clusters"
  log "  4. Your sign-in email       -- the email allowed to reach OpenClaw."
  log ""
  log "Press Ctrl-C any time to abort."
  echo >&2

  if (( need_zero )); then
    printf "[pomclaw] POMERIUM_ZERO_TOKEN: "
    read -r POMERIUM_ZERO_TOKEN || POMERIUM_ZERO_TOKEN=""
    if [[ -z "$POMERIUM_ZERO_TOKEN" ]]; then
      log_err "POMERIUM_ZERO_TOKEN is required."
      exit 1
    fi
  fi

  if (( need_api )); then
    printf "[pomclaw] POMERIUM_ZERO_API_TOKEN: "
    read -r POMERIUM_ZERO_API_TOKEN || POMERIUM_ZERO_API_TOKEN=""
    if [[ -z "$POMERIUM_ZERO_API_TOKEN" ]]; then
      log_err "POMERIUM_ZERO_API_TOKEN is required."
      exit 1
    fi
  fi

  if (( need_domain )); then
    printf "[pomclaw] POMERIUM_CLUSTER_DOMAIN (e.g. fantastic-fox-1234.pomerium.app): "
    read -r POMERIUM_CLUSTER_DOMAIN || POMERIUM_CLUSTER_DOMAIN=""
    if [[ -z "$POMERIUM_CLUSTER_DOMAIN" ]]; then
      log_err "POMERIUM_CLUSTER_DOMAIN is required."
      exit 1
    fi
  fi

  if (( need_email )); then
    printf "[pomclaw] OPERATOR_EMAIL (your sign-in email): "
    read -r OPERATOR_EMAIL || OPERATOR_EMAIL=""
    if [[ -z "$OPERATOR_EMAIL" ]]; then
      log_err "OPERATOR_EMAIL is required."
      exit 1
    fi
  fi
  echo >&2

  local openclaw_version="${OPENCLAW_VERSION:-2026.5.7}"
  cat > .env.new <<EOF
# Pomerium Zero Configuration
# Get this token from https://console.pomerium.com/ when creating your cluster
POMERIUM_ZERO_TOKEN=$POMERIUM_ZERO_TOKEN

# Your Pomerium Zero cluster domain (e.g., fantastic-fox-1234.pomerium.app)
# Found in your Pomerium Zero console after cluster creation
POMERIUM_CLUSTER_DOMAIN=$POMERIUM_CLUSTER_DOMAIN

# API user token from console.pomerium.app/app/management/api-tokens
POMERIUM_ZERO_API_TOKEN=$POMERIUM_ZERO_API_TOKEN

# The IdP email allowed by the route policy
OPERATOR_EMAIL=$OPERATOR_EMAIL

# OpenClaw version to install in OpenClaw container
OPENCLAW_VERSION=$openclaw_version # defaults to latest stable release if not set
EOF
  mv .env.new .env
  chmod 600 .env
  log_ok ".env written with all four required values."
  echo >&2
  # Re-source so subsequent phases see the new values in this shell.
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
}

# ---- docker compose wrappers ----
DC()     { docker compose "$@"; }
INSIDE() {
  # Run a command as the claw user inside the gateway container.
  # Optional env overrides are passed via --env=KEY=VALUE flags before the command.
  # We prepend the env assignments to the shell command itself because
  # `su - claw` starts a login shell that wipes the environment, so
  # `docker exec -e` alone won't propagate them to the inner process.
  local env_prefix=""
  while [[ $# -gt 0 && "$1" == --env=* ]]; do
    env_prefix+="${1#--env=} "
    shift
  done
  DC exec -T openclaw-gateway su - claw -c "${env_prefix}$*"
}
INSIDE_ROOT() {
  # Run as root inside the gateway container (used for jq/curl invocations
  # that don't need /claw home, just the container's installed tools).
  local env_args=()
  while [[ $# -gt 0 && "$1" == --env=* ]]; do
    env_args+=(-e "${1#--env=}")
    shift
  done
  DC exec -T "${env_args[@]}" openclaw-gateway "$@"
}

resolve_pomerium_replica_ip() {
  # Resolve the live IP of the pomerium container. We read Docker's runtime
  # state (not docker-compose.yml), so this works whether the compose file
  # pins `ipv4_address` or leaves Docker to auto-assign. Users hitting a
  # subnet collision (VPN, other stacks) can change `networks.main` in
  # docker-compose.yml without touching the script.
  #
  # Assumes:
  #   - The stack is up (run after `phase_stack_up`).
  #   - Pomerium is attached to exactly one Docker network -- the `main`
  #     network this compose stack defines. If you attach it to additional
  #     networks, this returns whichever IP Docker iterates first, which is
  #     not stable; query by network name in that case.
  local container ip
  container=$(DC ps -q pomerium 2>/dev/null | head -n1)
  if [[ -z "$container" ]]; then
    log_err "pomerium container not running (\`docker compose ps pomerium\`)"
    exit 1
  fi
  ip=$(docker inspect "$container" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' 2>/dev/null \
    | grep -v '^$' | head -n1 | tr -d '\r ')
  if [[ -z "$ip" ]]; then
    log_err "could not resolve pomerium IP from docker inspect (container fully up?)"
    exit 1
  fi
  printf '%s' "$ip"
}

# ---- generic helpers ----
retry() {
  local attempts="$1" sleep_s="$2" max_s="$3"
  shift 3
  local i=0
  while (( i < attempts )); do
    if "$@"; then return 0; fi
    i=$((i + 1))
    if (( i >= attempts )); then break; fi
    log_warn "attempt $i/$attempts failed; sleeping ${sleep_s}s"
    sleep "$sleep_s"
    sleep_s=$((sleep_s * 2))
    (( sleep_s > max_s )) && sleep_s="$max_s"
  done
  return 1
}

wait_for() {
  local label="$1" total="$2" interval="$3"
  shift 3
  local elapsed=0
  while (( elapsed < total )); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    if (( elapsed % 10 == 0 )); then
      log "still waiting for $label... (${elapsed}/${total}s)"
    fi
  done
  log_err "timeout waiting for $label after ${total}s"
  return 1
}

gateway_listening() { INSIDE "node $POMCLAW_HELPER auth-mode" >/dev/null 2>&1; }
helper()            { INSIDE "node $POMCLAW_HELPER $1"; }

# ---- Pomerium Zero API helpers (run inside the openclaw-gateway container) ----
#
# We use the gateway container's installed curl + jq so the host doesn't need
# either tool. The container needs to be up before we call these; phase_zero_api
# brings it up first and uses it as a "JSON utility container" for the API
# bootstrap, then phase_stack_up brings up the rest.

zero_curl() {
  # zero_curl <METHOD> <PATH-OR-URL> [<JSON-BODY>]
  # If ID_TOKEN is set on the host, it's passed in via --env so curl inside
  # the container can use it for the Authorization header.
  local method="$1" path="$2" body="${3:-}"
  local url
  if [[ "$path" == http* ]]; then url="$path"; else url="$ZERO_API$path"; fi

  local args=(-s -X "$method" "$url" -H "Content-Type: application/json")
  [[ -n "${ID_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer $ID_TOKEN")
  [[ -n "$body" ]] && args+=(-d "$body")

  # -w '\n%{http_code}' appends the HTTP status as the last line; we split it
  # off and surface a non-zero exit + log on >=400.
  local response status out
  response=$(INSIDE_ROOT curl "${args[@]}" -w $'\n%{http_code}')
  status=${response##*$'\n'}
  out=${response%$'\n'*}

  if [[ "$status" -ge 400 ]]; then
    log_err "Pomerium Zero API $method $path returned HTTP $status"
    log_err "Response: $out"
    return 1
  fi
  printf '%s' "$out"
}

zero_jq() {
  # Run jq inside the gateway container. Args: jq filter (and any flags).
  # Stdin is forwarded.
  INSIDE_ROOT jq "$@"
}

zero_login() {
  log "Authenticating to Pomerium Zero API"
  local body
  body=$(printf '%s' "$POMERIUM_ZERO_API_TOKEN" \
    | zero_jq -Rs '{refreshToken: .}')
  local response
  response=$(zero_curl POST "/token" "$body") || exit 1
  ID_TOKEN=$(printf '%s' "$response" | zero_jq -r '.idToken // empty')
  if [[ -z "$ID_TOKEN" ]]; then
    log_err "did not receive an idToken from Pomerium Zero"
    exit 1
  fi
  export ID_TOKEN
  log_ok "authenticated"
}

zero_resolve_ids() {
  log "Resolving organization + cluster IDs (looking up $POMERIUM_CLUSTER_DOMAIN)"
  local orgs
  orgs=$(zero_curl GET "/organizations") || exit 1
  ORG_ID=$(printf '%s' "$orgs" | zero_jq -r '.[0].id // empty')
  if [[ -z "$ORG_ID" ]]; then
    log_err "no organizations available on this API token"
    exit 1
  fi

  local clusters
  clusters=$(zero_curl GET "/organizations/$ORG_ID/clusters") || exit 1
  local match
  match=$(printf '%s' "$clusters" \
    | zero_jq -r --arg fqdn "$POMERIUM_CLUSTER_DOMAIN" \
        '.[] | select(.fqdn == $fqdn) | "\(.id) \(.namespaceId)"' \
    | head -n1)

  if [[ -z "$match" ]]; then
    log_err "cluster '$POMERIUM_CLUSTER_DOMAIN' not found in this organization"
    log_err "available clusters:"
    printf '%s' "$clusters" | zero_jq -r '.[] | "  - \(.fqdn)"' >&2
    exit 1
  fi

  CLUSTER_ID=${match% *}
  NAMESPACE_ID=${match#* }
  export ORG_ID CLUSTER_ID NAMESPACE_ID
  log_ok "  organization: $ORG_ID"
  log_ok "  cluster:      $CLUSTER_ID"
  log_ok "  namespace:    $NAMESPACE_ID"
}

zero_set_cluster_settings() {
  log "Setting cluster SSH config + JWT claim header mapping"
  # Read the key files from the host and pass them as raw stdin to jq inside
  # the container, which builds the JSON Patch payload.
  local h_ed h_rsa h_ecdsa user_ca
  h_ed=$(<ssh_host_ed25519_key)
  h_rsa=$(<ssh_host_rsa_key)
  h_ecdsa=$(<ssh_host_ecdsa_key)
  user_ca=$(<pomerium_user_ca_key)

  # `jwtClaimsHeaders` tells Pomerium to extract the named claim from the
  # JWT it issues (hosted authenticate) and forward it as the named HTTP
  # header on requests to upstreams. OpenClaw's trusted-proxy auth keys on
  # `x-pomerium-claim-email` (see `phase_configure_trusted_proxy`), but
  # individual claim headers are *not* emitted by default on hosted
  # authenticate clusters -- you have to opt in here. Without this mapping
  # the upstream sees only `X-Pomerium-Jwt-Assertion` and the gateway
  # rejects every request with `reason=trusted_proxy_user_missing`.
  local patch
  patch=$(zero_jq -n \
    --arg ed "$h_ed" \
    --arg rsa "$h_rsa" \
    --arg ecdsa "$h_ecdsa" \
    --arg ca "$user_ca" \
    '[
      {op: "add", path: "/sshAddress",       value: "0.0.0.0:22"},
      {op: "add", path: "/sshHostKeys",      value: [$ed, $rsa, $ecdsa]},
      {op: "add", path: "/sshUserCaKey",     value: $ca},
      {op: "add", path: "/jwtClaimsHeaders", value: {"x-pomerium-claim-email": "email"}}
    ]')

  zero_curl PATCH "/organizations/$ORG_ID/clusters/$CLUSTER_ID/settings" "$patch" >/dev/null
  log_ok "cluster settings applied (SSH config + jwtClaimsHeaders)"
}

zero_get_or_create_policy() {
  local name="OpenClaw allow-list ($OPERATOR_EMAIL)"
  local existing
  existing=$(zero_curl GET "/organizations/$ORG_ID/policies?namespaceId=$NAMESPACE_ID" \
    | zero_jq -r --arg n "$name" '.[]? | select(.name == $n) | .id' \
    | head -n1)
  if [[ -n "$existing" ]]; then
    POLICY_ID="$existing"
    export POLICY_ID
    log_ok "policy already exists: $POLICY_ID"
    return 0
  fi

  log "Creating allow-by-email policy ($OPERATOR_EMAIL)"
  local body
  body=$(zero_jq -n \
    --arg ns "$NAMESPACE_ID" \
    --arg name "$name" \
    --arg email "$OPERATOR_EMAIL" \
    '{
      namespaceId: $ns,
      name: $name,
      description: ("Allow " + $email + " to access OpenClaw"),
      explanation: "Access denied. Only the configured operator email is permitted.",
      remediation: "Contact the OpenClaw operator to request access.",
      enforced: false,
      ppl: { allow: { or: [{ email: { is: $email } }] } }
    }')
  POLICY_ID=$(zero_curl POST "/organizations/$ORG_ID/policies" "$body" \
    | zero_jq -r '.id')
  export POLICY_ID
  log_ok "policy created: $POLICY_ID"
}

zero_get_or_create_route() {
  # Args: <name> <from> <to> <kind: "web"|"ssh">
  local name="$1" from="$2" to="$3" kind="$4"
  local existing
  existing=$(zero_curl GET "/organizations/$ORG_ID/routes?namespaceId=$NAMESPACE_ID" \
    | zero_jq -r --arg from "$from" '.[]? | select(.from == $from) | .id' \
    | head -n1)
  if [[ -n "$existing" ]]; then
    log_ok "$kind route already exists: $existing"
    return 0
  fi

  log "Creating $kind route ($from -> $to)"
  local body
  # Common fields required by the Pomerium Zero API. `allowWebsockets` is
  # intentionally NOT in this block -- each route kind sets it explicitly
  # (web=true, ssh=false). It used to live here, but jq object construction
  # is last-write-wins, so an earlier `allowWebsockets: true` in the route
  # body was being silently clobbered by this block when it expanded after.
  # See hiccups #5 (Zero API required-fields list) and the websocket entry
  # for the regression that resurfaced this.
  local common_fields='
    allowSpdy: false,
    enableGoogleCloudServerlessAuthentication: false,
    preserveHostHeader: false,
    showErrorDetails: false,
    tlsSkipVerify: false,
    tlsUpstreamAllowRenegotiation: false
  '
  if [[ "$kind" == "web" ]]; then
    body=$(zero_jq -n \
      --arg ns "$NAMESPACE_ID" --arg name "$name" \
      --arg from "$from" --arg to "$to" --arg pid "$POLICY_ID" \
      "{
        namespaceId: \$ns, name: \$name, from: \$from, to: [\$to],
        policyIds: [\$pid],
        passIdentityHeaders: true,
        setRequestHeaders: { \"x-openclaw-scopes\": \"operator.admin\" },
        $common_fields,
        allowWebsockets: true
      }")
  else
    body=$(zero_jq -n \
      --arg ns "$NAMESPACE_ID" --arg name "$name" \
      --arg from "$from" --arg to "$to" --arg pid "$POLICY_ID" \
      "{
        namespaceId: \$ns, name: \$name, from: \$from, to: [\$to],
        policyIds: [\$pid],
        $common_fields,
        allowWebsockets: false
      }")
  fi
  local rid
  rid=$(zero_curl POST "/organizations/$ORG_ID/routes" "$body" \
    | zero_jq -r '.id')
  log_ok "$kind route created: $rid"
}

# ---- phases ----

phase_generate_ssh_keys() {
  log "Generating SSH keys (if missing) + installing User CA pub for the gateway container"
  if [[ ! -f pomerium_user_ca_key ]]; then
    ssh-keygen -N "" -f pomerium_user_ca_key -C "Pomerium User CA" >/dev/null
  fi
  [[ -f ssh_host_ed25519_key ]] || ssh-keygen -t ed25519 -f ssh_host_ed25519_key -N "" >/dev/null
  [[ -f ssh_host_rsa_key     ]] || ssh-keygen -t rsa -b 3072 -f ssh_host_rsa_key -N "" >/dev/null
  [[ -f ssh_host_ecdsa_key   ]] || ssh-keygen -t ecdsa -b 256 -f ssh_host_ecdsa_key -N "" >/dev/null

  mkdir -p ./openclaw-data/pomerium-ssh
  cp pomerium_user_ca_key.pub ./openclaw-data/pomerium-ssh/
  log_ok "User CA pub installed at openclaw-data/pomerium-ssh/"
}

phase_zero_api() {
  log "==> Phase 0: Pomerium Zero (SSH cluster config + policy + routes)"
  phase_generate_ssh_keys

  # Bring up just the openclaw-gateway service so we can use its installed
  # curl + jq for the API calls. The rest of the stack (pomerium, verify)
  # comes up in Phase 1, after the routes are configured.
  #
  # `DC build` first: `docker-compose.yml` tags the service `image: openclaw:VERSION`
  # which doesn't exist on any public registry; without an explicit build the
  # `docker compose up` step prints a noisy "pull access denied for openclaw"
  # warning before falling back to the build context. Building explicitly
  # skips the pull attempt. Cached on re-runs.
  log "Building openclaw-gateway image (cached on re-runs)"
  DC build openclaw-gateway >/dev/null
  log "Starting openclaw-gateway (used as a JSON utility container for API setup)"
  DC up -d openclaw-gateway
  if ! wait_for "openclaw-gateway exec ready" 60 2 \
       sh -c 'docker compose exec -T openclaw-gateway sh -c "command -v curl && command -v jq" >/dev/null 2>&1'; then
    log_err "openclaw-gateway did not become exec-ready"
    exit 1
  fi

  zero_login
  zero_resolve_ids
  zero_set_cluster_settings
  zero_get_or_create_policy
  zero_get_or_create_route "openclaw-ssh" "ssh://openclaw" "ssh://openclaw-gateway:22" "ssh"
  zero_get_or_create_route "openclaw-web" "https://openclaw.$POMERIUM_CLUSTER_DOMAIN" "http://openclaw-gateway:18789" "web"
}

phase_stack_up() {
  log "==> Phase 1: bringing up the rest of the docker compose stack"
  DC up -d
  if ! wait_for "gateway responding" 60 2 gateway_listening; then
    log_err "gateway did not come up. Run: docker compose logs openclaw-gateway"
    exit 1
  fi
  log_ok "stack is up"
}

phase_configure_trusted_proxy() {
  # Configure trusted-proxy auth directly. This replaces the older token-mode
  # WebSocket pairing dance (`phase_ensure_token` -> `trigger-pairing` ->
  # `devices approve` -> `switch-to-trusted-proxy`), which broke against
  # OpenClaw 2026.5.7: the gateway now answers the WebSocket `connect`
  # request with a `connect.challenge` (a nonce that the client must sign
  # with a device key) before any pending pairing is created, and the
  # pomclaw.mjs helper doesn't implement the challenge response. Since
  # trusted-proxy mode only needs three pieces of static config, we set them
  # directly instead. See hiccups.md for the codepath that broke.
  #
  # The pieces written:
  #   - gateway.auth.trustedProxy.userHeader      : header carrying the user
  #     id. Pomerium emits "x-pomerium-claim-email" once the cluster's
  #     jwtClaimsHeaders maps email -> that header name (set in
  #     zero_set_cluster_settings) AND the route has passIdentityHeaders=true.
  #   - gateway.auth.trustedProxy.requiredHeaders : the gateway requires this
  #     header set on every request before honoring userHeader. Pomerium emits
  #     X-Pomerium-Jwt-Assertion when passIdentityHeaders=true; requiring it
  #     means an attacker who can sit on the trusted-proxy IP (e.g. a rogue
  #     container on the docker network) would *also* need to mint a credible
  #     Pomerium-signed JWT to spoof identity.
  #   - `allowUsers` is intentionally NOT set: Pomerium's route policy is the
  #     single source of truth for who can reach this gateway. Duplicating
  #     the allowlist here drifts.
  #   - gateway.trustedProxies                    : list of exact upstream IPs
  #     allowed to inject those headers. OpenClaw doesn't support CIDR here,
  #     so we list one IP. We resolve it from `docker inspect` (see
  #     resolve_pomerium_replica_ip) so the value reflects whatever Docker
  #     actually assigned -- works whether the compose pins
  #     ipv4_address: 172.30.0.10 or a user picked a different subnet to avoid
  #     a collision.
  log "==> Phase 2: configuring trusted-proxy auth"
  local pomerium_ip
  pomerium_ip=$(resolve_pomerium_replica_ip)
  log "  pomerium replica IP: $pomerium_ip"
  local tp_block
  tp_block=$(zero_jq -n \
    --arg uh "x-pomerium-claim-email" \
    --arg jwt "X-Pomerium-Jwt-Assertion" \
    '{userHeader: $uh, requiredHeaders: [$jwt]}')
  local proxies
  proxies=$(zero_jq -n --arg ip "$pomerium_ip" '[$ip]')
  INSIDE "openclaw config set gateway.auth.trustedProxy --strict-json '$tp_block'" >/dev/null
  INSIDE "openclaw config set gateway.trustedProxies --strict-json '$proxies'" >/dev/null
  INSIDE "openclaw config set gateway.auth.mode trusted-proxy" >/dev/null
  INSIDE "openclaw config unset gateway.auth.token" >/dev/null 2>&1 || true
  # Note: trusted-proxy auth passes the WS handshake, but the gateway then
  # clears the browser's connect-frame scopes if its ed25519 device identity
  # is not in paired.json (see openclaw
  # `src/gateway/server/ws-connection/connect-policy.ts:88-106` and
  # `message-handler.ts:1131-1147`). The result is "missing scope:
  # operator.read" on Control UI RPCs. We deliberately do NOT set
  # `gateway.controlUi.dangerouslyDisableDeviceAuth: true` to silence that --
  # without it, a stolen Pomerium session cookie cannot escalate to admin.
  # Instead, run `./bootstrap.sh pair-browser <deviceId> <publicKey>` once
  # per browser, using the identity from its localStorage. See that
  # command's docs for the procedure.

  DC restart openclaw-gateway
  if ! wait_for "gateway responding after trusted-proxy switch" 60 2 gateway_listening; then
    log_err "gateway did not come back up. Run: docker compose logs openclaw-gateway"
    exit 1
  fi
  log_ok "gateway in trusted-proxy mode (userHeader=x-pomerium-claim-email, trustedProxies=[$pomerium_ip])"
  log_warn "Per-browser pairing required next: visit the Control UI once, copy the device identity from localStorage, then run \`./bootstrap.sh pair-browser <deviceId> <publicKey>\`."
}

phase_offer_token_revocation() {
  echo >&2
  log_warn "Least-privilege reminder"
  log_warn "  The Pomerium Zero API token in your .env was only used to set"
  log_warn "  up routes and SSH config. Bootstrap doesn't need it again, and"
  log_warn "  routine operations don't either. Consider revoking it now;"
  log_warn "  generate a fresh one if you ever need to re-run bootstrap."
  log_warn ""
  log_warn "  Manage tokens at: $API_TOKENS_URL"
  log_warn ""
  printf "Open the API tokens page in your browser now? [y/N]: "
  local answer
  read -r answer || answer=""
  if [[ "$answer" =~ ^[Yy] ]]; then
    if command -v open >/dev/null 2>&1; then
      open "$API_TOKENS_URL"
    elif command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$API_TOKENS_URL" >/dev/null 2>&1 || true
    else
      log "open the URL manually: $API_TOKENS_URL"
    fi
    log_warn "After revoking, remove POMERIUM_ZERO_API_TOKEN from .env."
  else
    log "skipping; the token stays active until you revoke it manually."
  fi
}

# ---- top-level commands ----

cmd_status() {
  banner
  load_env
  if ! gateway_listening; then
    log_warn "gateway is not responding (is the stack up? \`docker compose up -d\`)"
    return 1
  fi
  local mode ops pending
  mode="$(helper auth-mode | tr -d '\r\n ')"
  ops="$(helper operators-count | tr -d '\r\n ')"
  pending="$(helper pending-count | tr -d '\r\n ')"
  log "auth.mode:        ${mode:-unknown}"
  log "operator devices: $ops"
  log "pending pairings: $pending"
}

pair_browser_apply() {
  # Pure pairing logic: validate deviceId/publicKey, stop gateway, write the
  # paired.json record, restart, wait healthy. No banner / no env load --
  # callers (cmd_pair_browser, phase_prompt_pair_browser) handle that.
  local device_id="$1"
  local public_key="$2"
  # Ensure the gateway is running so the INSIDE_ROOT sha256 derivation below
  # can exec into the container. A prior failed pair-browser run can leave
  # the gateway stopped; `DC start` is a no-op when it's already up.
  DC start openclaw-gateway >/dev/null 2>&1 || true
  if ! wait_for "gateway responding" 30 2 gateway_listening; then
    log_err "gateway is not responding; cannot pair. Run \`docker compose up -d\` first."
    exit 1
  fi
  # Sanity-check the deviceId derivation matches the publicKey (gateway uses
  # sha256(base64url-decoded(publicKey)) hex). Mismatch would silently produce
  # a paired record the gateway rejects.
  local derived
  derived=$(printf '%s' "$public_key" \
    | INSIDE_ROOT sh -c '
        tr -- -_ +/ |
        base64 -d 2>/dev/null |
        sha256sum |
        awk "{print \$1}"
      ' | tr -d '\r\n ')
  if [[ -n "$derived" && "$derived" != "$device_id" ]]; then
    log_err "deviceId mismatch: expected sha256(pubkey)=$derived but got $device_id"
    log_err "Re-copy the deviceId from the browser's localStorage."
    exit 1
  fi
  log "Pairing browser device $device_id with operator.admin/read/write/approvals/pairing"
  DC stop openclaw-gateway >/dev/null
  DC run --rm --no-deps --entrypoint sh openclaw-gateway -c "
    set -e
    # Ensure the devices/ dir exists. On a totally fresh openclaw-data
    # (or one wiped between bootstrap and pair-browser) the gateway may
    # not yet have created its devices/ subdir, so mkdir -p as a no-op
    # for the steady-state case.
    mkdir -p /claw/.openclaw/devices && chown claw:claw /claw/.openclaw/devices
    f=/claw/.openclaw/devices/paired.json
    [ -s \"\$f\" ] || echo '{}' > \"\$f\"
    now=\$(date +%s%3N)
    # Generate an opaque operator token. The Control UI authenticates with
    # its ed25519 device key, not this token, but openclaw's
    # listEffectivePairedDeviceRoles (infra/device-pairing.ts:246-259) only
    # honors paired-device roles when the device has at least one
    # non-revoked tokens.<role> entry. Tokenless records fail closed.
    op_token=\$(head -c 32 /dev/urandom | base64 | tr -d '+/=' | head -c 43)
    jq --arg id '$device_id' --arg pk '$public_key' --arg tok \"\$op_token\" --argjson now \"\$now\" \
       '.[\$id] = {
          deviceId: \$id,
          publicKey: \$pk,
          clientId: \"openclaw-control-ui\",
          clientMode: \"webchat\",
          role: \"operator\",
          roles: [\"operator\"],
          scopes: [\"operator.admin\",\"operator.read\",\"operator.write\",\"operator.approvals\",\"operator.pairing\"],
          approvedScopes: [\"operator.admin\",\"operator.read\",\"operator.write\",\"operator.approvals\",\"operator.pairing\"],
          tokens: {
            operator: {
              token: \$tok,
              role: \"operator\",
              scopes: [\"operator.admin\",\"operator.read\",\"operator.write\",\"operator.approvals\",\"operator.pairing\"],
              createdAtMs: \$now
            }
          },
          createdAtMs: \$now,
          approvedAtMs: \$now
        }' \"\$f\" > \"\$f.new\" && mv \"\$f.new\" \"\$f\" && chown claw:claw \"\$f\"
  " >/dev/null
  DC start openclaw-gateway >/dev/null
  if ! wait_for "gateway responding after pairing" 60 2 gateway_listening; then
    log_err "gateway did not come back up. Run: docker compose logs openclaw-gateway"
    exit 1
  fi
  log_ok "browser device paired; reload the Control UI"
}

cmd_pair_browser() {
  # Pair a Control UI browser device with operator.admin scopes (full thinking
  # is in pair_browser_apply / hiccup #24). In trusted-proxy mode openclaw's
  # WS handshake (`src/gateway/server/ws-connection/connect-policy.ts:88-106`,
  # `message-handler.ts:1131-1147`) zeroes a Control UI session's
  # connect-frame scopes unless its ed25519 device key is already in
  # paired.json. This subcommand drops in such a record so the next handshake
  # binds the requested scopes properly, without resorting to
  # `gateway.controlUi.dangerouslyDisableDeviceAuth: true` (which lets a
  # stolen Pomerium session cookie escalate to admin).
  #
  # Usage:
  #   1. Visit the Control UI once in the target browser; it auto-generates
  #      its ed25519 device identity and stores it in localStorage under
  #      `openclaw-device-identity-v1`.
  #   2. In DevTools console:
  #        JSON.parse(localStorage.getItem("openclaw-device-identity-v1"))
  #      Copy `deviceId` (sha256 hex of pubkey) and `publicKey` (base64url
  #      ed25519 pubkey).
  #   3. ./bootstrap.sh pair-browser <deviceId> <publicKey>
  #   4. Reload the Control UI. Scopes bind, chat history loads.
  banner
  load_env
  local device_id="${1:-}"
  local public_key="${2:-}"
  if [[ -z "$device_id" || -z "$public_key" ]]; then
    log_err "usage: ./bootstrap.sh pair-browser <deviceId> <publicKey>"
    log_err ""
    log_err "Get these from the Control UI's localStorage. In a browser that"
    log_err "has visited https://openclaw.\$POMERIUM_CLUSTER_DOMAIN at least once,"
    log_err "open DevTools console and run:"
    log_err "  JSON.parse(localStorage.getItem(\"openclaw-device-identity-v1\"))"
    exit 2
  fi
  pair_browser_apply "$device_id" "$public_key"
}

phase_prompt_pair_browser() {
  # Optional interactive step at end of `bootstrap`. Asks the user to paste
  # their browser's device identity JSON from localStorage and pairs it.
  # Idempotent: if a webchat operator device already exists, skip.
  # Non-TTY: skip (print instructions only).
  local existing
  existing=$(INSIDE_ROOT sh -c 'cat /claw/.openclaw/devices/paired.json 2>/dev/null || echo "{}"' \
    | INSIDE_ROOT jq -r '[.[]? | select((.clientMode // "") == "webchat" and (.role // "") == "operator")] | length' \
    | tr -d '\r\n ')
  if [[ "${existing:-0}" -gt 0 ]]; then
    log_ok "browser device already paired ($existing); skipping pairing prompt"
    return
  fi
  echo >&2
  log "Last step: pair this browser so the Control UI gets full operator scopes."
  log "  1. Open  https://openclaw.$POMERIUM_CLUSTER_DOMAIN  in your browser and sign in via Pomerium."
  log "  2. Open DevTools console (Cmd+Opt+I on Mac, F12 on Win/Linux)."
  log "  3. Run this and copy the JSON output:"
  log "       JSON.parse(localStorage.getItem(\"openclaw-device-identity-v1\"))"
  log "  4. Paste the JSON below (or press Enter to skip and pair later with"
  log "     \`./bootstrap.sh pair-browser <deviceId> <publicKey>\`)."
  echo >&2
  if [[ ! -t 0 ]]; then
    log_warn "stdin is not a TTY; skipping interactive prompt."
    log_warn "Pair later with: ./bootstrap.sh pair-browser <deviceId> <publicKey>"
    return
  fi
  printf "[pomclaw] device identity JSON: "
  local input
  read -r input || input=""
  if [[ -z "${input// }" ]]; then
    log "Skipped. Pair later with: ./bootstrap.sh pair-browser <deviceId> <publicKey>"
    return
  fi
  local device_id public_key
  device_id=$(printf '%s' "$input" | INSIDE_ROOT jq -r '.deviceId // empty' 2>/dev/null | tr -d '\r\n ')
  public_key=$(printf '%s' "$input" | INSIDE_ROOT jq -r '.publicKey // empty' 2>/dev/null | tr -d '\r\n ')
  if [[ -z "$device_id" || -z "$public_key" ]]; then
    log_err "Couldn't read .deviceId/.publicKey from the pasted value."
    log_err "Pair later with: ./bootstrap.sh pair-browser <deviceId> <publicKey>"
    return
  fi
  pair_browser_apply "$device_id" "$public_key"
}

cmd_reset() {
  banner
  load_env
  log_warn "RESET will: clear all paired devices, flip auth.mode back to token,"
  log_warn "set a placeholder token, and restart the gateway."
  log_warn "(Pomerium Zero routes and policies are NOT touched.)"
  printf "Type 'reset' to confirm: "
  read -r confirm
  if [[ "$confirm" != "reset" ]]; then
    log "aborted"
    exit 0
  fi
  INSIDE "openclaw devices clear --yes --pending" || true
  INSIDE "openclaw config set gateway.auth.mode token" >/dev/null
  INSIDE "openclaw config set gateway.auth.token 'configure-gateway-token'" >/dev/null
  INSIDE "openclaw config unset gateway.auth.trustedProxy" >/dev/null 2>&1 || true
  INSIDE "openclaw config unset gateway.trustedProxies"   >/dev/null 2>&1 || true
  INSIDE "openclaw config unset gateway.controlUi.dangerouslyDisableDeviceAuth" >/dev/null 2>&1 || true
  DC restart openclaw-gateway
  log_ok "reset complete; run ./bootstrap.sh to bootstrap again"
}

cmd_bootstrap() {
  banner
  phase_env_setup
  load_env
  require_env POMERIUM_ZERO_TOKEN POMERIUM_CLUSTER_DOMAIN POMERIUM_ZERO_API_TOKEN OPERATOR_EMAIL
  require_tools docker ssh-keygen

  phase_zero_api
  phase_stack_up

  local mode tp_set
  mode="$(helper auth-mode | tr -d '\r\n ')"
  # `gateway.auth.trustedProxy` populated is the durable signal that Phase 2
  # has run. We don't use `operators-count` for this: the gateway
  # self-registers a CLI operator device on startup (role=operator,
  # scope=operator.pairing), so that count is always >=1 even on a fresh
  # state.
  tp_set="$(INSIDE "openclaw config get gateway.auth.trustedProxy" 2>/dev/null | tr -d '\r\n ' || true)"
  if [[ -n "$tp_set" && "$tp_set" != "null" && "$tp_set" != "{}" ]]; then
    tp_set=yes
  else
    tp_set=no
  fi
  log "current state: auth.mode=$mode, trustedProxy=$tp_set"

  if [[ "$mode" == "trusted-proxy" && "$tp_set" == "yes" ]]; then
    log_ok "already bootstrapped"
  elif [[ "$mode" == "trusted-proxy" && "$tp_set" == "no" ]]; then
    log_err "inconsistent state (trusted-proxy mode without trustedProxy config)."
    log_err "Run: ./bootstrap.sh reset"
    exit 1
  else
    phase_configure_trusted_proxy
  fi

  echo >&2
  log_ok "================================================================"
  log_ok "  Setup complete"
  log_ok ""
  log_ok "  Open OpenClaw at:"
  log_ok "    https://openclaw.$POMERIUM_CLUSTER_DOMAIN"
  log_ok ""
  log_ok "  SSH into the gateway container with:"
  log_ok "    ssh claw@openclaw@$POMERIUM_CLUSTER_DOMAIN -p 2200"
  log_ok "================================================================"

  phase_prompt_pair_browser
  phase_offer_token_revocation
}

case "${1:-bootstrap}" in
  bootstrap)     cmd_bootstrap ;;
  status)        cmd_status ;;
  reset)         cmd_reset ;;
  pair-browser)  shift; cmd_pair_browser "$@" ;;
  -h|--help|help)
    cat <<EOF
Usage: $(basename "$0") [bootstrap|status|reset|pair-browser <deviceId> <publicKey>]

Commands:
  bootstrap (default)  End-to-end setup: configure Pomerium Zero (SSH cluster
                       config, policy, SSH route, web route), bring up the
                       Docker stack, switch the gateway to trusted-proxy auth.
  status               Print current auth mode and device counts.
  reset                Destructive: clear OpenClaw devices, flip back to
                       token mode. Does not touch Pomerium Zero routes.
  pair-browser         Pair a Control UI browser's ed25519 device key with
                       operator.admin scopes. Required once per browser in
                       trusted-proxy auth mode (see command help below).
                       Get <deviceId> + <publicKey> from the browser by running:
                         JSON.parse(localStorage.getItem(
                           "openclaw-device-identity-v1"))

Required env vars in .env:
  POMERIUM_ZERO_TOKEN, POMERIUM_CLUSTER_DOMAIN,
  POMERIUM_ZERO_API_TOKEN ($API_TOKENS_URL),
  OPERATOR_EMAIL (your IdP email; used in the route policy).

Host prereqs: docker, docker compose, ssh-keygen.
(curl + jq run inside the openclaw-gateway container; not required on host.)
EOF
    ;;
  *)
    echo "Unknown command: $1" >&2
    echo "Run: $0 --help" >&2
    exit 2
    ;;
esac
