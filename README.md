# Securing Access to OpenClaw Gateway

> [!WARNING]
> **Security Scope:** OpenClaw (formerly Moltbot, Clawdbot) is not production-ready software and has known security limitations. This repo secures *access* to OpenClaw (SSH and gateway portal) using Pomerium's identity-aware proxy. It does not address OpenClaw's internal security model. See the [OpenClaw Gateway Security documentation](https://docs.openclaw.ai/gateway/security).
>
> What Pomerium secures: user authentication and identity verification, access control to SSH and gateway endpoints, network-level protection.
>
> What this does NOT secure: OpenClaw's internal operations and tool execution, code or commands run by authenticated users.

A containerized deployment of [OpenClaw](https://openclaw.ai/) behind Pomerium's zero-trust identity-aware proxy. The full narrative walkthrough is in the [deployment guide](https://docs.pomerium.com/guides/openclaw-gateway); this README is the operator runbook.

## Quick Setup

Host prereqs: `docker`, `docker compose`, `git`, `ssh-keygen` (universal on macOS/Linux/WSL). The script uses `curl` and `jq` inside the gateway container, so you don't need them on the host. WSL is fine on Windows.

```bash
curl -fsSL https://raw.githubusercontent.com/pomerium/openclaw-pomerium-guide/openclaw-trusted-proxy-auth/install.sh | bash
```

This clones the repo into `./pomclaw` and runs `bootstrap.sh`. To install somewhere else, pass a path:

```bash
curl -fsSL https://raw.githubusercontent.com/pomerium/openclaw-pomerium-guide/openclaw-trusted-proxy-auth/install.sh | bash -s -- ~/openclaw
```

`bootstrap.sh` then prompts for the four required values:

- `POMERIUM_ZERO_TOKEN` — cluster bootstrap token from Pomerium Zero
- `POMERIUM_ZERO_API_TOKEN` — generate at <https://console.pomerium.app/app/management/api-tokens>
- `POMERIUM_CLUSTER_DOMAIN` — e.g. `fantastic-fox-1234.pomerium.app` (auto-detected from your Pomerium Zero clusters when the API token is set)
- `OPERATOR_EMAIL` — your IdP email; used in the route policy

The values are written to `./pomclaw/.env` (mode 600). To inspect the repo before running, clone it manually and run `./bootstrap.sh` from inside — the prompts work the same way.

`./bootstrap.sh` does everything end-to-end:

- generates the SSH keys (User CA + three host keys)
- uploads the cluster's SSH config (host keys + User CA private key) to Pomerium Zero
- creates an allow-by-email policy for `OPERATOR_EMAIL`
- creates the SSH route (`ssh://openclaw` → `ssh://openclaw-gateway:22`)
- creates the web route (`https://openclaw.<cluster>` → `http://openclaw-gateway:18789`) with Pass Identity Headers, the `x-openclaw-scopes: operator.admin` request header, and WebSocket support
- brings up the docker compose stack
- pairs the primary operator device via a token-mode WebSocket handshake
- flips the gateway to trusted-proxy auth

It's idempotent. Re-running picks up from the current state.

When it finishes, the script prints the URL to open OpenClaw in your browser, and offers to open the Pomerium Zero API tokens page so you can revoke the API user token (recommended for least privilege; you can always generate a fresh one if you need to re-run bootstrap).

## Other commands

- `./bootstrap.sh status` — print current auth mode, paired-operator count, pending-pairing count.
- `./bootstrap.sh reset` — destructive: clear OpenClaw's paired devices, flip the gateway back to token mode, restart it. Pomerium Zero routes and policies are left in place. Use this if pairing went sideways and you need to start over.

## What's included

- **Pomerium**: zero-trust authentication proxy on port 443 (and 2200 for SSH)
- **OpenClaw Gateway**: AI assistant that takes action across your digital life, isolated to an internal Docker network
- **Verify**: Pomerium's identity verification service for testing auth

The gateway is not exposed to the internet. All access is proxied through Pomerium, which authenticates users at the IdP and applies the policy from `OPERATOR_EMAIL` before forwarding traffic.

## Architecture

OpenClaw is distributed as an npm package and doesn't ship a Docker image, so this repo includes a custom `openclaw/Dockerfile` that builds a gateway container with:

- the OpenClaw CLI installed from npm
- an SSH server that trusts the Pomerium User CA
- git for agent operations
- a persistent workspace mounted at `/claw/workspace`
- the `pomclaw.mjs` helper used by `bootstrap.sh` to drive the in-container WebSocket handshake

## Gateway authentication model

The gateway ships configured for **token auth** so the bootstrap can pair the primary operator device. Once paired, `bootstrap.sh` flips the gateway to **trusted-proxy auth**, where Pomerium-asserted identity (`X-Pomerium-Claim-Email`, `X-Pomerium-Jwt-Assertion`) replaces the shared token. The paired device record then provides operator scopes for the Control UI WebSocket.

This phased approach is necessary because OpenClaw's trusted-proxy mode is documented as an "identity-bearing HTTP mode" and rejects loopback-source requests, so the OpenClaw CLI inside the container cannot bootstrap a first device pairing while the gateway is in trusted-proxy mode (a known chicken-and-egg, see [openclaw issue #19352](https://github.com/openclaw/openclaw/issues/19352)). Token auth covers that gap; the script flips back automatically.

The Control UI WebSocket inherits scopes from the operator's paired device record, **not** from the `x-openclaw-scopes` header (see [openclaw issue #18560](https://github.com/openclaw/openclaw/issues/18560)). After Phase 2 of bootstrap, additional Control UI sessions from new browsers or devices that sign in as the same Pomerium-authenticated user typically just work without a separate pairing approval (see ["Control UI Pairing Behavior" in the OpenClaw trusted-proxy doc](https://docs.openclaw.ai/gateway/trusted-proxy-auth#control-ui-pairing-behavior)).

A note on auto-approved devices: when a *new* device pairing record is created in trusted-proxy mode (a different Pomerium identity, or a non-CUI client), the auto-approval grants only `operator.pairing`. The first time that device tries an operation requiring broader scope, OpenClaw queues a separate **scope-upgrade** pairing request; approving it with `openclaw devices approve <scope-upgrade-request-id>` widens the device record without a re-pair. See [OpenClaw operator scopes](https://docs.openclaw.ai/gateway/operator-scopes). For a single-operator deployment the bootstrap pairing already holds `operator.admin`, so this only matters when adding distinct device records for non-CUI clients or a second human operator.

> [!IMPORTANT]
> Don't `openclaw devices remove` the bootstrap pairing record. It's the durable source of operator scopes for every Control UI session in trusted-proxy mode. If you wipe `./openclaw-data/` or remove the pairing, the Control UI regresses to empty scopes and you'll need to re-bootstrap. Pair a second operator device first if you ever need to rotate.

## What the script does for you in Pomerium Zero

The Pomerium Zero pieces `bootstrap.sh` configures via the API:

- **Cluster SSH settings**: `sshAddress`, `sshHostKeys` (the three private host keys), `sshUserCaKey`. These are the values that would otherwise be pasted into Pomerium Zero's "Global SSH Settings" page during the first Guided SSH Route flow.
- **A policy** named `OpenClaw allow-list (<OPERATOR_EMAIL>)` that allows the configured email.
- **The SSH route** `ssh://openclaw` → `ssh://openclaw-gateway:22` with that policy attached.
- **The web route** `https://openclaw.<cluster>.pomerium.app` → `http://openclaw-gateway:18789` with that policy attached, plus:
  - `passIdentityHeaders: true`
  - `setRequestHeaders: { "x-openclaw-scopes": "operator.admin" }`
  - `allowWebsockets: true`

If any of those resources already exist (matched by name for policies, by `from` URL for routes), the script skips creating them. Settings are PATCHed, so re-running with new keys just overwrites. `./bootstrap.sh reset` does **not** touch Pomerium Zero state — it only resets OpenClaw's local pairing/auth-mode state.

## API token least privilege

The `POMERIUM_ZERO_API_TOKEN` is only needed during bootstrap. Once setup is done, the script offers to open the Pomerium Zero API tokens page so you can revoke the token. The Pomerium Zero API doesn't expose a token-delete endpoint, so revocation is a UI click. If you ever need to re-run `bootstrap.sh` (to add a new email, regenerate keys, etc.), generate a fresh token at the same URL.

## References

- [OpenClaw Gateway Guide (Pomerium docs)](https://docs.pomerium.com/guides/openclaw-gateway)
- [OpenClaw Trusted Proxy Auth](https://docs.openclaw.ai/gateway/trusted-proxy-auth)
- [OpenClaw Operator Scopes](https://docs.openclaw.ai/gateway/operator-scopes)
- [Pomerium Zero API reference](https://www.pomerium.com/docs/internals/management-api-zero)
- [Pomerium Documentation](https://www.pomerium.com/docs)
- [OpenClaw](https://openclaw.ai)
