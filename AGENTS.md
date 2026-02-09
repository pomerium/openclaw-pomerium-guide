# Repository Guidelines

## Project Structure & Module Organization
- Root `docker-compose.yml` orchestrates Pomerium, Verify, and the `openclaw-gateway` service.
- `openclaw/` contains the container build context (`Dockerfile`, `entrypoint.sh`); update this when changing the gateway image.
- Persistent state lives under `openclaw-data/`: `config/` for OpenClaw settings, `workspace/` for agent projects, and `pomerium-ssh/` for the Pomerium User CA (mounted read-only).
- `setup-ssh.sh` bootstraps SSH keys; reference `README.md` and `SSH_TROUBLESHOOTING.md` for deployment workflows.

## Build, Test, and Development Commands
- `docker-compose up -d` — build (if needed) and start the full stack.
- `docker-compose build openclaw-gateway` — rebuild the gateway image after Dockerfile or entrypoint tweaks.
- `docker-compose logs -f openclaw-gateway` — follow runtime logs; verify the gateway is accepting connections.
- `./setup-ssh.sh` — generate or rotate Pomerium SSH keys before first boot or contributor handoff.

## Coding Style & Naming Conventions
- Dockerfiles: lowercase instructions, chain compatible `RUN` steps, avoid unnecessary layers.
- Shell scripts (`entrypoint.sh`, helpers): `#!/bin/sh`, `set -e`, two-space indentation, no bash-only syntax.
- YAML (`docker-compose.yml`): two-space indent, lowercase keys, env vars uppercase with underscores.
- Markdown docs: title-case headings, short paragraphs, fenced code blocks for commands.

## Testing Guidelines
- No automated test suite; rely on operational validation.
- After changes run `docker-compose up --build` then `docker-compose ps` to confirm healthy services.
- Use `docker-compose exec openclaw-gateway openclaw --version` to verify the expected release is installed.
- For SSH updates, confirm access through `ssh root@openclaw@<cluster>.pomerium.app` via your configured Pomerium route.

## Commit & Pull Request Guidelines
- Follow Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`) consistent with current history.
- Scope commits narrowly; include affected service or area when helpful (`feat(openclaw): ...`).
- Pull requests should describe operational impact, list manual verification, and link related TODO items.
- Attach logs or screenshots when modifying deployment docs or SSH flows.

## Security & Configuration Tips
- Keep `.env` untracked; populate `POMERIUM_ZERO_TOKEN` and `POMERIUM_CLUSTER_DOMAIN` locally.
- Ensure `openclaw-data/pomerium-ssh/` remains read-only in Docker mounts to protect the CA key.
- Rotate keys with `./setup-ssh.sh` whenever adding contributors or machines.
