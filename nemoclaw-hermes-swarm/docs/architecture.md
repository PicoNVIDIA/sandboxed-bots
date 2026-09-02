# Architecture

Five diagrams and a table. If you read one thing, read the two-gateway diagram;
conflating those two gateways is the most common way this setup breaks.

## Components

```
  YOUR LAPTOP                     │             THE HOST (Linux + Docker + OpenShell)
                                  │
  ┌─────────────────────┐   SSH   │   ┌────────────────────────────────────────────┐
  │ Hermes Desktop      │─────────┼──▶│ host gateway per bot                       │
  │  Bots roster        │         │   │   hermes -p researcher gateway run         │
  │  group chat         │         │   │   hermes -p reviewer   gateway run         │
  └─────────────────────┘         │   └───────────────┬────────────────────────────┘
                                  │                   │ model.base_url
                                  │                   ▼
                                  │       OpenShell bridge  172.18.0.1
                                  │       ┌──────────┬──────────┬────────┐
                                  │       │  :8490   │  :8491   │ :4319  │
                                  │       └────┬─────┴────┬─────┴───┬────┘
                                  │            │          │         │
                                  │   ┌────────▼───┐ ┌────▼──────┐ ▼
                                  │   │v2-researcher│ │v2-reviewer│ swarm-otel
                                  │   │            │ │           │ (OTel collector)
                                  │   │ Hermes 0.21│ │ Hermes    │      │
                                  │   │ api_server │ │ api_server│      ▼ optional
                                  │   │ Relay ─────┼─┼─Relay ────┼──▶ LangSmith
                                  │   └─────┬──────┘ └─────┬─────┘
                                  │         └───────┬──────┘
                                  │                 ▼
                                  │   ┌────────────────────────────────────────────┐
                                  │   │ inference endpoint (OpenAI-compatible)     │
                                  │   │ hosted API, NIM, vLLM, SGLang: your choice │
                                  │   └────────────────────────────────────────────┘
```

Each sandbox is a separate container with its own PID, network, mount, and IPC
namespaces. Bots cannot see each other's processes or files. `./swarm test`
section 3 reads `/proc/self/ns/*` from inside each sandbox and from the host and
checks all three differ.

## Two gateways per bot

Every bot runs two Hermes gateway processes. They do different jobs, and missing
the second produces a bot that works over HTTP yet never appears in Desktop.

```
                 ┌──────────────────────────────────────────────┐
                 │ HOST                                         │
  Desktop ──────▶│  host gateway:  hermes -p researcher gateway run
  Bots roster    │    makes `hermes profile list` say "running" │
  lists THIS     │    the only thing the roster sees            │
                 │    model.base_url = http://172.18.0.1:8490/v1│
                 │                        │                     │
                 │  bridge forward        │ openshell forward   │
                 │  172.18.0.1:8490 ──────┼──▶ v2-researcher:8490
                 └────────────────────────┼─────────────────────┘
                                          │
                 ┌────────────────────────▼─────────────────────┐
                 │ SANDBOX v2-researcher                        │
                 │  in-sandbox gateway:  hermes gateway run     │
                 │    serves the api_server on :8490            │
                 │    runs the agent loop and every tool call   │
                 │    reads SOUL.md, bot_peers, relay config    │
                 │    talks to the inference endpoint           │
                 └──────────────────────────────────────────────┘
```

The host profile is a thin client. Its `model.base_url` points at the sandbox's
api_server, so a "model call" from the host profile is a full agent turn inside
the sandbox. That is what makes `hermes -p researcher chat` and a Desktop
`@researcher` execute tools in the sandbox rather than on the host.

| You see | Meaning |
|---|---|
| api_server 200, `hermes -p X chat` works, X absent from roster | host gateway down; `./swarm up` restarts it |
| `hermes profile list` says running, chat hangs | in-sandbox gateway down or model endpoint down; `./swarm status` |
| both fine, Desktop room dead | Desktop backend stale; restart the app |

## A request, end to end

```
Desktop ─@researcher─▶ host gateway ─POST /v1/chat/completions─▶ bridge :8490
                                                                       │
                       ┌───────────────────────────────────────────────▼──┐
                       │ v2-researcher                                    │
                       │  api_server ─▶ agent loop ─▶ tools (terminal,    │
                       │                    │          web_search, ...)   │
                       │                    ├─▶ inference endpoint        │
                       │                    └─▶ Relay spans ─▶ :4319      │
                       └──────────────────────────────────────────────────┘
```

Every tool the bot runs executes inside the sandbox under its egress policy.
`./swarm test` section 7 asks a bot to run `hostname` and checks the answer is the
sandbox's, not the host's.

## Handoff between bots

```
 v2-researcher                                   v2-reviewer
 ┌──────────────────────────┐                    ┌──────────────────────────┐
 │ agent decides to hand off│                    │                          │
 │ message_teammate(        │  POST :8491        │ api_server ─▶ agent turn │
 │   reviewer, "...")  ─────┼──── bridge ───────▶│   in reviewer's Bot Chat │
 │                          │  Bearer <reviewer  │   with reviewer's SOUL   │
 │ reply lands in the       │◀── key> ───────────┼── reply                  │
 │ researcher's turn        │                    │                          │
 └──────────────────────────┘                    └──────────────────────────┘
```

Three things make this pass the sandbox boundary, and `./swarm add` sets up all
three in both directions for every pair:

1. `hermes peer add reviewer --url http://host.openshell.internal:8491 --key …`
   inside the researcher's sandbox (the agent loop runs there and reads that config)
2. an additive egress rule in the researcher's policy allowing `:8491`
3. the `teammates` plugin, which turns "message reviewer" into a real tool call
   with the target validated against the peer list

Hermes 0.21's built-in `message_agent` covers the same job for bots managed by
Desktop; the plugin keeps handoffs working from the CLI and in rooms with no
Desktop in the loop.

## Tracing

```
 sandbox ─── Relay (in-process, gen_ai spans) ───▶ swarm-otel :4319 ──▶ debug log
                                                        │
                                                        └──▶ LangSmith (if key file present)
```

Relay is part of Hermes. `./swarm up` writes a `relay-plugins.toml` per bot,
points Hermes at it through `HERMES_NEMO_RELAY_PLUGINS_TOML`, and allows egress
to the collector. The collector keeps the LangSmith key on the host; sandboxes
never hold it. See [tracing.md](tracing.md).

## Network boundaries

| From | To | Allowed | How |
|---|---|---|---|
| sandbox | inference endpoint | yes | policy group `inference` |
| sandbox | collector `172.18.0.1:4319` | yes | additive preset `otlp-export` |
| sandbox | another bot's api_server | yes, per pair | additive preset `peer-<name>` |
| sandbox | host loopback `127.0.0.1` | no | different network namespace |
| sandbox | any other host | no | deny by default; HTTPS gets `CONNECT … 403` |
| sandbox | another sandbox's filesystem | no | separate mount namespace |
| host | sandbox api_server | with the bot's key | bridge forward + `API_SERVER_KEY` |
| Desktop | host | SSH | Hermes Desktop connection |
| Desktop | sandbox | never directly | always through the host profile |

## Where things live

| | Host | Sandbox |
|---|---|---|
| bot's SOUL, config, sessions, memory | `~/.hermes/profiles/<bot>/` (thin) | `/sandbox/.hermes/` (real) |
| api key for the bot's api_server | `~/.swarm/keys/<bot>.key` (600) | `/sandbox/.hermes/.env` |
| inference key | `~/.secrets/inference.key` (600) | `/sandbox/.hermes/.env` |
| rendered policies | `~/.swarm/policies/` | applied to the sandbox |
| relay config | `~/.swarm/relay/<bot>.relay-plugins.toml` | `/sandbox/.hermes/relay-plugins.toml` |
| logs | `~/.swarm/logs/<bot>-{gateway,forward,host-gateway}.log` | `/sandbox/.hermes/logs/` |
| LangSmith key | `~/.langsmith/api_key` (600), collector env only | never |
