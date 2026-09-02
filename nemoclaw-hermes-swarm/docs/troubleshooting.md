# Troubleshooting

By symptom. Every entry is a failure that happened while building this example.

## Start here: is a bot really down?

Most "bot X is down" reports are not bot problems. In this order; stop at the
first failure.

**1. Is the Desktop app running?** On your laptop:

```bash
pgrep -f "Hermes.app/Contents/MacOS/Hermes" >/dev/null && echo RUNNING || echo DOWN
```

DOWN means nothing on the host matters. Relaunch and stop here. Several bots
erroring at once with no error text is nearly always the client having exited.

**2. Does the bot answer a direct turn?** On the host:

```bash
hermes -p researcher chat -q "Reply with exactly OK"
```

A reply means the bot is healthy and the fault is Desktop-side. Skip to step 5.

**3. Is the model endpoint up?**

```bash
./swarm doctor      # auth 200? model listed?
```

Since Hermes 0.21 a dead endpoint shows in Desktop as `[reason: model_unavailable]`
instead of a bare error. A bot whose endpoint is down is not a broken bot.

**4. `./swarm status`.** Each rung is a real probe: sandbox Ready, api_server
200, a chat turn through the sandbox, relay active, host profile running.

**5. Restart the Desktop app.** Cheap and correct for any room-level symptom: an
exited client, stale backends after a gateway restart, reverted routing. Every
in-sandbox gateway restart invalidates the Desktop's backend, so after
`./swarm up` on a rebooted host, restart the app too. Never restart gateways
right before a demo.

## A bot receives nothing in a group chat

Every health check passes and it still says nothing.

**First, rule out correct behaviour.** The room prompt tells bots to reply only
with something new; `(pass)` is a valid answer. Read what it actually said:

```bash
openshell sandbox exec -n v2-researcher -- /sandbox/.hermes/hermes-agent/venv/bin/python - <<'PY'
import sqlite3
c = sqlite3.connect("/sandbox/.hermes/state.db")
for role, text in reversed(list(c.execute("select role, substr(content,1,200) from messages order by rowid desc limit 6"))):
    print(role, "|", " ".join((text or "").split())[:180])
PY
```

**Then check whether the message arrived.** Search the same table for a phrase
unique to your prompt. Zero hits means the bot never got it; the fault is
upstream of the bot.

**Cause, usually: an orphaned Desktop backend.** The Desktop keeps one backend
process per profile under `~/.hermes/desktop-ssh/<hash>/backend.lock.json` on
the host. On relaunch it can latch onto one that survived a previous session,
which looks alive but is not wired to the current room. The tell is uptime skew:
three backends at 10 minutes, one at 1h23m. Kill the old one, remove its lock
directory, restart the app.

**Chained tasks amplify it.** `@b research, @c consolidate, @a brief` deadlocks
when `@b` is the silent one; everyone else correctly waits. Check the first bot
in the chain before debugging the rest.

**Nothing schedules follow-up work.** A room turn is one request, one response. A
bot that says "on it, I'll report back" then does nothing. Ask for the result in
the same message; see the soul guidance in [customizing.md](customizing.md).

## A bot is missing from the roster

Works from the CLI, api_server returns 200, `hermes profile list` says `stopped`.

Two gateways per bot: one inside the sandbox serving the api_server, one on the
host that makes the profile report `running`. The roster lists only the second.
`./swarm up` starts it; `./swarm status` checks it. `hermes profile list`
computes `running` from `gateway.lock` plus a `gateway.pid` whose recorded start
time matches the live process, so `kill -0 $(cat gateway.pid)` is not enough,
and `gateway.pid` is JSON, not a bare PID.

## Desktop shows no bots at all

The app reads its connection config at launch and rewrites it on exit. If the
Bots pane is empty, the app is probably talking to your laptop's local runtime
instead of the host. Settings, Connections: make sure the SSH connection exists
and is selected, then restart the app.

## Nothing responds after a reboot

```bash
./swarm up
```

Sandboxes and profiles survive a reboot; processes do not. `up` restores every
bot in `BOTS`, re-applies tracing, re-checks the mesh, and prints status. It does
not start your inference endpoint.

## A request from inside a sandbox is blocked

| Code | Meaning | Fix |
|---|---|---|
| 403 | policy denied it | host not allowed, or the calling binary is not in `binaries` |
| 000 + `CONNECT tunnel failed, response 403` on stderr | policy denied an HTTPS request | same |
| 502 | allowed, nothing listening | a service on host `127.0.0.1`; sandboxes have their own netns, use the bridge |
| 401 | reached the target | credential wrong or stale |
| 200 | working | |

Policies bind to binaries as well as hosts. With `pypi.org` allowed, `curl` gets
200 and `uv` gets 403 until `uv` is listed. Redirects are separate decisions:
allow both `astral.sh` and `releases.astral.sh`.

## `policy-add` rejects the file

```
Preset must declare preset.name (lowercase, hyphenated RFC 1123 label)
```

Files given to `nemoclaw <sandbox> policy-add` are presets: top-level
`preset: {name, description}`, no `version:`, filename ending in `.yaml`.
`policies/otlp-export.yaml` is the reference shape. The `version: 3` document is
only for the initial policy at sandbox creation.

## Sandbox creation fails

| Error | Cause |
|---|---|
| `sandbox user 'sandbox' not found in image` | image needs a user and group literally named `sandbox` |
| `ContainerRestarting` | image entrypoint exits; use `CMD ["sleep","infinity"]` |
| `missing field 'version'` | the creation policy needs `version: 3` |

Creation takes about 2 minutes. `openshell sandbox create` can block after the
sandbox is already Ready; `swarm` bounds it and polls `sandbox list` instead.

## Hermes inside a sandbox is the wrong version or missing

Hermes is baked into the image at `HERMES_REF`. If a sandbox reports a different
version, it was created from an older image: `./swarm rm <bot> --yes`, then
`./swarm add`. Do not `hermes update` inside a sandbox; egress to GitHub is not
allowed and the image is the source of truth.

## `message_teammate` says "Unknown teammate"

Peers must be registered inside the sandbox, because the agent loop runs there
and reads that config. `./swarm add` does this for every pair in both
directions. Check `./swarm ls`; the `peers` column is read from inside each
sandbox. Also check port direction: A's `peer-B` preset must allow B's port, not
A's own. Reversed, you get a 403 that reads like an auth failure.

## Relay says "not active" but the collector receives spans

The activation line is written at INFO to `/sandbox/.hermes/logs/agent.log`
inside the sandbox, not to `gateway.log` and not to the stderr captured on the
host. `./swarm traces <bot>` reads the right file. Trust the collector's counters
over any log grep.

## The same test prompt returns instantly and no new session appears

The api_server dedupes identical requests through its response store. Use a
unique token per probe. `./swarm test` does.

## Every model call returns 400

Hermes asks for the whole context window as output tokens unless told otherwise.
`swarm.env` sets `INFERENCE_MAX_TOKENS` and `INFERENCE_CONTEXT_LENGTH`; make sure
the second does not exceed what your server serves.

## A bot claims it verified something it did not

Observed: nine GitHub issues reported open by number, four were closed, zero tool
calls that turn. Bots produce real-looking identifiers from training data when
they cannot reach a source. Two mitigations: a hard rule in the soul (never state
a fact a tool did not return this session), and tracing, where a turn asserting
verification with no tool spans is obvious at a glance.

## A bot loops on a blocked tool and burns the whole turn

Observed: HTML scrape fails, `terminal` tried three times, `Operation interrupted`
after six minutes. One paragraph in the soul fixed it: report what you have, name
the blocker, stop after three failures with the same tool. That turned the
six-minute failure into a 57-second answer with ten sources.

## `swarm rm` printed nothing and removed nothing

It asked for confirmation on a closed stdin. Pass `--yes` when scripting or
running over SSH.

## Traps in your own diagnostics

- **`gateway.pid` holds JSON.** `ps -p $(cat gateway.pid)` reports every gateway
  dead. Ask `hermes profile list`.
- **Nested shell quoting mangles keys.** Read them from files inside a script,
  never interpolate through `ssh '… "… \"…\" …" …'`. Same for `python -c`
  through `sandbox exec`; feed python a heredoc on stdin.
- **`pkill -f <pattern>` over SSH can match your own session.** A pattern
  containing a sandbox name matches the ssh command that contains it. Kill by
  PID or by a substring the outer command cannot have.
- **`docker ps` showing `Up` proves nothing.** Probe the port.
- **Do not probe a sandbox while `swarm add` is mid-flight.** Concurrent execs
  return empty output and look exactly like a dead sandbox.

## On a shared host

- Never background a remote command whose first line is destructive.
- Never `docker rm` with a broad filter or `ancestor=`.
- Never bind a probe to a port a working service owns. The victim exits on its
  next restart with no obvious connection to what you changed.
- `swarm` only touches sandboxes with your `SANDBOX_PREFIX`, profiles named in
  its state directory, and its own collector. Other people's sandboxes on the
  same host are invisible to it.
