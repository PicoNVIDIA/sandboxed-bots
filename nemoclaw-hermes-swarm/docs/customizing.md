# Customizing

Three things define a bot. Change any of them independently.

| What | Where | Changes |
|---|---|---|
| Role (SOUL) | `souls/<name>.md` | how the bot thinks, what it refuses, how it writes |
| Policy | `policies/bot.template.yaml`, plus additive presets | what it can reach on the network and disk |
| Model | `swarm.env` | which endpoint, which model, context and token budget |

Start with the role. Most of what makes a bot useful is there and it needs no
infrastructure change.

## The role (SOUL.md)

A soul is a markdown file that becomes the bot's system prompt. `./swarm add`
writes it to `/sandbox/.hermes/SOUL.md` inside the sandbox and appends two short
sections: a Runtime note (sandbox name, endpoint, egress posture) and a Teammates
note (how to hand work to another bot).

```bash
./swarm add auditor --soul ./souls/reviewer.md
./swarm add auditor --role "You audit Terraform for security problems."
```

To change a running bot's role, edit the file and re-run `./swarm add` for that
bot after `./swarm rm`; roles are part of the bot's identity, not hot config.

### What separates a useful role from a decorative one

**Give it a method, not just an identity.** "You are a researcher" produces
generic output. A numbered procedure produces consistent output. See
`souls/researcher.md` for the four-phase pattern.

**Write the rules that stop the failure you care about.** Each of these was added
after a real one:

```markdown
## Hard rules
- Never invent a source, citation, URL, number, or quote.
- Never cite an issue or PR you did not fetch in THIS session. Recalling an
  identifier from memory is fabrication even when it happens to exist.
- Separate what you found from what you inferred from what you assume, and use
  those words.
- If a tool cannot reach what you need, name the blocker. A blocked source is a
  finding, not something to work around.
```

**Answer in the same message.** Nothing re-prompts a bot. A reply of "I'll look
into that and report back" is a dead end for whoever asked.

```markdown
Deliver a usable answer in THE SAME MESSAGE. Never ask the user to scope the
task and never promise to report back later.
```

**Cap retries.** A bot that hits a policy denial and tries three workarounds
burns six minutes and produces nothing.

```markdown
If a source is unreachable, report what you have and name the blocker in one
line. Three failed attempts with the same tool means the path is closed.
```

## The policy

Every bot starts from `policies/bot.template.yaml`: a read-only system, a
writable `/sandbox`, and exactly one network group, `inference`. Everything
else is denied. `./swarm` then adds presets as needed:

| Preset | Added by | Allows |
|---|---|---|
| `otlp-export` | `swarm up` / `swarm add` when `TRACING=on` | the collector on the bridge |
| `peer-<name>` | mesh sync, one per teammate | that teammate's api_server port |

To give one bot more reach, write your own preset and apply it additively:

```yaml
# policies/web-research.yaml
preset:
  name: web-research
  description: Read public documentation sites
network_policies:
  web-research:
    name: web-research
    endpoints:
      - { host: docs.nvidia.com, port: 443, tls: skip }
      - { host: github.com, port: 443, tls: skip }
      - { host: raw.githubusercontent.com, port: 443, tls: skip }
    binaries:
      - { path: /sandbox/.hermes/hermes-agent/venv/bin/python }
      - { path: /usr/bin/curl }
```

```bash
nemoclaw v2-researcher policy-add --from-file policies/web-research.yaml --yes
```

Rules that trip everyone:

- **Never `openshell policy set`.** It replaces the whole policy and drops the
  inference and peer rules. Only add.
- **Presets need `preset.name` and no top-level `version`.** The template that
  `swarm` renders for sandbox creation has `version: 3`; presets do not.
- **Policies bind to binaries as well as hosts.** Allowing `github.com` is not
  enough if the program making the call is not in `binaries`. `curl` gets 200
  while `python` gets 403 until you list it.
- **Redirects are separate decisions.** `curl -L https://astral.sh` fails even
  with `astral.sh` allowed, because it redirects to `releases.astral.sh`.
- **The file must end in `.yaml`.**

The status codes inside a sandbox tell you what happened: 403 is policy, 502 is
allowed-but-nothing-listening (usually a host loopback service), 000 with
`CONNECT tunnel failed, response 403` on stderr is policy denying HTTPS.

## The model

All bots share one endpoint and model from `swarm.env`:

```bash
INFERENCE_BASE_URL=https://your-endpoint/v1
INFERENCE_MODEL=your/model-id
INFERENCE_CONTEXT_LENGTH=131072
INFERENCE_MAX_TOKENS=8192
```

The key lives in `INFERENCE_KEY_FILE` (default `~/.secrets/inference.key`, mode
600). `swarm` copies it into each sandbox's `.env` as `INFERENCE_API_KEY`; it
never appears in a policy, a log, or the repo.

Any OpenAI-compatible server works: a hosted API, NVIDIA NIM, vLLM, SGLang. The
example was verified against a hosted Nemotron 3 Super endpoint. Two things to
check when switching: the model must handle tool calls well (a bot is nothing but
tool calls), and `INFERENCE_CONTEXT_LENGTH` must not exceed what the server
serves or the first long turn gets a 400.

To give one bot a different model, edit `/sandbox/.hermes/config.yaml` in its
sandbox (`model.default`, `model.base_url`) and restart its gateway with
`./swarm up`. There is deliberately no per-bot model setting in `swarm.env`; a
fleet on one model is easier to reason about.

## More bots

```bash
./swarm add analyst --soul souls/critic.md
./swarm add qa --soul souls/qa.md
```

Each `add` is 3 to 4 minutes and fully meshes the new bot with every existing
one. There is no model load: bots share the endpoint. Sandbox memory and CPU are
`SANDBOX_MEMORY` and `SANDBOX_CPU` in `swarm.env`.

To make new bots part of the default fleet that `./swarm up` creates on a clean
host, add them to `BOTS` and drop a `souls/<name>.md` in place.

## Hermes inside the sandbox

Hermes is baked into the image at `HERMES_REF` (a git tag). To move the fleet
to a new release: change `HERMES_REF`, `./swarm down --yes`, `./swarm up`. Do
not `hermes update` inside a sandbox; the image is the source of truth and a
mixed fleet is hard to debug.

Skills and plugins for a bot go in `/sandbox/.hermes/skills/` and
`/sandbox/.hermes/plugins/` inside its sandbox. The `teammates` plugin is the
only one `swarm` installs.
