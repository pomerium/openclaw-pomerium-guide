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
curl -fsSL https://raw.githubusercontent.com/pomerium/openclaw-pomerium-guide/main/install.sh | bash
```

This clones the repo into `./pomclaw` and runs `bootstrap.sh`. To install somewhere else, pass a path:

```bash
curl -fsSL https://raw.githubusercontent.com/pomerium/openclaw-pomerium-guide/main/install.sh | bash -s -- ~/openclaw
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
- configures the gateway for trusted-proxy auth (`gateway.auth.trustedProxy`, `gateway.trustedProxies`, `auth.mode=trusted-proxy`)

It's idempotent. Re-running picks up from the current state.

When it finishes, the script prints the URL to open OpenClaw in your browser, and offers to open the Pomerium Zero API tokens page so you can revoke the API user token (recommended for least privilege; you can always generate a fresh one if you need to re-run bootstrap).

## Other commands

- `./bootstrap.sh status` — print current auth mode and whether `trustedProxy` config is set.
- `./bootstrap.sh reset` — destructive: clear any OpenClaw device records, flip the gateway back to token mode, unset trusted-proxy config, restart it. Pomerium Zero routes and policies are left in place. Use this when you need to re-bootstrap from a clean state.

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

## Gateway authentication model

The gateway runs in **trusted-proxy auth** end-to-end; `bootstrap.sh` writes the config directly via `openclaw config set` rather than going through a token-mode bootstrap first. Pomerium authenticates the user at the IdP, signs a JWT, and forwards both `X-Pomerium-Jwt-Assertion` and `x-pomerium-claim-email` on every request — the JWT because the route has `passIdentityHeaders: true`, and the claim header because the cluster has `jwtClaimsHeaders` mapping the `email` claim to `x-pomerium-claim-email`. The gateway reads the user identity from the claim header and refuses to honor it unless the JWT assertion is also present, so an attacker landing on the trusted-proxy IP would still need a credible Pomerium-signed JWT to spoof identity.

`gateway.trustedProxies` is set to the live IP of the `pomerium` container (resolved at bootstrap from `docker inspect`, so it reflects whatever Docker actually assigned rather than a hard-coded address). The route also injects `x-openclaw-scopes: operator.admin`, and Pomerium's route policy is the single source of truth for *who* can reach the gateway — `bootstrap.sh` creates an allow-by-email policy keyed on `OPERATOR_EMAIL`.

Earlier iterations of this guide did a token-mode device pairing first and flipped the gateway to trusted-proxy afterward, because trusted-proxy mode rejected loopback-source requests during a first device pairing. OpenClaw 2026.5.7+ changed the WebSocket pairing handshake that step depended on, so the bootstrap now skips device pairing entirely. See the [OpenClaw trusted-proxy docs](https://docs.openclaw.ai/gateway/trusted-proxy-auth) for the current runtime behavior model.

## What the script does for you in Pomerium Zero

The Pomerium Zero pieces `bootstrap.sh` configures via the API:

- **Cluster settings**: `sshAddress`, `sshHostKeys` (the three private host keys), `sshUserCaKey`, plus `jwtClaimsHeaders` mapping the `email` claim to the `x-pomerium-claim-email` header that trusted-proxy auth keys on. The SSH bits are what would otherwise be pasted into Pomerium Zero's "Global SSH Settings" page during the first Guided SSH Route flow.
- **A policy** named `openclaw users` that allows the configured `OPERATOR_EMAIL`.
- **The SSH route** `ssh://openclaw` → `ssh://openclaw-gateway:22` with that policy attached.
- **The web route** `https://openclaw.<cluster>.pomerium.app` → `http://openclaw-gateway:18789` with that policy attached, plus:
  - `passIdentityHeaders: true`
  - `setRequestHeaders: { "x-openclaw-scopes": "operator.admin" }`
  - `allowWebsockets: true`

If any of those resources already exist (matched by name for policies, by `from` URL for routes), the script skips creating them. Settings are PATCHed, so re-running with new keys just overwrites. `./bootstrap.sh reset` does **not** touch Pomerium Zero state — it only resets the gateway container's local auth state.

## API token least privilege

The `POMERIUM_ZERO_API_TOKEN` is only needed during bootstrap. Once setup is done, the script offers to open the Pomerium Zero API tokens page so you can revoke the token. The Pomerium Zero API doesn't expose a token-delete endpoint, so revocation is a UI click. If you ever need to re-run `bootstrap.sh` (to add a new email, regenerate keys, etc.), generate a fresh token at the same URL.

## References

- [OpenClaw Gateway Guide (Pomerium docs)](https://docs.pomerium.com/guides/openclaw-gateway)
- [OpenClaw Trusted Proxy Auth](https://docs.openclaw.ai/gateway/trusted-proxy-auth)
- [OpenClaw Operator Scopes](https://docs.openclaw.ai/gateway/operator-scopes)
- [Pomerium Zero API reference](https://www.pomerium.com/docs/internals/management-api-zero)
- [Pomerium Documentation](https://www.pomerium.com/docs)
- [OpenClaw](https://openclaw.ai)
