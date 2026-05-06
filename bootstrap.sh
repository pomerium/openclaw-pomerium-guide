#!/usr/bin/env bash
# bootstrap.sh — Pomerium + OpenClaw deployment bootstrap.
#
# What this does:
#   Phase 0: Generates SSH keys, sets the cluster's SSH config (host keys
#            + User CA) in Pomerium Zero, creates the policy + SSH route +
#            web route via the Pomerium Zero API.
#   Phase 1: Pairs the primary operator device using token auth.
#   Phase 2: Switches the gateway from token auth to trusted-proxy auth.
#
# Idempotent and resumable. Re-running picks up from the current state.
#
# Required env vars (in .env):
#   POMERIUM_ZERO_TOKEN       Cluster bootstrap token
#   POMERIUM_CLUSTER_DOMAIN   e.g. fantastic-fox-1234.pomerium.app
#   POMERIUM_ZERO_API_TOKEN   API user token; generate at:
#                             https://console.pomerium.app/app/management/api-tokens
#   OPERATOR_EMAIL            Email allowed by the route policy (your IdP email)
#
# Host prereqs: docker, docker compose, ssh-keygen. (curl + jq run inside the
# openclaw-gateway container, so the host doesn't need them.)
#
# Usage:
#   ./bootstrap.sh           # bootstrap (default)
#   ./bootstrap.sh status    # print current state, no changes
#   ./bootstrap.sh reset     # destructive: clear devices + flip back to token mode

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

# ---- docker compose wrappers ----
DC()     { docker compose "$@"; }
INSIDE() {
  # Run a command as the claw user inside the gateway container.
  # Optional env overrides are passed via --env=KEY=VALUE flags before the command.
  local env_args=()
  while [[ $# -gt 0 && "$1" == --env=* ]]; do
    env_args+=(-e "${1#--env=}")
    shift
  done
  DC exec -T "${env_args[@]}" openclaw-gateway su - claw -c "$*"
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

zero_set_ssh_config() {
  log "Uploading SSH host keys + User CA private key to the cluster's SSH settings"
  # Read the key files from the host and pass them as raw stdin to jq inside
  # the container, which builds the JSON Patch payload.
  local h_ed h_rsa h_ecdsa user_ca
  h_ed=$(<ssh_host_ed25519_key)
  h_rsa=$(<ssh_host_rsa_key)
  h_ecdsa=$(<ssh_host_ecdsa_key)
  user_ca=$(<pomerium_user_ca_key)

  local patch
  patch=$(zero_jq -n \
    --arg ed "$h_ed" \
    --arg rsa "$h_rsa" \
    --arg ecdsa "$h_ecdsa" \
    --arg ca "$user_ca" \
    '[
      {op: "replace", path: "/sshAddress", value: "0.0.0.0:22"},
      {op: "replace", path: "/sshHostKeys", value: [$ed, $rsa, $ecdsa]},
      {op: "replace", path: "/sshUserCaKey", value: $ca}
    ]')

  zero_curl PATCH "/organizations/$ORG_ID/clusters/$CLUSTER_ID/settings" "$patch" >/dev/null
  log_ok "SSH cluster config set"
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
  if [[ "$kind" == "web" ]]; then
    body=$(zero_jq -n \
      --arg ns "$NAMESPACE_ID" --arg name "$name" \
      --arg from "$from" --arg to "$to" --arg pid "$POLICY_ID" \
      '{
        namespaceId: $ns, name: $name, from: $from, to: [$to],
        policyIds: [$pid],
        passIdentityHeaders: true,
        setRequestHeaders: { "x-openclaw-scopes": "operator.admin" },
        allowWebsockets: true
      }')
  else
    body=$(zero_jq -n \
      --arg ns "$NAMESPACE_ID" --arg name "$name" \
      --arg from "$from" --arg to "$to" --arg pid "$POLICY_ID" \
      '{
        namespaceId: $ns, name: $name, from: $from, to: [$to],
        policyIds: [$pid]
      }')
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
  log "Starting openclaw-gateway (used as a JSON utility container for API setup)"
  DC up -d openclaw-gateway
  if ! wait_for "openclaw-gateway exec ready" 60 2 \
       sh -c 'docker compose exec -T openclaw-gateway sh -c "command -v curl && command -v jq" >/dev/null 2>&1'; then
    log_err "openclaw-gateway did not become exec-ready"
    exit 1
  fi

  zero_login
  zero_resolve_ids
  zero_set_ssh_config
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

phase_ensure_token() {
  local current
  current="$(helper token)"
  if [[ -z "$current" || "$current" == "configure-gateway-token" ]]; then
    log "Rotating placeholder gateway token"
    local fresh
    fresh="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
    INSIDE "openclaw config set gateway.auth.token '$fresh'" >/dev/null
    DC restart openclaw-gateway
    wait_for "gateway responding after restart" 60 2 gateway_listening
    printf '%s' "$fresh"
  else
    printf '%s' "$current"
  fi
}

phase_trigger_pairing() {
  local token="$1"
  log "Triggering pending pairing via token-mode WebSocket"
  if ! retry 5 1 16 \
       INSIDE "--env=OPENCLAW_GATEWAY_TOKEN=$token" \
       "node $POMCLAW_HELPER trigger-pairing"; then
    log_err "could not trigger pairing"
    exit 1
  fi
  if ! wait_for "pending pairing to register" 30 2 \
       sh -c '[ "$(docker compose exec -T openclaw-gateway su - claw -c "node /opt/pomclaw/pomclaw.mjs pending-count" | tr -d "\r\n ")" -gt 0 ]'; then
    log_err "no pending pairing showed up"
    exit 1
  fi
  log_ok "pending pairing request registered"
}

phase_approve() {
  local req_id
  req_id="$(helper latest-pending | tr -d '\r\n ')"
  if [[ -z "$req_id" ]]; then
    log_err "no pending pairing to approve"
    exit 1
  fi
  log "Approving pairing request $req_id"
  if ! retry 3 2 8 INSIDE "openclaw devices approve $req_id"; then
    log_err "could not approve pairing"
    exit 1
  fi
  if ! wait_for "operator pairing to materialize" 30 2 \
       sh -c '[ "$(docker compose exec -T openclaw-gateway su - claw -c "node /opt/pomclaw/pomclaw.mjs operators-count" | tr -d "\r\n ")" -gt 0 ]'; then
    log_err "approval did not produce a paired operator device"
    exit 1
  fi
  log_ok "operator device paired"
}

phase_switch_to_trusted_proxy() {
  log "==> Phase 2: switching gateway to trusted-proxy auth"
  INSIDE "openclaw config unset gateway.auth.token" >/dev/null
  INSIDE "openclaw config set gateway.auth.mode trusted-proxy" >/dev/null
  DC restart openclaw-gateway
  log_ok "gateway restarted in trusted-proxy mode"
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
  DC restart openclaw-gateway
  log_ok "reset complete; run ./bootstrap.sh to bootstrap again"
}

cmd_bootstrap() {
  banner
  load_env
  require_env POMERIUM_ZERO_TOKEN POMERIUM_CLUSTER_DOMAIN POMERIUM_ZERO_API_TOKEN OPERATOR_EMAIL
  require_tools docker ssh-keygen

  phase_zero_api
  phase_stack_up

  local mode ops
  mode="$(helper auth-mode | tr -d '\r\n ')"
  ops="$(helper operators-count | tr -d '\r\n ')"
  log "current state: auth.mode=$mode, operator devices=$ops"

  if [[ "$mode" == "trusted-proxy" && "$ops" -gt 0 ]]; then
    log_ok "already bootstrapped"
  else
    if [[ "$mode" == "trusted-proxy" && "$ops" -eq 0 ]]; then
      log_err "inconsistent state (trusted-proxy mode, no paired operator)."
      log_err "Run: ./bootstrap.sh reset"
      exit 1
    fi
    if [[ "$ops" -eq 0 ]]; then
      local token
      token="$(phase_ensure_token)"
      phase_trigger_pairing "$token"
      phase_approve
    else
      log_ok "operator already paired; skipping pairing step"
    fi
    if [[ "$mode" != "trusted-proxy" ]]; then
      phase_switch_to_trusted_proxy
    fi
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

  phase_offer_token_revocation
}

case "${1:-bootstrap}" in
  bootstrap) cmd_bootstrap ;;
  status)    cmd_status ;;
  reset)     cmd_reset ;;
  -h|--help|help)
    cat <<EOF
Usage: $(basename "$0") [bootstrap|status|reset]

Commands:
  bootstrap (default)  End-to-end setup: configure Pomerium Zero (SSH cluster
                       config, policy, SSH route, web route), bring up the
                       Docker stack, pair the operator device, switch the
                       gateway to trusted-proxy auth.
  status               Print current auth mode and device counts.
  reset                Destructive: clear OpenClaw devices, flip back to
                       token mode. Does not touch Pomerium Zero routes.

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
