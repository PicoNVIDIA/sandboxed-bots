# Desktop group chat: diagnosing a silent agent

Every failure here was observed live. The pattern is always the same: some agents
respond, others say nothing, and **every health check passes** — which is what
makes it hard.

## First, rule out correct behaviour

An agent that stays silent is *usually right to*. The room prompt the desktop
sends contains:

> *"If you have nothing new to add, reply with exactly `(pass)`. **Passing is
> good** — it lets the conversation settle."*
> *"**Do not repeat points already made.**"*

So on `hi @a @b @c @d`, whoever answers first satisfies the greeting and the rest
correctly pass. Observed exactly that: gamma replied, beta and delta each stored
a literal `(pass)`.

**Check what the agent actually said before assuming it never ran:**

```python
import sqlite3
c = sqlite3.connect("~/.hermes/profiles/<name>/state.db")   # expand the path
for r in reversed(list(c.execute(
        "select role, substr(content,1,200) from messages order by rowid desc limit 6"))):
    print(r[0], "|", " ".join((r[1] or "").split())[:180])
```

- Stored `(pass)` → working as designed. Ask something with distinct angles.
- No turn at all → keep reading.

## Did the agent even receive the message?

The decisive query. Search its message store for a phrase unique to your prompt:

```python
hits = list(c.execute(
    "select rowid from messages where content like '%<distinctive phrase>%'"))
print(len(hits))   # 0 = it never got the message
```

Observed: three agents had the task and acknowledged it; the fourth returned
**`matches: 0`** and its last turn was still asking *"what do you need
researched?"* — stuck one message behind, permanently.

## Cause: an orphaned desktop backend

The desktop keeps one backend process per profile, recorded in
`~/.hermes/desktop-ssh/<hash>/backend.lock.json`. If the app relaunches and
latches onto a **surviving process from a previous session**, that profile keeps a
live-looking backend that is not wired to your current room. It receives nothing.

**The tell is backend UPTIME, not health.** Observed:

| profile | backend uptime |
|---|---|
| alpha | 10m |
| gamma | 9m |
| delta | 8m |
| **beta** | **1h 23m** ← orphan |

All four reported `running`, all four api_servers returned 200, all four answered
direct CLI turns. Only the uptime skew revealed it.

```bash
./scripts/fix-desktop-backends.sh    # detects orphans + dead locks, repairs both
```

Then **restart the desktop app**: any profile whose backend was stopped gets a
fresh one, the rest keep theirs. Healthy looks like tightly clustered uptimes
(e.g. all 170-192s).

## A dead lock also blocks respawn

A `backend.lock.json` whose pid no longer exists prevents the app from starting a
new backend for that profile — the bot never appears at all. The repair script
clears these; it is also what the e2e suite's *"no stale desktop backend locks"*
check catches.

## Nothing arrives for ANY agent

Then the app is talking to the wrong machine.

```bash
python3 -c "import json,os;p=os.path.expanduser('~/Library/Application Support/Hermes/connections.json');print(json.load(open(p))['lastUsed'])"
```

`lastUsed` controls routing — **not** `primary`. The app rewrites it on exit and
reads it only at launch, so it can silently revert to `local`, where your remote
profiles do not exist. Fix the file, **then** restart; restarting first re-saves
the old value.

## An agent promises work and goes quiet

A group-chat turn is one request/response. **Nothing schedules follow-up work.**
An agent that replies *"on it, I'll report back"* then does nothing, and passes on
every later round — indistinguishable from being busy.

Confirm it is idle rather than working:

```bash
nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader
curl -s localhost:<engine-port>/metrics | grep num_requests_running
```

All zeros means idle. Ask for the result **in** the turn: *"give me the findings in
this message — don't defer."*

## Chain tasks deadlock on the silent agent

A prompt like *"@b research, @c consolidate, @a brief, @d fixes"* leaves three
agents correctly waiting on the one that never received the instruction. The room
looks alive — everyone acknowledges their role — and no work happens.

If a chained task stalls, check whether the **first** agent in the chain received
anything before debugging the others.

## Full diagnostic ladder

Work outward; stop at the first failure.

| # | Check | Command |
|---|---|---|
| 1 | Agent answers at all | `hermes -p <n> chat -q 'Reply with OK'` |
| 2 | Profile reports running | `hermes profile list` |
| 3 | api_server on the bridge | `curl -H "Authorization: Bearer $(cat secrets/<n>.key)" http://<BRIDGE>:<port>/v1/models` |
| 4 | Backend alive and not an orphan | `./scripts/fix-desktop-backends.sh` |
| 5 | Backend port listening | `ss -lnt \| grep <port from lock file>` |
| 6 | Message actually delivered | query `state.db` for a phrase from your prompt |
| 7 | Desktop pointed at the right host | `lastUsed` in `connections.json` |

Steps 1-3 passing while the bot is silent in the room means the fault is in
4-7 — the desktop layer, not the agent.

## Two traps in your own diagnostics

- **`gateway.pid` holds JSON, not a bare pid.** `ps -p $(cat gateway.pid)` reports
  every gateway dead. Parse it: `{"pid":…,"kind":…,"start_time":…}` — the
  `start_time` is a PID-reuse guard.
- **Nested shell quoting mangles API keys**, producing 401s from endpoints that
  are fine. Read keys from files inside a script rather than interpolating them
  through several layers of `ssh '… "… \"…\" …" …'`.
