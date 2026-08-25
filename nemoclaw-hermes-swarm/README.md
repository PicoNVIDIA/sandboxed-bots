# NemoClaw Hermes Swarm

Run a team of [Hermes Agent](https://github.com/NousResearch/hermes-agent) bots on
one machine, each isolated in its own NVIDIA OpenShell sandbox, able to message
each other, and usable together from the Hermes desktop app.

One command adds an agent. Point it at any OpenAI-compatible endpoint you already
have.

```bash
./scripts/spawn-agent.sh --name reviewer --role "You review code for security problems."
```

```
Hermes desktop (your laptop)          Your cluster / workstation
┌────────────────────┐   SSH   ┌────────────────────────────────────────────┐
│  Bots roster       │◄───────►│  profile alpha ──► bot-alpha  (sandbox) ─┐ │
│   @alpha  @beta    │         │  profile beta  ──► bot-beta   (sandbox) ─┼─┼──► your
│   @reviewer        │         │  profile reviewer ► bot-reviewer(sandbox)┘ │    inference
│  group chat        │         │                                            │    endpoint
└────────────────────┘         │      alpha ◄── message_teammate ──► beta   │
                               └────────────────────────────────────────────┘
```

## Why this exists

A single agent is easy. A *team* of agents that can be trusted to run real work is
not, because each one needs a boundary. This example gives every agent its own
kernel-isolated sandbox with a deny-by-default egress policy, so an agent can only
reach what you explicitly allow — its inference endpoint, its teammates, and
nothing else.

What you get:

- **One sandbox per agent** — separate PID namespace, separate filesystem,
  separate egress policy
- **Agent-to-agent messaging** — a `message_teammate` tool, so agents delegate to
  each other without you relaying
- **Desktop integration** — agents appear in the Hermes Bots roster and can be
  put in a group chat together
- **One-command lifecycle** — `spawn-agent.sh` to add, `--list` to inspect,
  `--destroy` to remove cleanly
- **A real test suite** — verifies isolation and messaging with evidence, not
  assertions

## Scope

This example stands up one or more Hermes agents, each in its own OpenShell
sandbox, wires them into a peer mesh, and makes them visible to the Hermes
desktop app.

It does not:

- deploy or manage an inference server
- provision GPUs or a model
- create the OpenShell gateway for you
- configure messaging platforms (Slack, Outlook, etc.)

You supply one OpenAI-compatible inference endpoint reachable from the sandboxes —
vLLM, SGLang, NIM, or a hosted API — via `.env`.

## Provenance and support

Independent community contribution. Not a supported part of NemoClaw core; its
placement in the catalog aids discovery and does not imply NVIDIA support or a
readiness guarantee. Operators remain responsible for their own credentials,
endpoint availability, and any production hardening.

## Prerequisites

Versions below are what this example was developed and verified against. Nearby
versions will likely work; these are the ones actually tested.

| Requirement | Verified with | Notes |
|---|---|---|
| Linux host with Docker | Docker 29.6.2 | Compose v2 (`docker compose`) — the legacy `docker-compose` binary is not used |
| OpenShell CLI + active gateway | openshell 0.0.85 | `openshell gateway list` must show a gateway marked `*` |
| NemoClaw CLI *(strongly recommended)* | nemoclaw v0.0.97 | Makes policy edits **additive**. Without it, policy changes use `openshell policy set`, which **replaces** a sandbox's entire policy |
| Hermes Agent on the host | v0.20.5, Python 3.11 | Provides the `hermes` CLI for profiles and gateways |
| An OpenAI-compatible endpoint | any | You supply URL, model name, and key via `.env` |
| Hermes desktop app *(optional)* | — | Only for the Bots roster and group chat |

Sandbox image: **Ubuntu 24.04** with **Python 3.11** (from the deadsnakes PPA).
Policy schema: **`version: 3`**.

You do **not** need a GPU on the host if your inference endpoint is remote.

### A PATH gotcha worth knowing up front

`openshell`, `nemoclaw`, and `hermes` typically install into `~/.local/bin`, which
is added by `~/.profile` — a file that a **non-login** shell does not read. So this
fails:

```console
$ ssh yourhost 'openshell --version'
bash: line 1: openshell: command not found
```

Use a login shell for remote invocations, and note that the Hermes desktop app
probes the host with `bash -lc 'command -v hermes'` for exactly this reason:

```bash
ssh yourhost 'bash -lc "openshell --version"'
```

`scripts/00-preflight.sh` checks this for you.

## Quickstart

```bash
git clone <this-repo>
cd nemoclaw-hermes-swarm

cp .env.example .env
$EDITOR .env                      # set INFERENCE_URL and INFERENCE_KEY

./scripts/00-preflight.sh         # checks prerequisites, fails loudly if missing
./scripts/01-build-image.sh       # builds the sandbox base image
./scripts/spawn-agent.sh --name alpha --role "You are Alpha, a research assistant."
./scripts/spawn-agent.sh --name beta  --role "You are Beta, a critic who stress-tests Alpha's work."
./scripts/e2e-test.sh             # verifies isolation, messaging, and roster visibility
```

Then restart the Hermes desktop app and both agents appear in the Bots roster.

## How it works

Five moving parts. The unintuitive ones are 3 and 4.

**1. A sandbox per agent.** `openshell sandbox create` from a purpose-built image.
Each sandbox gets its own PID namespace, its own writable filesystem, and a
policy that denies egress by default.

**2. Hermes inside the sandbox.** The agent's brain runs *in* the sandbox, so its
tool calls — terminal, file writes, network — are all subject to the policy.

**3. Two gateways per agent, not one.** This is the part that surprises people:

| gateway | where it runs | what it does |
|---|---|---|
| in-sandbox | inside `bot-<name>` | serves the api_server the host profile calls |
| **host-side** | on the host | makes the profile report `running` — **the desktop roster only lists these** |

An agent with only the in-sandbox gateway works perfectly over HTTP and is
completely invisible in the desktop. `spawn-agent.sh` starts both.

**4. The bridge, not loopback.** A sandbox has its own network namespace, so
`127.0.0.1` inside it is *the sandbox*, not your host. Cross-boundary traffic goes
via `host.openshell.internal`, which resolves to the OpenShell docker bridge — not
the default docker bridge. If your inference server binds only to loopback, this
example includes a small socat relay to expose it on the bridge.

**5. The peer mesh.** Each agent runs an api_server published onto the bridge by
`openshell forward service`. A small Hermes plugin gives every agent a
`message_teammate` tool that POSTs to a teammate's api_server. The teammate runs a
full agent turn and returns its answer.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/00-preflight.sh` | Verify prerequisites before you waste time |
| `scripts/01-build-image.sh` | Build the sandbox base image |
| `scripts/spawn-agent.sh` | Add / list / destroy an agent |
| `scripts/start-swarm.sh` | Restore everything after a reboot (idempotent) |
| `scripts/e2e-test.sh` | Full verification suite |

### Managing agents

```bash
./scripts/spawn-agent.sh --name gamma --role "..."      # add
./scripts/spawn-agent.sh --name gamma --role-file r.md  # role from a file
./scripts/spawn-agent.sh --list                         # inspect the swarm
./scripts/spawn-agent.sh --name gamma --destroy         # remove cleanly
```

By default a new agent **shares** an existing inference endpoint, so adding one
costs no GPU and no model load. Adding an agent takes a few minutes, most of it
installing Hermes inside the new sandbox.

## Verifying it actually works

Do not trust an agent's self-description — it can recite its role from its prompt
with every tool broken. `e2e-test.sh` checks evidence instead:

- **Isolation:** writes a different marker to the same path in every sandbox and
  confirms each sees only its own
- **Messaging:** plants a random secret inside agent A's sandbox and requires
  agent B to retrieve it through `message_teammate` — B cannot know it otherwise
- **Roster visibility:** asserts every profile reports `running` and has a live
  host gateway
- **Egress policy:** confirms allowed routes return 200 and disallowed ones are
  blocked

## Security notes

- **Egress is deny-by-default.** An agent reaches only what its policy lists.
  Widening a policy is a deliberate act; `policies/` has commented examples.
- **Policies bind to binary paths, not just hosts.** Allowlisting a host is not
  enough — the calling binary must be listed too. This is the single most
  confusing thing about OpenShell policies.
- **Secrets stay out of the repo.** Keys live in `.env` (gitignored) and in
  per-agent key files created at runtime with `openssl rand -hex 32`.
- **api_server keys must be strong.** That endpoint dispatches terminal-capable
  work; Hermes refuses to start with a weak key, and it is right to.
- **The sandbox boundary protects the agent's tools, not your model server.** If
  your inference server runs on the host, it is outside the boundary.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Agent works via CLI but is missing from the desktop roster | No host-side gateway — see "two gateways" above |
| Desktop shows nothing at all | `connections.json` is read only at app launch; fix it, *then* restart |
| `403` from inside a sandbox | Policy denied it — host not allowed, or the calling binary is not in `binaries` |
| `502` from inside a sandbox | Policy allowed it, but nothing is listening — usually a loopback-bound service |
| Spawn hangs with an empty `/sandbox/.hermes` | Install step stalled; see `docs/troubleshooting.md` for the recovery |
| A bot stays silent in group chat | Often correct — room rules say reply only with something new to add |

Full details in [docs/troubleshooting.md](docs/troubleshooting.md).

## Repository layout

```
nemoclaw-hermes-swarm/
├── README.md
├── .env.example              # copy to .env; never commit .env
├── .gitignore
├── Dockerfile.sandbox        # sandbox base image
├── Dockerfile.relay          # socat relay for loopback-bound endpoints
├── scripts/
├── policies/                 # per-agent egress policy templates
├── plugins/peer-messaging/   # the message_teammate tool
├── souls/                    # example agent role definitions
└── docs/
```

## License

Apache-2.0. See [LICENSE](LICENSE).
