# NemoClaw Hermes Swarm

Run several [Hermes Agent](https://github.com/NousResearch/hermes-agent) instances
on one machine, each isolated in its own NVIDIA OpenShell sandbox. The agents can
message each other and appear together in the Hermes desktop app's group chat.

Adding an agent is one command:

```bash
./scripts/spawn-agent.sh --name reviewer --role "You review code for security problems."
```

## Scope

This example sets up the agents, their sandboxes, their egress policies, the
messaging between them, and the desktop wiring.

It does not:

- deploy or manage an inference server
- provision GPUs or download a model
- create the OpenShell gateway for you
- configure messaging platforms such as Slack or Outlook

You supply one OpenAI-compatible inference endpoint that the sandboxes can reach.
vLLM, SGLang, NIM, and hosted APIs all work.

## Prerequisites

Versions below are what this was built and tested against.

| Requirement | Tested with | Notes |
|---|---|---|
| Linux host with Docker | Docker 29.6.2 | Compose v2; the legacy `docker-compose` binary is not used |
| OpenShell CLI and a running gateway | openshell 0.0.85 | `openshell gateway list` must show one marked `*` |
| NemoClaw CLI | v0.0.97 | Strongly recommended: makes policy edits additive. Without it, `openshell policy set` replaces a sandbox's entire policy |
| Hermes Agent on the host | v0.20.5, Python 3.11 | Provides the `hermes` CLI |
| An OpenAI-compatible endpoint | any | URL, model name, and key go in `.env` |
| Hermes desktop app | optional | Only for the Bots roster and group chat |

Sandbox image: Ubuntu 24.04 with Python 3.11. Policy schema `version: 3`.

You do not need a GPU on the host if your endpoint is remote.

### PATH gotcha

`openshell`, `nemoclaw`, and `hermes` install into `~/.local/bin`, which is added
by `~/.profile`. Non-login shells do not read that file, so this fails:

```console
$ ssh yourhost 'openshell --version'
bash: line 1: openshell: command not found
```

Use a login shell for remote commands:

```bash
ssh yourhost 'bash -lc "openshell --version"'
```

The desktop app probes the host the same way. `scripts/00-preflight.sh` checks it.

## Quickstart

Run these in order. Each step checks the previous one worked.

```bash
# 1. get the code and configure
git clone <this-repo>
cd nemoclaw-hermes-swarm
cp .env.example .env
$EDITOR .env                      # set INFERENCE_URL and INFERENCE_MODEL

# 2. check prerequisites before spending time on a build
./scripts/00-preflight.sh

# 3. build the sandbox image
./scripts/01-build-image.sh

# 4. create two agents: a researcher and a critic
./scripts/02-bootstrap-two-agents.sh

# 5. confirm isolation, messaging and roster visibility
./scripts/e2e-test.sh
```

Then restart the Hermes desktop app. Both agents appear in the Bots roster and can
be put in a group chat together.

Step 4 takes 10 to 20 minutes. Most of that is installing Hermes inside each new
sandbox.

## How it works

Five parts. The first two are where people get stuck.

**Two gateways per agent.** One runs inside the sandbox and serves the api_server.
One runs on the host and is what makes `hermes profile list` report `running`. The
desktop roster only lists agents that have the host-side gateway, so an agent with
just the in-sandbox one works over HTTP and is invisible in the app.

**The bridge, not loopback.** A sandbox has its own network namespace, so
`127.0.0.1` inside it is the sandbox, not your host. Cross-boundary traffic uses
`host.openshell.internal`, which resolves to the OpenShell docker bridge. If your
inference server binds only to loopback, `Dockerfile.relay` republishes it on the
bridge.

**A sandbox per agent.** Separate PID, network, mount, and IPC namespaces, and an
egress policy that denies by default.

**Hermes inside the sandbox.** The agent's tool calls happen inside the boundary,
so terminal commands, file writes, and network access are all subject to the
policy.

**Agent-to-agent messaging.** A plugin gives each agent a `message_teammate` tool
that POSTs to a teammate's api_server. The teammate runs a full agent turn in its
own sandbox and returns the answer.

Diagrams for all of this, including the network boundaries and status codes:
[docs/architecture.md](docs/architecture.md).

## Managing agents

```bash
./scripts/spawn-agent.sh --name gamma --role "..."       # add
./scripts/spawn-agent.sh --name gamma --role-file r.md   # role from a file
./scripts/spawn-agent.sh --list                          # inspect the swarm
./scripts/spawn-agent.sh --name gamma --destroy          # remove cleanly
./scripts/start-swarm.sh                                 # restore after a reboot
```

A new agent shares an existing inference endpoint by default, so adding one costs
no GPU and no model load.

## Verifying it works

An agent can describe its role perfectly while every tool is broken, so the test
suite checks evidence instead of self-reports:

- **Isolation**: writes a different marker to the same path in every sandbox and
  confirms each sees only its own
- **Messaging**: plants a random secret inside agent A's sandbox and requires agent
  B to retrieve it through `message_teammate`
- **Roster visibility**: asserts every profile reports `running` with a live
  host-side gateway
- **Policy**: confirms allowed routes return 200 and denied ones do not

```bash
./scripts/e2e-test.sh
```

## Repository layout

```
nemoclaw-hermes-swarm/
├── README.md
├── .env.example              # copy to .env; never commit .env
├── Dockerfile.sandbox        # sandbox base image
├── Dockerfile.relay          # socat relay for loopback-bound endpoints
├── scripts/                  # preflight, build, bootstrap, spawn, test, repair
├── policies/                 # egress policy templates
├── plugins/peer-messaging/   # the message_teammate tool
├── souls/                    # example agent roles
├── observability/            # optional NeMo Relay to LangSmith tracing
├── skill/                    # Hermes skill so an agent can drive this setup
└── docs/                     # architecture, troubleshooting, customization
```

## Documentation

| Document | Answers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | How the pieces fit, what crosses which boundary |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Something is broken |
| [docs/customizing-agents.md](docs/customizing-agents.md) | Changing roles, policies, models |
| [observability/README.md](observability/README.md) | Tracing agent runs into LangSmith |
| [skill/README.md](skill/README.md) | Letting your own Hermes agent drive this setup |

## Security notes

- Egress is deny-by-default. An agent reaches only what its policy lists.
- Policies bind to binary paths as well as hosts. Allowlisting a host is not
  enough; the calling program must be listed too. This is the most confusing part
  of OpenShell policies.
- Keys live in `.env`, which is gitignored, and in per-agent key files generated at
  runtime with `openssl rand -hex 32`.
- The api_server dispatches terminal-capable work, so its key must be strong.
  Hermes refuses to start with a weak one.
- The sandbox boundary protects the agent's tools, not your model server. An
  inference server on the host sits outside it.

## Provenance

Independent community contribution. Not a supported part of NemoClaw core; its
placement in the catalog aids discovery and does not imply NVIDIA support. You
remain responsible for your own credentials, endpoint availability, and any
production hardening.

## License

Apache-2.0. See [LICENSE](LICENSE).
