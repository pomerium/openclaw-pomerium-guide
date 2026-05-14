#!/usr/bin/env bash
# install.sh — one-shot installer for OpenClaw + Pomerium.
#
# Intended invocation:
#   curl -fsSL https://raw.githubusercontent.com/pomerium/openclaw-pomerium-guide/openclaw-trusted-proxy-auth/install.sh | bash
#
# What it does:
#   1. Sanity-checks that git is installed (docker + ssh-keygen are
#      checked by bootstrap.sh once we hand off).
#   2. Clones the repo into ./pomclaw (the user's current working dir).
#   3. cd's in and hands off to bootstrap.sh, reattaching stdin to
#      /dev/tty so the four interactive prompts still work even when
#      the installer itself was piped from curl.
#
# Aborts (rather than pulling or overwriting) if ./pomclaw already
# exists -- bootstrap.sh is idempotent on re-run, so the right move
# is for the user to `cd pomclaw && ./bootstrap.sh`.

set -euo pipefail

# TODO: flip to `main` (or a release tag) before merging to main.
REPO_URL="https://github.com/pomerium/openclaw-pomerium-guide.git"
REPO_BRANCH="openclaw-trusted-proxy-auth"
TARGET_DIR="pomclaw"

log()     { printf '\033[36m[install]\033[0m %s\n' "$*" >&2; }
log_ok()  { printf '\033[32m[install]\033[0m %s\n' "$*" >&2; }
log_err() { printf '\033[31m[install]\033[0m %s\n' "$*" >&2; }

if ! command -v git >/dev/null 2>&1; then
  log_err "git is required but not found on PATH. Install git and re-run."
  exit 1
fi

if [[ -e "$TARGET_DIR" ]]; then
  log_err "./$TARGET_DIR already exists in $(pwd)."
  log_err "If you want to (re-)run the bootstrap, do:"
  log_err "  cd $TARGET_DIR && ./bootstrap.sh"
  log_err "If you want a clean install, remove or rename ./$TARGET_DIR first."
  exit 1
fi

log "Cloning $REPO_URL (branch: $REPO_BRANCH) into ./$TARGET_DIR"
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TARGET_DIR"
log_ok "clone complete"

cd "$TARGET_DIR"

# Reattach stdin to the controlling terminal. When this script is run as
# `curl ... | bash`, stdin is the curl pipe -- not a TTY -- so bootstrap.sh's
# `read` prompts would silently get EOF. Redirecting from /dev/tty restores
# interactivity for the handoff.
if [[ ! -r /dev/tty ]]; then
  log_err "No controlling TTY available; bootstrap.sh needs to prompt for"
  log_err "four values. Re-run from an interactive shell, or:"
  log_err "  cd $TARGET_DIR && ./bootstrap.sh"
  exit 1
fi

log "Handing off to ./bootstrap.sh"
exec ./bootstrap.sh </dev/tty
