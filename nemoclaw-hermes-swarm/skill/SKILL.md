---
name: nemoclaw-hermes-swarm
description: "Use when deploying Hermes bots in NemoClaw sandboxes. Bring up, extend, verify, and debug a sandboxed bot swarm with ./swarm."
version: 2.0.0
author: nemoclaw-hermes-swarm example
license: Apache-2.0
platforms: [macos, linux]
metadata:
  hermes:
    tags: [openshell, nemoclaw, sandbox, multi-agent, hermes-bots, nemo-relay]
---

# Hermes bots in NemoClaw sandboxes

You are operating the `nemoclaw-hermes-swarm` example. It runs several Hermes
bots on one Linux host, each in its own OpenShell (NemoClaw) sandbox, with
NeMo Relay tracing into an OpenTelemetry collector. Everything goes through
one command, `./swarm`, in the example's root directory.

The host needs Docker, `openshell`, `nemoclaw`, and Hermes 0.21+. An
OpenAI-compatible inference endpoint must already exist; deploying a model is
out of scope. The Hermes Desktop app runs on the user's machine and reaches
the host over SSH.

## Two habits first

- **Never `openshell policy set`.** It replaces a sandbox's whole policy and
  silently drops its inference and teammate rules. Only ever add, and only
  through `./swarm` (which uses `nemoclaw <sandbox> policy-add`).
- **Login shell for every remote command.** `openshell`, `nemoclaw`, and
  `hermes` live in `~/.local/bin`, which non-login shells do not put on PATH.
  `ssh host 'openshell ...'` fails with `command not found`. Use
  `ssh host 'bash -lc "cd ~/nemoclaw-hermes-swarm && ./swarm status"'`.

## From nothing to a working swarm

```bash
cp swarm.env.example swarm.env      # INFERENCE_BASE_URL, INFERENCE_MODEL
umask 077; printf '%s' '<key>' > ~/.secrets/inference.key
./swarm up
```

`swarm up` runs preflight, builds the image with Hermes baked in, starts the
collector, creates every bot in `BOTS`, wires the mesh, and prints a status
table. First run is 8 to 12 minutes, dominated by the image build and two
sandbox creations. Re-running is idempotent and is also how you recover after
a reboot: existing bots are restored, missing ones are created.

Then have the user add the host in Hermes Desktop (Settings, Connections, Add
connection, SSH) and restart the app. The roster is read at launch.

## One bot at a time

```bash
./swarm add analyst --soul souls/researcher.md   # new bot, meshed to all others
./swarm add analyst --soul ./my-role.md
./swarm rm analyst --yes                          # sandbox, profile, key, peers
./swarm ls
./swarm status                                    # health ladder per bot
./swarm test                                      # 50-check e2e suite
./swarm traces analyst                            # relay state + collector counters
```

`add` takes 3 to 4 minutes, so give the terminal tool a timeout of at least
600 seconds. New bots share the inference endpoint; there is no model load. If
a tool call still times out mid-`add`, do not conclude failure: run
`./swarm ls` and `./swarm status` and read the result. Re-running `add` for the
same name is safe.

`./swarm` fixes its own environment (real `HOME` from the passwd database,
`HERMES_HOME`/`HERMES_PROFILE` cleared, `~/.local/bin` on `PATH`), so it works
from an agent's terminal tool, where `HOME` is rewritten to the profile's
private directory. Do not wrap it in `hermes -p`. If a bot creation ever stops
right after `api port NNNN` with exit 1 and no error, that is the symptom of an
older copy without this fix: the key file was looked up under the wrong home.

## Writing a role (SOUL)

The soul file is the bot's system prompt and matters more than any config.
Give it a method, not just an identity. Two paragraphs that fixed observed
failures:

```markdown
Deliver a usable answer in THE SAME MESSAGE. Never ask the user to scope the
task and never promise to report back later. Nothing re-prompts you.

If a source is unreachable, report what you have and name the blocker in one
line. Three failed attempts with the same tool means the path is closed.
```

Never let a bot claim a fact a tool did not return this session. Without a
reachable source, models produce plausible issue numbers and versions from
training data.

`swarm add` appends a short Runtime section (sandbox name, endpoint, egress
posture) and a Teammates section to whatever soul you give it.

## Diagnosing "a bot is down"

In this order. Stop at the first failure.

1. **Is the Desktop app running on the user's machine?**
   `pgrep -f "Hermes.app/Contents/MacOS/Hermes"`. Several bots erroring at once
   with no error text is nearly always the client having exited. Relaunch.
2. **Does the bot answer directly?** `hermes -p <bot> chat -q "Reply with OK"`
   on the host. A reply means the bot is fine and the fault is Desktop-side.
3. **Is the model endpoint up?** `./swarm doctor` checks auth and that the model
   is listed. Since 0.21 a dead endpoint surfaces in Desktop as
   `[reason: model_unavailable]` rather than a generic error.
4. **`./swarm status`.** Each rung is a real probe: sandbox phase, api_server
   200, a chat turn through the sandbox, relay active, host profile running.
5. **Restart the Desktop app.** Every in-sandbox gateway restart invalidates
   the Desktop's backend, so `swarm up` after a reboot means the user restarts
   the app too. Never restart gateways right before a demo.

## Failures that look like something else

- **Bot works over HTTP but is missing from the roster.** Two gateways per bot:
  one inside the sandbox (serves the api_server), one on the host (`hermes -p
  <bot> gateway run`) that makes the profile report `running`. The roster
  lists only the second. `swarm up` starts both; `swarm status` checks both.
- **`403` vs `502` vs `000` from inside a sandbox.** 403: policy denied it
  (host not allowed, *or the calling binary is not listed*; policies bind to
  both). 502: allowed, but nothing listening, usually a service on host
  loopback. 000 with `CONNECT tunnel failed, response 403` in stderr: HTTPS to
  an unlisted host, also a denial. `127.0.0.1` inside a sandbox is the sandbox;
  cross to the host with `host.openshell.internal`.
- **`policy-add` says `Preset must declare preset.name`.** Files given to
  policy-add are presets: top-level `preset: {name, description}`, no
  `version:`. `policies/otlp-export.yaml` is the reference shape.
- **Relay "not active" but spans arrive.** The activation line is logged at
  INFO to `/sandbox/.hermes/logs/agent.log` inside the sandbox, not
  `gateway.log` and not the stderr captured on the host. Trust the collector
  counters (`./swarm traces <bot>`); they are the only delivery signal.
- **A repeated identical prompt returns instantly and no new session appears.**
  The api_server dedupes identical requests through its response store. Use a
  unique token when probing.
- **`swarm rm` printed nothing.** It asked for confirmation on a stdin that was
  closed. Pass `--yes` when scripting.
- **Removed bots reappear as `stopped` profiles a minute later.** The Desktop's
  host backend (`hermes serve --isolated`) cached the profile list at start and
  its cron ticker recreates `<profile>/cron/` every 60 s. Kill that process,
  remove its `~/.hermes/desktop-ssh/<hash>/`, delete the ghosts, and have the
  user restart Desktop.
- **A bot replies `(pass)`.** Correct. The room prompt says reply only with
  something new.
- **A chained task stalls.** `@b research, @c summarise, @a brief` deadlocks
  when `@b` never got the message. Check whether the *first* bot in the chain
  received anything.

## Traps in your own diagnostics

- **`gateway.pid` holds JSON**, not a bare PID. Ask `hermes profile list`.
- **Nested shell quoting mangles keys** and yields 401s from healthy endpoints.
  Read keys from files inside a script; never interpolate them through
  `ssh '… "… \"…\" …" …'`. Same for `python -c` through `sandbox exec`: two
  shells eat the quotes. Use a heredoc on stdin.
- **`pkill -f <pattern>` over SSH can match your own session** and kill it.
  Patterns that include the sandbox name (`sandbox exec -n v2-x`) match the
  ssh command that contains them. Kill by PID or by a pattern the outer
  command cannot contain (`--timeout 0`).
- **`docker ps` showing `Up` proves nothing.** Probe the port.

## Before claiming success

Run `./swarm test` and quote the numbers. If something failed, name the check
and the error rather than reporting a clean run. Do not trust a bot's
self-description; it can recite its role while every tool is broken.

For a public change, `./swarm presubmit` gates secrets, internal hostnames,
SPDX headers, and shell syntax.

## Deeper reading

| Topic | File |
|---|---|
| How the pieces fit, network boundaries | `docs/architecture.md` |
| Symptoms and fixes | `docs/troubleshooting.md` |
| Roles, policies, models | `docs/customizing.md` |
| Tracing: Relay, collector, LangSmith | `docs/tracing.md` |
| What is and is not protected | `SECURITY.md` |
