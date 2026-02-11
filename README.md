# Securing Access to OpenClaw Gateway

> [!WARNING]
> **Security Scope:** OpenClaw (formerly known as Moltbot and Clawdbot) is not production-ready software and has known security limitations. **This guide secures access to OpenClaw** (SSH and gateway portal) using Pomerium's identity-aware proxy, but **does not address OpenClaw's internal security model**. For details on OpenClaw's security considerations, see the [OpenClaw Gateway Security documentation](https://docs.openclaw.ai/gateway/security).
>
> **What Pomerium Secures:**
>
> - User authentication and identity verification
> - Access control to SSH and gateway endpoints
> - Network-level protection
>
> **What This Guide Does NOT Secure:**
>
> - OpenClaw's internal operations and tool execution
> - Code or commands run by authenticated users


A containerized deployment of [OpenClaw](https://openclaw.ai/) deployment secured by Pomerium's zero-trust identity-aware proxy.

## Getting Started

For complete setup instructions, configuration options, and troubleshooting, please refer to the [comprehensive guide](https://docs.pomerium.com/guides/openclaw-gateway).

## Quick Setup

### New to Pomerium SSH? (Recommended Path)

```bash
# 1. Clone this repository

# git clone
git clone https://github.com/pomerium/openclaw-pomerium-guide

# via GitHub CLI
gh repo clone pomerium/openclaw-pomerium-guide

cd openclaw-pomerium-guide

# 2. Configure environment
cp .env.example .env
# Edit .env with your Pomerium Zero token and cluster domain

# 3. Generate SSH keys
./setup-ssh.sh

# 4. Start services
docker-compose up -d
```

### Already Have Pomerium SSH Configured?

If you already have SSH routes configured in Pomerium Zero with a User CA key:

```bash
# 1. Clone this repository (same as above)

# 2. Configure environment (same as above)

# 3. Copy your existing User CA public key
# Instead of running setup-ssh.sh, manually copy your existing public key:
cp /path/to/your/existing/pomerium_user_ca_key.pub ./openclaw-data/pomerium-ssh/

# 4. Start services
docker-compose up -d
```

**Note:** Generating new SSH keys will invalidate your existing Pomerium SSH configuration. Only run `./setup-ssh.sh` if you're setting up Pomerium SSH for the first time or intentionally rotating your keys.

For detailed prerequisites, network requirements, and step-by-step instructions, see the [full guide](https://deploy-preview-2084--pomerium-docs.netlify.app/docs/guides/openclaw-gateway).

## What's Included

- **Pomerium**: Zero-trust authentication proxy on port 443
- **OpenClaw Gateway**: AI assistant that takes action across your digital life
- **Verify**: Pomerium's verification service for testing authentication

## Architecture

OpenClaw is distributed as an npm package and doesn't provide an official Docker image. This repository includes a custom Dockerfile (`openclaw/Dockerfile`) that builds a gateway container with:

- OpenClaw CLI installed from npm
- SSH server with Pomerium User CA integration
- Git for agent operations
- Persistent workspace mounted at `/claw/workspace`

The gateway runs on an internal Docker network with none of those ports exposed to the internet. All access is proxied through Pomerium, which provides identity-aware, zero-trust access control. SSH traffic via port 2200 and HTTPS traffic via port 443 are secured with context-based authorization policies that verify user identity and device posture before granting access. See the [deployment guide](https://docs.pomerium.com/guides/openclaw-gateway) for detailed architecture and security considerations. Where you deploy, port 22 will typically be open by default. Once Pomerium is configured, you can disable direct port 22 access (recommended), ensuring all SSH connections are authenticated and authorized through Pomerium's policy engine.

## References

For issues or questions, please refer to:
- [OpenClaw Gateway Guide](https://docs.pomerium.com/guides/openclaw-gateway)
- [Pomerium Documentation](https://www.pomerium.com/docs)
- [OpenClaw](https://openclaw.ai)
