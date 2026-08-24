# sandboxed-bots

Two Hermes agents, each in its own kernel-isolated NVIDIA OpenShell sandbox,
each backed by its own locally-hosted DeepSeek-V4-Flash instance, able to
message each other on their own initiative.

Verified on an 8×B200 box: **39/39 end-to-end checks passing.**

```
Desktop (macOS)                    Linux GPU box
┌──────────────┐   SSH    ┌──────────────────────────────────────┐
│ Bots roster  │◄────────►│ host profile alpha ─┐                │
│  @alpha      │          │                     ├─► bot-alpha ───┼─► vLLM GPU 0
│  @beta       │          │ host profile beta ──┤    (sandbox)   │
│  group chat  │          │                     └─► bot-beta ────┼─► vLLM GPU 4
└──────────────┘          │                          (sandbox)   │
                          │        alpha ◄── peer messaging ──► beta
                          └──────────────────────────────────────┘
```

## What's here

| File | Purpose |
|---|---|
| `Dockerfile.bot` | Sandbox image with all five OpenShell requirements baked in |
| `Dockerfile.relay` | Tiny socat image bridging host loopback vLLM onto the sandbox network |
| `policy-bot-{alpha,beta}.yaml` | Per-bot egress policy — deny-by-default, own inference port only |
| `peer-plugin/` | Hermes plugin giving agents a real `message_teammate` tool |
| `start-sandboxed-bots.sh` | Idempotent bring-up: relays, gateways, port forwards, health checks |
| `verify.sh` | 8 fast checks that nothing critical broke |
| `e2e-test.sh` | 39 checks including live inference and live bot-to-bot messaging |

## Architecture, and why

**Agents are sandboxed; the model server is not.** Each agent runs inside an
OpenShell sandbox (own netns, landlock filesystem, deny-by-default egress).
vLLM stays on the host with the GPUs, because reloading a 149 GB MoE costs
~11 minutes and gains nothing for agent isolation.

**Sandboxes cannot reach host loopback.** vLLM binds `127.0.0.1`, and a sandbox
lives in its own network namespace at `10.200.0.x`. Two socat relays bridge
`172.18.0.1:1800x → 127.0.0.1:800x`. `172.18.0.1` is `host.openshell.internal`,
the openshell-docker bridge — *not* the default docker bridge at `172.17.0.1`.

**The desktop only sees host profiles.** It cannot enumerate profiles that live
inside containers, so each host profile points its `model.base_url` at its
sandbox's api_server (an OpenAI-compatible endpoint serving `hermes-agent`).
Every turn therefore executes inside the sandbox while still appearing in the
desktop Bots roster.

## Setup

Assumes: Docker, OpenShell CLI with a gateway, a vLLM (or any OpenAI-compatible)
server per bot on host loopback, and Hermes installed on the host.

```bash
# 1. images
docker build -f Dockerfile.bot   -t bot-sandbox:base .
docker build -f Dockerfile.relay -t bot-relay:base   .

# 2. sandboxes
openshell sandbox create --name bot-alpha --from bot-sandbox:base \
  --policy policy-bot-alpha.yaml --memory 8Gi --cpu 4
openshell sandbox create --name bot-beta  --from bot-sandbox:base \
  --policy policy-bot-beta.yaml  --memory 8Gi --cpu 4

# 3. install Hermes inside each sandbox (see "Installer notes" below)

# 4. per-bot api_server + a STRONG key
openssl rand -hex 32          # -> API_SERVER_KEY in each sandbox's .env

# 5. bring everything up
./start-sandboxed-bots.sh

# 6. verify
./e2e-test.sh                 # expect: 39 passed, 0 failed
```

Keys live in `secrets/` locally and are **git-ignored**. Never commit them.

## Peer messaging

`hermes peer dm` is an **operator** command — an agent has no tool for it. The
plugin in `peer-plugin/` closes that gap with two tools:

- `message_teammate` — send a message to a teammate, get their reply
- `list_teammates` — who is reachable, with role notes

The teammate runs a full agent turn on its own GPU in its own sandbox. Peers are
read from each profile's `bot_peers` config, so the same code works on a host
profile or inside a sandbox.

```bash
hermes -p alpha plugins enable peer-messaging   # plugins are OFF by default
```

## Hard-won gotchas

**Sandbox image (all are hard failures)**
- Must contain a `sandbox` user+group, or create fails outright.
- Must not exit: use `CMD ["sleep","infinity"]`. OpenShell injects its own entrypoint.
- `/home/sandbox` is **not writable** under landlock even when correctly owned — use `HOME=/sandbox`.
- Bake in `python3.11`, `xz-utils`, `libatomic1`, `build-essential`. The installer cannot apt-install through the egress proxy.

**Policy**
- `version: 3` is mandatory or the YAML is rejected.
- `network_policies` bind to **binary paths**, not just hosts. `curl` got 200 while `uv` got 403 on the same allowlisted URL because only `curl` was listed.
- HTTP redirects are evaluated separately: `astral.sh → releases.astral.sh` needs the target allowlisted, or fetch the final URL directly.

**Status-code ladder** — 403 = egress denied · 502 = allowed but nothing listening · 401 = reached api_server, bad key · 200 = working.

**Installer notes** — `hermes` is not on PATH inside the sandbox; call
`/sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main`. A trailing
`npm install failed` is cosmetic (browser tools only).

**Plugin deployment** — `openshell sandbox upload <name> <local> <dest>` creates
a **directory** at `<dest>`. Base64 the file and decode inside the sandbox
instead. Plugin handlers also do **not** get the profile's `.env` exported, so
read `HERMES_PEER_<NAME>_KEY` from `$HERMES_HOME/.env` directly.

**Desktop lifecycle** — `connections.json` is read **only at app launch**;
switching connections in the sidebar will not reload it. Killing a desktop
`serve` process leaves a stale `backend.lock.json` that silently blocks respawn —
remove it too.

**A bot going quiet is usually correct.** Room rules say reply only with
something new to add, so `(pass)` on a greeting is intended behaviour. But a bot
that promised future work ("I'll write that doc") will pass on every later round
and look broken — check its room session before debugging infrastructure.

**GPU util is a bad progress signal.** Turns against a warm MoE take 1–3 s;
sampling `nvidia-smi` every 10 s shows 0% throughout a working conversation.
Count turns in `agent.log` instead.

## Verifying isolation is real

Do not trust the reply text — a bot can describe its sandbox from its SOUL
without executing there. Two independent checks:

```bash
# platform must be 'desktop' for a real group-chat turn
grep -a "conversation turn" ~/.hermes/profiles/alpha/logs/agent.log | tail -1

# the sandbox's OWN session count must increase across the turn
openshell sandbox exec -n bot-alpha -- /bin/sh -c \
  '/sandbox/.hermes/hermes-agent/venv/bin/python -c "import sqlite3;print(list(sqlite3.connect(\"/sandbox/.hermes/state.db\").execute(\"select count(*) from sessions\"))[0][0])"'
```

## Operating on a shared box

- Never background an SSH job whose first line is destructive — a `sandbox delete` can fire minutes later, after you rebuilt the thing it deletes.
- Killing the local SSH client does **not** kill the remote command. Check with `pgrep -fa` and kill real PIDs.
- Never `pkill -f "docker run"` over SSH: the pattern matches your own SSH command string and kills your session.
- Never `docker rm` with `ancestor=` or a broad filter — it takes out unrelated containers, including other teams' work.
