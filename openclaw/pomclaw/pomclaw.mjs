#!/usr/bin/env node
// pomclaw.mjs — in-container helper for the bootstrap orchestrator.
//
// Runs inside the openclaw-gateway container. The host-side bootstrap.sh
// invokes subcommands of this script via `docker compose exec` and reads
// their stdout. Stays small and dep-free: uses Node 22+ built-in WebSocket
// and the openclaw CLI on PATH.

import { execSync } from "node:child_process";

const PROTOCOL = 3;
const WS_URL = process.env.POMCLAW_WS_URL ?? "ws://127.0.0.1:18789";
const WS_TIMEOUT_MS = Number(process.env.POMCLAW_WS_TIMEOUT_MS ?? 10_000);

// stdio: stderr=ignore so the openclaw CLI's warnings (e.g. "Config path
// not found: gateway.auth.mode" on a fresh install before any config has
// been written) don't bleed to the bootstrap script's terminal. The
// try/catch already turns failures into empty / default returns; this just
// completes the silence.
const QUIET_STDIO = ["ignore", "pipe", "ignore"];

function configGet(path) {
  try {
    return execSync(`openclaw config get ${path}`, {
      encoding: "utf8",
      stdio: QUIET_STDIO,
    })
      .trim()
      .replace(/^"|"$/g, "");
  } catch {
    return "";
  }
}

function devicesList() {
  try {
    return JSON.parse(
      execSync("openclaw devices list --json", {
        encoding: "utf8",
        stdio: QUIET_STDIO,
      }),
    );
  } catch {
    return { pending: [], paired: [] };
  }
}

const subcommands = {
  "auth-mode": () => console.log(configGet("gateway.auth.mode")),
  token: () => console.log(configGet("gateway.auth.token")),
  "pending-count": () => console.log((devicesList().pending ?? []).length),
  "operators-count": () => {
    const ops = (devicesList().paired ?? []).filter((d) =>
      (d.roles ?? []).includes("operator"),
    );
    console.log(ops.length);
  },
  "latest-pending": () => {
    const sorted = (devicesList().pending ?? [])
      .slice()
      .sort((a, b) => (a.ts ?? 0) - (b.ts ?? 0));
    console.log(sorted.at(-1)?.requestId ?? "");
  },
  "trigger-pairing": async () => {
    const token = process.env.OPENCLAW_GATEWAY_TOKEN;
    if (!token) {
      console.error("OPENCLAW_GATEWAY_TOKEN env var is required");
      process.exit(2);
    }
    const ws = new WebSocket(WS_URL);
    const timeout = setTimeout(() => {
      console.error(`timed out after ${WS_TIMEOUT_MS}ms`);
      try {
        ws.close();
      } catch {}
      process.exit(3);
    }, WS_TIMEOUT_MS);

    ws.addEventListener("open", () => {
      ws.send(
        JSON.stringify({
          type: "req",
          id: "pomclaw-bootstrap",
          method: "connect",
          params: {
            minProtocol: PROTOCOL,
            maxProtocol: PROTOCOL,
            client: {
              id: "gateway-client",
              version: "0.0.0-pomclaw-bootstrap",
              platform: "node",
              mode: "backend",
            },
            auth: { token },
            scopes: ["operator.admin"],
          },
        }),
      );
    });

    ws.addEventListener("message", (event) => {
      // Any response (success, "pairing required", or scope-stripped ack)
      // is enough: by this point the gateway has registered the pending
      // pairing request, which is all bootstrap.sh needs to proceed.
      clearTimeout(timeout);
      try {
        const msg = JSON.parse(String(event.data));
        console.log(JSON.stringify(msg));
      } catch {
        console.log(String(event.data));
      }
      ws.close();
      process.exit(0);
    });

    ws.addEventListener("error", (event) => {
      clearTimeout(timeout);
      console.error(`WebSocket error: ${event.message ?? "unknown"}`);
      process.exit(4);
    });
  },
};

const subcommand = process.argv[2];
const fn = subcommands[subcommand];
if (!fn) {
  console.error(
    `Usage: pomclaw.mjs <${Object.keys(subcommands).join("|")}>`,
  );
  process.exit(2);
}
await fn();
