# Troubleshooting

Every entry here is a failure that actually happened during development, with the
real error text. If you hit something not listed, the diagnostic ladder at the
bottom is usually enough to place it.

## The agent works but is missing from the desktop roster

**Symptom:** `hermes -p <name> chat` works, the api_server returns 200, agents can
message each other — but the agent is not in the Bots roster, and
`hermes profile list` shows it `stopped` while others show `running`.

**Cause:** there are **two** gateways per agent and it is easy to start only one.

| gateway | where | what it does |
|---|---|---|
| in-sandbox | inside `bot-<name>` | serves the api_server the host profile calls |
| **host-side** | on the host | makes the profile report `running` — the roster lists only these |

**Diagnose:**

```bash
ls ~/.hermes/profiles/<name>/ | grep gateway
# healthy: gateway.pid gateway.lock gateway.sock gateway_state.json
# broken:  (nothing)
```

**Fix** — must be a login shell plus `setsid`, or it dies with your SSH session:

```bash
ssh yourhost 'bash -lc "
  export PATH=\$HOME/.local/bin:\$PATH
  setsid hermes -p <name> gateway run > \$HOME/gw-<name>.log 2>&1 < /dev/null &
"'
```

Two warnings in that log are normal and harmless: *"No env user allowlists
configured"* and *"No messaging platforms enabled."*

`gateway_running` is computed from an **active `gateway.lock`** plus a
`gateway.pid` whose recorded start time matches the live process — a PID-reuse
guard. So `kill -0 $(cat gateway.pid)` is not a sufficient check; ask
`hermes profile list` instead.

## The desktop shows no agents at all

The desktop reads its connection config **only at app launch**, and rewrites it on
exit. Switching connections in the sidebar does not reload it.

```bash
# macOS
python3 -c "import json,os; p=os.path.expanduser('~/Library/Application Support/Hermes/connections.json'); print(json.load(open(p))['lastUsed'])"
```

If that is not your remote connection id, the app is talking to your laptop, where
these profiles do not exist. **Fix the file, then restart** — restarting first
re-saves the old value.

Note it is `lastUsed` that controls routing, not `primary`.

## Nothing responds after a reboot

```bash
./scripts/start-swarm.sh
```

Idempotent: restores relays, in-sandbox gateways, port forwards, and host
gateways for every agent it discovers, then health-checks them.

## A request from inside a sandbox is blocked

Read the status code — it tells you which layer refused.

| code | meaning | fix |
|---|---|---|
| **403** | Policy denied it | Host not in the policy, **or the calling binary is not in `binaries`** |
| **502** | Policy allowed it, nothing listening | Usually a service bound to `127.0.0.1` on the host — a sandbox cannot reach host loopback. Use the relay |
| **401** | You reached the target | Credential wrong or missing |
| **200** | Working | — |

### The binary-path trap

`network_policies` bind to **binary paths as well as hosts**. Allowlisting a host
is not enough. Real example, with `pypi.org` allowed:

```console
$ curl https://pypi.org/simple/pillow/     # 200 — curl was in `binaries`
$ uv pip install pillow                    # 403 — uv was not
```

Every program that makes network calls must be listed: `curl`, `python`, `uv`,
`node`, `npm`, `git`.

### Redirects are separate decisions

`curl -L https://astral.sh/uv/install.sh` fails even with `astral.sh` allowed,
because the 301 target `releases.astral.sh` is evaluated independently. Allowlist
both, or fetch the final URL directly.

## Sandbox creation fails

| Error | Cause |
|---|---|
| `sandbox user 'sandbox' not found in image` | The image needs a user **and** group literally named `sandbox` |
| `ContainerRestarting: Container is restarting after a failure` | Your image's entrypoint exits. Use `CMD ["sleep","infinity"]` — OpenShell injects its own entrypoint |
| `failed to parse sandbox policy YAML: missing field 'version'` | Add `version: 3` at the top level |

Sandbox creation can take 2+ minutes. A tool timeout is not a failure — check
`openshell sandbox list` before retrying.

## Cannot write inside the sandbox despite correct ownership

`/home/sandbox` is not writable under Landlock even when `ls -ld` shows it owned
by the sandbox user. Use `HOME=/sandbox` and `HERMES_HOME=/sandbox/.hermes`. The
provided `Dockerfile.sandbox` already does.

## The Hermes install inside a sandbox hangs

**Symptom:** the spawn stalls, `/sandbox/.hermes` is empty, there is no
`/sandbox/install.log`, no `sandbox exec` process for that sandbox, yet the spawn
script is still alive.

Reproducible, not a one-off. **Recover:**

```bash
# 1. install directly — this reliably works
openshell sandbox exec -n bot-<name> --timeout 1650 -- /bin/sh -c '
  export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
  cd /sandbox
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash > /sandbox/install.log 2>&1
  test -x /sandbox/.hermes/hermes-agent/venv/bin/python && echo INSTALL-OK'

# 2. kill the stuck spawn, then re-run it — it detects the install and continues
./scripts/spawn-agent.sh --name <name> --role "..."
```

**Do not** run your own `sandbox exec` against a sandbox while a spawn is
mid-install. Concurrent execs return empty output and look exactly like a dead
sandbox. Confirm liveness with a trivial `echo ALIVE` first.

## Installer fails at the uv, Python, or Node step

The sandbox image must ship these; the egress proxy blocks the mirrors that would
otherwise provide them at install time:

- `python3.11` — otherwise uv downloads a standalone CPython from GitHub releases
- `xz-utils` — to extract the Node.js tarball
- `libatomic1` — otherwise `node` fails with `libatomic.so.1: cannot open shared object file`
- `build-essential` — `node-pty` compiles from source

A trailing `npm install failed` is cosmetic (browser tools only). Verify
independently:

```bash
openshell sandbox exec -n bot-<name> -- /bin/sh -c \
  '/sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main --version'
```

## Every model call returns 400

Hermes otherwise requests the entire context window as **output** tokens. Set
both in `.env`:

```
AGENT_MAX_TOKENS=8192
AGENT_CONTEXT_LENGTH=65536
```

Hermes also refuses a context window below 64K.

## `message_teammate` says "Unknown teammate"

Peers must be registered **inside the sandbox**, not only on the host profile. The
agent loop runs in the sandbox and reads that config. `spawn-agent.sh` does both;
if you wired an agent by hand, that is the usual omission.

Also check the port direction: agent A's `peer-B` policy group must allow **B's**
port, not A's own. Reversed, you get a 403 that reads like an auth failure.

## A bot stays silent in a group chat

Usually correct. Room rules say reply only with something new to add, so a `(pass)`
on a greeting is intended behaviour.

But a bot that promised future work ("I'll write that up and post it here") will
pass on **every** later round and look broken. Inspect its room session before
suspecting infrastructure.

## An engine or agent looks hung

`docker ps` showing `Up` proves nothing, and **high CPU does not mean progress** —
collective operations busy-wait, so a deadlock burns ~100% per rank too.

```bash
docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}}' <container>
docker exec <container> sh -c 'ps -eLo stat,pcpu,comm | sort -k2 -rn | head -5'
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader   # if applicable
```

- **Deadlocked:** every thread `RLl` at ~99%, empty `/proc/<pid>/wchan`,
  `read_bytes: 0`, memory flat for 5+ minutes.
- **Working:** varying CPU, growing `read_bytes`, climbing memory.

The trustworthy signal is the combination, never one alone.

## Diagnostic ladder

When something is unclear, work outward from the agent:

1. **Is the model reachable from inside the sandbox?**
   `openshell sandbox exec -n bot-<name> -- /bin/sh -c 'curl -s -o /dev/null -w "%{http_code}" <INFERENCE_URL>/models'`
2. **Does the agent answer at all?** `hermes -p <name> chat -q 'Reply with OK'`
3. **Is its api_server on the bridge?** `curl -H "Authorization: Bearer $(cat secrets/<name>.key)" http://<BRIDGE>:<port>/v1/models`
4. **Does the profile report running?** `hermes profile list`
5. **Full sweep:** `./scripts/e2e-test.sh`

## Operating on a shared machine

- Never background a remote command whose first line is destructive — a
  `sandbox delete` can fire minutes later, after you rebuilt the thing it deletes.
- Killing a local SSH client does **not** kill the remote command. Check with
  `pgrep -fa` and kill by exact PID.
- Never `pkill -f <pattern>` over SSH when the pattern could match your own
  command string — it will kill your session. This genuinely happens with names
  like `pkill -f zztest`.
- Never `docker rm` with a broad filter or `ancestor=`; it takes out unrelated
  containers, including other people's work.
- Never bind a test service to a port a working service already owns. The victim
  exits on its next restart, with no obvious connection to what you changed.
