# Hermes bots in NemoClaw sandboxes

Run a team of [Hermes Agent](https://github.com/NousResearch/hermes-agent) bots on
one GPU host, each in its own [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)
sandbox managed by [NemoClaw](https://github.com/NVIDIA/NemoClaw), traced end to end
with [NeMo Relay](https://docs.nvidia.com/nemo/relay/). Talk to them from Hermes
Desktop as a group chat: `@researcher dig into X, then hand it to @reviewer`.

One command brings it up. The same command brings it back after a reboot.

```
$ ./swarm up
▸ preflight              18 passed, 0 failed
▸ image                  hermes-bot:v2026.8.31 present
▸ tracing collector      swarm-otel running on 172.18.0.1:4319
▸ bot researcher         sandbox Ready · Hermes v0.21.0 · api_server :8490 · relay on
▸ bot reviewer           sandbox Ready · Hermes v0.21.0 · api_server :8491 · relay on
▸ mesh                   2 bots, 2 directed links
▸ status                 11 ok, 0 failed
```

## Why sandboxes

A Hermes bot is a persistent agent with its own memory, tools, credentials, and
the ability to run shell commands and reach the network. A Hermes *profile* keeps
bots from reading each other's files; it does not stop a bot from reading yours.

Each bot here runs in an OpenShell sandbox: its own PID, network, and mount
namespaces, a filesystem it owns, and egress that is denied unless a policy allows
it. The researcher can reach the model endpoint and the collector. It cannot reach
the host's loopback, the reviewer's files, or any site you did not list. The
reviewer is the same, with a different list. `./swarm test` proves each of those
claims with a live probe rather than asserting them.

## What you need

| | Version used to verify this example |
|---|---|
| Linux host with Docker | Ubuntu 24.04, Docker 29 |
| [OpenShell](https://github.com/NVIDIA/OpenShell) + [NemoClaw](https://github.com/NVIDIA/NemoClaw) CLI | openshell 0.0.85, nemoclaw 0.0.97 |
| Hermes Agent on the host | v0.21.0 (needed for `hermes peer` and Bot Mode) |
| An OpenAI-compatible inference endpoint | any; the example was verified against a hosted Nemotron 3 Super endpoint |
| Hermes Desktop on your laptop | 0.21 |

No GPU on the host is required if your inference endpoint is remote. Deploying a
model server is out of scope.

## Quick start

On the host, as the user who owns `~/.hermes`:

```bash
git clone https://github.com/NVIDIA/nemoclaw-community
cd nemoclaw-community/examples/nemoclaw-hermes-swarm

cp swarm.env.example swarm.env
$EDITOR swarm.env                      # INFERENCE_BASE_URL and INFERENCE_MODEL

umask 077
mkdir -p ~/.secrets
printf '%s' 'your-inference-api-key' > ~/.secrets/inference.key

./swarm up                             # 8 to 12 minutes the first time
./swarm test                           # 50 checks; expect 50 passed
```

Then in Hermes Desktop: **Settings, Connections, Add connection, SSH**, point it at
the host, restart the app. `researcher` and `reviewer` appear in the Bots roster.
Make a group chat with both and try:

> @researcher what changed in Hermes 0.21 for bot mode? Hand your findings to
> @reviewer for a security read.

## Day to day

```bash
./swarm add analyst --soul souls/critic.md    # a third bot, meshed to the others
./swarm add scout --role "You find primary sources and quote them."
./swarm ls                                    # table: bot, sandbox, port, peers, gateway
./swarm status                                # health ladder per bot
./swarm rm scout --yes
./swarm traces researcher                     # relay state and collector counters
./swarm doctor                                # preflight without changing anything
./swarm down --yes                            # remove every bot
```

After a host reboot: `./swarm up`. Sandboxes and profiles survive; processes do not.

## What is in the box

```
swarm                     the CLI; everything goes through it
swarm.env.example         config: endpoint, model, bot list, tracing
lib/                      one module per concern: preflight, image, policy, sandbox,
                          bot, host, mesh, tracing, verify
image/Dockerfile          sandbox image with Hermes pinned at a tag
policies/                 egress policy template + the additive OTLP preset
souls/                    roles: researcher, reviewer, critic, qa
plugins/teammates/        message_teammate / list_teammates tool for handoffs
observability/            NeMo Relay plugin config + OTel collector config
tests/e2e.sh              50 live checks; tests/presubmit.sh gates a public push
skill/SKILL.md            hand this to your own Hermes agent to run the above
docs/                     architecture, customizing, tracing, troubleshooting
SECURITY.md               what is protected, what is not, what the operator holds
```

## Let your agent do it

`skill/SKILL.md` is a Hermes skill. Install it and your own agent can bring up,
extend, verify, and debug a swarm on a host you point it at:

```bash
cp -r skill ~/.hermes/skills/nemoclaw-hermes-swarm
hermes chat -q "Use the nemoclaw-hermes-swarm skill to add a bot named scout on myhost that reviews pull requests."
```

The skill carries every trap this example hit while being built, so the agent does
not rediscover them.

## Scope

This example does:

- one sandbox per bot, deny-by-default egress, kernel namespace isolation
- Hermes 0.21 baked into the image at a pinned tag, no per-sandbox GitHub clone
- bot to bot handoffs through the sandbox boundary, verified with a planted secret
- NeMo Relay traces from every bot to one OpenTelemetry collector, LangSmith optional
- Hermes Desktop group chat over SSH, restore after reboot, a live test suite

It does not:

- deploy or tune a model server
- run the bots on more than one host
- expose the bots to anything but your Desktop and each other
- link a multi-bot handoff into one trace tree (Relay emits one tree per bot turn)

## Further reading

| | |
|---|---|
| [docs/architecture.md](docs/architecture.md) | the pieces, the two gateways, the network boundaries |
| [docs/customizing.md](docs/customizing.md) | roles, policies, models, more bots |
| [docs/tracing.md](docs/tracing.md) | Relay, the collector, LangSmith, what a trace shows |
| [docs/troubleshooting.md](docs/troubleshooting.md) | symptom first, in the order that finds it fastest |
| [SECURITY.md](SECURITY.md) | threat model in plain language |
