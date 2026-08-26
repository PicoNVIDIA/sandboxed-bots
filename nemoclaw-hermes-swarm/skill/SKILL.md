---
name: hermes-swarm-setup
description: "Use when running sandboxed Hermes agents. Spawn, debug, verify a multi-agent swarm."
version: 1.0.0
author: nemoclaw-hermes-swarm example
license: Apache-2.0
platforms: [macos, linux]
metadata:
  hermes:
    tags: [openshell, nemoclaw, sandbox, multi-agent, hermes-swarm]
---

# Sandboxed Hermes Swarm

Set up, extend, and debug several Hermes agents on one Linux host, each in its own
OpenShell sandbox. Use this when the user wants multiple isolated agents that can
message each other, or when an existing swarm misbehaves.

Assumes this repository is checked out and an OpenAI-compatible inference endpoint
already exists. Deploying an inference server is out of scope.

The agents run on a Linux host with Docker and OpenShell. You can drive that host
from anywhere, including macOS over SSH, so wrap remote commands in a login shell:
`ssh <host> 'bash -lc "..."'`.

## Before touching anything

Two habits that prevent most of the damage:

- **Never `openshell policy set`.** It replaces a sandbox's entire policy and will
  silently remove its inference and peer rules. Always `nemoclaw <sandbox>
  policy-add --from-file <file> --yes`.
- **Use a login shell for every remote command.** `openshell`, `nemoclaw`, and
  `hermes` live in `~/.local/bin`, added by `~/.profile`, which non-login shells do
  not read. `ssh host 'openshell --version'` fails with `command not found`. Use
  `ssh host 'bash -lc "..."'`.

## Setting up from scratch

Run in order. Each step validates the previous one.

```bash
cp .env.example .env         # set INFERENCE_URL and INFERENCE_MODEL
./scripts/00-preflight.sh    # fails loudly with the fix if anything is missing
./scripts/01-build-image.sh
./scripts/02-bootstrap-two-agents.sh
./scripts/e2e-test.sh
```

Then tell the user to restart the Hermes desktop app. The profile list is read at
launch, so agents do not appear until it restarts.

Step 3 takes 10-20 minutes, mostly installing Hermes inside each sandbox. A tool
timeout is not a failure. Poll `openshell sandbox list` before concluding anything.

## Adding one agent

```bash
./scripts/spawn-agent.sh --name <name> --role "<one paragraph>"
./scripts/spawn-agent.sh --name <name> --role-file ./souls/reviewer.md
./scripts/spawn-agent.sh --list
./scripts/spawn-agent.sh --name <name> --destroy
```

Idempotent: re-running for an existing agent repairs it rather than duplicating.
New agents share the existing inference endpoint, so no GPU cost and no model load.

## Writing a good role

The role file is the agent's system prompt and matters more than any config. Give
it a method, not just an identity, and write the rules that stop the failures you
care about. Two that are always worth including:

```markdown
Deliver a usable answer in THE SAME MESSAGE. Never ask the user to scope the task
and never promise to report back later. Nothing re-prompts you, so a deferral is a
dead end for whoever is waiting.

If a source is unreachable, report what you have and name the blocker in one line.
Do not attempt a second or third workaround. Three failed attempts with the same
tool means the path is closed.
```

Those two paragraphs turned an observed six-minute `Operation interrupted` failure
into a 57-second answer with ten cited sources.

Never claim a fact a tool did not return this session. Agents will produce
plausible identifiers (issue numbers, versions, states) from training data when
they cannot reach a source. One observed case reported nine GitHub issues as open
with zero tool calls; four were closed.

See `docs/customizing-agents.md`.

## Diagnosing "an agent is down"

Work through these in order and stop at the first failure. Out of order is what
wastes hours.

**1. Is the user's desktop app running?** On their machine:

```bash
pgrep -f "Hermes.app/Contents/MacOS/Hermes" >/dev/null && echo RUNNING || echo DOWN
```

If DOWN, nothing on the host matters. Have them relaunch and stop. Several agents
erroring at once with no error text is nearly always the client having exited.

**2. Does the agent answer directly?**

```bash
hermes -p <agent> chat -q "Reply with exactly OK"
```

A reply means the agent is fine and the fault is desktop-side. Skip to step 4.

**3. Is the engine busy?**

```bash
curl -s localhost:<engine-port>/metrics | grep num_requests_running
nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader
```

`1.0` plus non-zero GPU means it is thinking. Wait. Do not restart. A research turn
legitimately runs for minutes with no visible progress.

**4. Only now check backend locks.**

```bash
./scripts/fix-desktop-backends.sh
```

Restarting the desktop app is a cheap, correct first move for any room-level
symptom. **Every in-sandbox gateway restart invalidates the desktop's backends**,
so if you restart gateways, tell the user to relaunch the app afterwards. Never
batch gateway restarts before a demo.

## Failures that look like something else

**Agent works over HTTP but is absent from the roster.** There are two gateways per
agent: one in the sandbox serving the api_server, one on the host that makes
`hermes profile list` report `running`. The roster lists only the second.

```bash
ls ~/.hermes/profiles/<agent>/ | grep gateway
# healthy: gateway.pid gateway.lock gateway.sock gateway_state.json
```

Start it with a login shell and `setsid`, or it dies with the SSH session.

**A bot replies `(pass)`.** Correct behaviour. The room prompt says reply only with
something new. Read the agent's stored message before assuming a fault.

**A chained task stalls.** `@b research, @c summarise, @a brief` deadlocks when
`@b` never received the message. Everyone else correctly waits. Check whether the
*first* agent in the chain got anything.

**Install hangs.** Get the real error first:

```bash
openshell sandbox exec -n bot-<name> -- /bin/sh -c 'tail -5 /sandbox/install.log'
```

Usually a GitHub 429: sandbox egress shares one apparent source via the OpenShell
proxy, so back-to-back installs trip the unauthenticated rate limit while a
host-side clone still works. `spawn-agent.sh` seeds from an existing sandbox with
`docker cp` to avoid it.

**Do not probe a sandbox while a spawn is mid-install.** Concurrent execs return
empty output and look exactly like a dead sandbox.

**403 vs 502.** 403 is policy denial (host not allowed, *or the calling binary is
not listed* — policies bind to both). 502 means policy allowed it but nothing is
listening, usually a service bound to host loopback. Inside a sandbox `127.0.0.1`
is the sandbox; cross the boundary with `host.openshell.internal`.

## Verifying, properly

Do not trust an agent's self-description. It can recite its role while every tool
is broken.

```bash
./scripts/e2e-test.sh
```

Checks evidence: a unique marker per sandbox at the same path, a secret only a
teammate can read, a live host gateway per profile, and allowed-vs-denied status
codes.

## Traps in your own diagnostics

- **`gateway.pid` holds JSON, not a bare PID.** `ps -p $(cat gateway.pid)` reports
  every gateway dead. Parse it, or ask `hermes profile list`.
- **Nested shell quoting mangles API keys** and produces 401s from endpoints that
  are fine. Read keys from files inside a script rather than interpolating through
  `ssh '… "… \"…\" …" …'`. This produced a 401 from a port working all day.
- **`pkill -f <pattern>` over SSH can match your own command** and kill your
  session. Kill by exact PID.
- **`docker ps` showing `Up` proves nothing**, and high CPU does not mean progress:
  a deadlock busy-waits at ~100% too. Trust the combination of CPU, `read_bytes`,
  and memory trend.

## Before claiming success

Run the suite and quote the actual numbers. If something failed, say which check
and what the error was rather than reporting a clean run.

For a public change, `./scripts/presubmit-check.sh` gates credentials, internal
hostnames, SPDX headers, syntax, and file modes.

## Deeper reading

| Topic | File |
|---|---|
| How the pieces fit, network boundaries | `docs/architecture.md` |
| Symptom-organised failures | `docs/troubleshooting.md` |
| Roles, policies, models | `docs/customizing-agents.md` |
| Tracing agent runs to LangSmith | `observability/README.md` |
