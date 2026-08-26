# Troubleshooting

Organised by symptom. Every entry here is a failure that actually happened, with
the real error text.

## Start here: is an agent really down?

Most "agent X is down" reports are not agent problems. Work through these four in
order and stop at the first failure. Doing this out of order wastes the most time.

**1. Is the desktop app running?** On the client machine:

```bash
pgrep -f "Hermes.app/Contents/MacOS/Hermes" >/dev/null && echo RUNNING || echo DOWN
```

If it says DOWN, nothing on the host matters. Relaunch it and stop here. Several
agents "erroring" at once with no error detail is nearly always the client having
exited.

**2. Does the agent answer a direct CLI turn?**

```bash
hermes -p <agent> chat -q "Reply with exactly OK"
```

A reply means the agent is healthy and the fault is in the desktop layer. Go to
step 4.

**3. Is the inference engine busy?**

```bash
curl -s localhost:<engine-port>/metrics | grep num_requests_running
nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader
```

`1.0` and non-zero GPU means the agent is thinking. Wait. Do not restart anything.
A deep research turn legitimately runs for minutes with no visible progress.

**4. Only now inspect backend locks.** See "a bot receives nothing in group chat"
below.

Restarting the desktop app is a cheap and correct first move for any room-level
symptom. It fixes an exited client, stale backends after a gateway restart, and
reverted routing.

**Every in-sandbox gateway restart invalidates the desktop's backends.** If you
restart gateways, relaunch the app afterwards, and never batch gateway restarts
right before a demo.

## A bot receives nothing in group chat

Hard to diagnose because every health check passes: the profile reports `running`,
the api_server returns 200, and a direct CLI turn works.

### First, rule out correct behaviour

The room prompt tells agents to reply only when they have something new:

> If you have nothing new to add, reply with exactly `(pass)`. Passing is good.
> Do not repeat points already made.

So on a greeting, whoever answers first satisfies it and the rest pass correctly.
Read what the agent actually said:

```python
import sqlite3
c = sqlite3.connect("<HERMES_HOME>/profiles/<agent>/state.db")
for r in reversed(list(c.execute(
        "select role, substr(content,1,200) from messages order by rowid desc limit 6"))):
    print(r[0], "|", " ".join((r[1] or "").split())[:180])
```

A stored `(pass)` means it worked as designed. Ask something with distinct angles
per agent instead.

### Then check whether the message arrived at all

Search the agent's message store for a phrase unique to your prompt:

```python
hits = list(c.execute("select rowid from messages where content like '%<your phrase>%'"))
print(len(hits))   # 0 means it never received the message
```

Observed: three agents had the task and acknowledged it; the fourth returned zero
matches and was still asking what to research, one message behind permanently.

### Cause: an orphaned desktop backend

The desktop keeps one backend process per profile in
`~/.hermes/desktop-ssh/<hash>/backend.lock.json`. On relaunch it can latch onto a
process that survived from a previous session. That backend looks alive but is not
wired to the current room, so the profile gets no turns.

The tell is uptime skew, not health:

| profile | backend uptime |
|---|---|
| alpha | 10m |
| gamma | 9m |
| delta | 8m |
| beta | **1h 23m** — orphan |

```bash
./scripts/fix-desktop-backends.sh
```

Then restart the desktop app. Healthy looks like tightly clustered uptimes.

A lock whose PID no longer exists also blocks respawn entirely, so the bot never
appears at all. The same script clears those.

### Chained tasks amplify it

`@b research, @c consolidate, @a brief` deadlocks when `@b` is the silent one.
Everyone else correctly waits, all acknowledge their roles, and no work happens. If
a chain stalls, check whether the **first** agent received anything before
debugging the rest.

### Nothing schedules follow-up work

A room turn is one request and one response. An agent that replies "on it, I'll
report back" then does nothing and passes on every later round. It looks busy and
is idle. Ask for the result in the same turn: "give me the findings in this
message, do not defer."

## An agent is missing from the desktop roster

Works from the CLI, api_server returns 200, `message_teammate` works both ways, but
it is not in the roster and `hermes profile list` says `stopped`.

There are two gateways per agent:

| gateway | where | what it does |
|---|---|---|
| in-sandbox | inside `bot-<name>` | serves the api_server |
| host-side | on the host | makes the profile report `running`; the roster lists only these |

```bash
ls ~/.hermes/profiles/<name>/ | grep gateway
# healthy: gateway.pid gateway.lock gateway.sock gateway_state.json
# broken:  nothing
```

Start it with a login shell and `setsid`, or it dies with your SSH session:

```bash
ssh yourhost 'bash -lc "
  export PATH=\$HOME/.local/bin:\$PATH
  setsid hermes -p <name> gateway run > \$HOME/gw-<name>.log 2>&1 < /dev/null &
"'
```

Two warnings in that log are normal: "No env user allowlists configured" and "No
messaging platforms enabled."

`gateway_running` is computed from an active `gateway.lock` plus a `gateway.pid`
whose recorded start time matches the live process. So `kill -0 $(cat gateway.pid)`
is not sufficient; ask `hermes profile list`.

## The desktop shows no agents at all

The app reads its connection config only at launch, and rewrites it on exit.

```bash
python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/Hermes/connections.json');print(json.load(open(p))['lastUsed'])"
```

If that is not your remote connection id, the app is talking to your laptop, where
these profiles do not exist. Fix the file, then restart. Restarting first re-saves
the old value.

`lastUsed` controls routing, not `primary`.

## Nothing responds after a reboot

```bash
./scripts/start-swarm.sh
```

Idempotent. Restores relays, in-sandbox gateways, port forwards, and host gateways
for every agent it discovers, then health-checks them.

## A request from inside a sandbox is blocked

The status code tells you which layer refused.

| code | meaning | fix |
|---|---|---|
| 403 | policy denied it | host not in the policy, or the calling binary is not in `binaries` |
| 502 | policy allowed it, nothing listening | usually a service bound to `127.0.0.1` on the host; use the relay |
| 401 | you reached the target | credential wrong or missing |
| 000 | no route | wrong address for the boundary you are crossing |
| 200 | working | |

### The binary-path trap

`network_policies` bind to binary paths as well as hosts. Allowlisting a host is
not enough. With `pypi.org` allowed:

```console
$ curl https://pypi.org/simple/pillow/     # 200 — curl was in `binaries`
$ uv pip install pillow                    # 403 — uv was not
```

List every program that makes network calls: `curl`, `python`, `uv`, `node`, `npm`,
`git`.

### Redirects are separate decisions

`curl -L https://astral.sh/uv/install.sh` fails even with `astral.sh` allowed,
because the 301 target `releases.astral.sh` is evaluated independently. Allowlist
both.

## Sandbox creation fails

| Error | Cause |
|---|---|
| `sandbox user 'sandbox' not found in image` | the image needs a user **and** group literally named `sandbox` |
| `ContainerRestarting: Container is restarting after a failure` | your image's entrypoint exits. Use `CMD ["sleep","infinity"]` |
| `failed to parse sandbox policy YAML: missing field 'version'` | add `version: 3` at the top level |

Sandbox creation takes 2+ minutes. A tool timeout is not a failure; check
`openshell sandbox list` before retrying.

Also: `openshell sandbox create` can block long after the sandbox is already Ready.
Wrap it in `timeout 180` and let a readiness poll be the real gate.

## Cannot write inside the sandbox despite correct ownership

`/home/sandbox` is not writable under Landlock even when `ls -ld` shows it owned by
the sandbox user. Use `HOME=/sandbox` and `HERMES_HOME=/sandbox/.hermes`.
`Dockerfile.sandbox` already does this.

## The Hermes install inside a sandbox hangs

First get the real error:

```bash
openshell sandbox exec -n bot-<name> -- /bin/sh -c 'tail -5 /sandbox/install.log'
```

The common one on a busy host:

```
remote: This request was rate-limited due to too many requests.
fatal: unable to access 'https://github.com/NousResearch/hermes-agent.git/':
       The requested URL returned error: 429
```

Sandbox egress goes through the OpenShell proxy, so every sandbox shares one
apparent source address. Installing into several in quick succession trips
GitHub's unauthenticated rate limit, while a host-side `git clone` still works.

`spawn-agent.sh` handles this by seeding Hermes from an already-built sandbox with
`docker cp` instead of cloning. If you hit it manually: wait, space out spawns, or
bake Hermes into the sandbox image.

If `/sandbox/install.log` does not exist at all, no `sandbox exec` process is
running for that sandbox, and the spawn script is still alive, that is a separate
output-buffering stall. Run the installer directly, then re-run the spawn.

Do not run your own `sandbox exec` against a sandbox while a spawn is mid-install.
Concurrent execs return empty output and look exactly like a dead sandbox.

## Installer fails at the uv, Python, or Node step

The sandbox image must ship these, because the egress proxy blocks the mirrors
that would otherwise provide them at install time:

- `python3.11`, or uv downloads a standalone CPython from GitHub releases
- `xz-utils`, to extract the Node.js tarball
- `libatomic1`, or `node` fails with `libatomic.so.1: cannot open shared object file`
- `build-essential`, because `node-pty` compiles from source

A trailing `npm install failed` is cosmetic (browser tools only). Verify
independently:

```bash
openshell sandbox exec -n bot-<name> -- /bin/sh -c \
  '/sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main --version'
```

## Every model call returns 400

Hermes otherwise requests the entire context window as output tokens. Set both in
`.env`:

```
AGENT_MAX_TOKENS=8192
AGENT_CONTEXT_LENGTH=65536
```

Hermes also refuses a context window below 64K.

## `message_teammate` says "Unknown teammate"

Peers must be registered **inside the sandbox**, not only on the host profile. The
agent loop runs in the sandbox and reads that config. `spawn-agent.sh` does both;
a hand-wired agent is the usual case where this is missed.

Also check the port direction: agent A's `peer-B` policy group must allow **B's**
port, not A's own. Reversed, you get a 403 that reads like an auth failure.

## An agent claims it verified something it did not

Observed: an agent reported nine GitHub issues as open, citing them by number.
Four were closed. It had made zero tool calls that turn.

Agents will produce real-looking identifiers from training data when they cannot
reach a source. Two mitigations:

- A hard rule in the agent's role: never state an issue's state without a tool call
  that returned it in this session.
- Tracing. A turn asserting verification with no `tool.call` child spans is
  obvious at a glance. See [observability/README.md](../observability/README.md).

## An agent loops on a blocked tool and burns the whole turn

Observed: an agent tried to scrape GitHub issue state from HTML, failed, tried
`terminal` three times, and ended with `Operation interrupted` after six minutes.

Add to the agent's role file:

> If a source is unreachable, report what you have and name the blocker in one
> line. Do not attempt a second or third workaround. Three failed attempts with
> the same tool means the path is closed.

That single instruction turned a six-minute failure into a 57-second answer with
ten cited sources.

## An engine or agent looks hung

`docker ps` showing `Up` proves nothing, and high CPU does not mean progress:
collective operations busy-wait, so a deadlock also burns ~100% per rank.

```bash
docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}}' <container>
docker exec <container> sh -c 'ps -eLo stat,pcpu,comm | sort -k2 -rn | head -5'
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
```

- **Deadlocked**: every thread `RLl` at ~99%, empty `/proc/<pid>/wchan`,
  `read_bytes: 0`, memory flat for 5+ minutes.
- **Working**: varying CPU, growing `read_bytes`, climbing memory.

Trust the combination, never one signal alone.

## Two traps in your own diagnostics

**`gateway.pid` holds JSON, not a bare PID.** `ps -p $(cat gateway.pid)` reports
every gateway dead. The file is `{"pid":…,"kind":…,"start_time":…}`, and
`start_time` is a PID-reuse guard.

**Nested shell quoting mangles API keys** and produces 401s from endpoints that are
fine. Read keys from files inside a script rather than interpolating them through
several layers of `ssh '… "… \"…\" …" …'`. This produced a 401 from a port that had
been working all day.

## Operating on a shared machine

- Never background a remote command whose first line is destructive. A
  `sandbox delete` can fire minutes later, after you rebuilt the thing it deletes.
- Killing a local SSH client does not kill the remote command. Check with
  `pgrep -fa` and kill by exact PID.
- Never `pkill -f <pattern>` over SSH when the pattern could match your own command
  string. It will kill your session. `pkill -f zztest` does exactly this.
- Never `docker rm` with a broad filter or `ancestor=`. It takes out unrelated
  containers, including other people's work.
- Never bind a test service to a port a working service already owns. The victim
  exits on its next restart with no obvious connection to what you changed.
