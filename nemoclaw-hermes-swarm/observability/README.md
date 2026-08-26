# Tracing: NeMo Relay → LangSmith

Working setup for seeing what your agents actually did — per-turn spans with
inputs, outputs, token usage, and tool calls, filterable by agent.

NeMo Relay is **built into Hermes** (0.7.3 ships inside the sandbox already), so
there is no plugin to write and no code to maintain. This is configuration only.

## Why bother

Four real failures from this deployment, and the span that exposes each:

| symptom | what the trace shows |
|---|---|
| One agent silently receives no work while others reply | **no turn span** for that agent in the round |
| A chained task deadlocks | a turn span that closes with **zero tool-call children** |
| An agent claims it verified sources but invented them | a turn asserting verification with **no tool spans beneath it** |
| A bot says `(pass)` — broken, or correct? | a **completed** turn span, short output → working |

The third one is the strongest argument. It took an hour of manual checking to
catch by hand; as a trace it is one glance.

## Architecture

```
sandbox (bot-<agent>)                         host
┌──────────────────────────────┐  OTLP/HTTP   ┌─────────────────────┐
│ Hermes + nemo_relay          │─────────────►│ otel-collector :4319│──► LangSmith
│  relay-plugins.toml          │  bridge      │  key from host file │
└──────────────────────────────┘ 172.18.0.1   └─────────────────────┘
```

The collector is not optional decoration: it keeps the LangSmith API key **on the
host**. Sandboxes are agent-writable, so a credential inside one is exposed to the
agent.

## Setup

**1. Store the key host-side, mode 600.**

```bash
mkdir -p ~/.langsmith && umask 077
printf '%s' 'lsv2_pt_…' > ~/.langsmith/api_key
chmod 600 ~/.langsmith/api_key
```

**2. Run the collector.** Config in `otel-collector-config.yaml`.

```bash
docker run -d --name otel-collector --restart unless-stopped \
  -p 4319:4319 -p 127.0.0.1:8889:8888 \
  -e LANGSMITH_API_KEY="$(cat ~/.langsmith/api_key)" \
  -v ~/otel-collector/config.yaml:/etc/otelcol-contrib/config.yaml:ro \
  otel/opentelemetry-collector-contrib:latest \
  --config /etc/otelcol-contrib/config.yaml
```

**3. Allow the egress.** Deny-by-default, so add an **additive** policy — never
`openshell policy set`, which replaces the whole thing:

```bash
nemoclaw bot-<agent> policy-add --from-file otlp-policy.yaml --yes
```

**4. Configure each agent.** Copy `relay-plugins.toml.example` to
`/sandbox/.hermes/relay-plugins.toml`, substituting `AGENT_NAME`, then:

```bash
echo 'HERMES_NEMO_RELAY_PLUGINS_TOML=/sandbox/.hermes/relay-plugins.toml' \
  >> /sandbox/.hermes/.env
hermes config set telemetry.shared_metrics.enabled true
```

**5. Restart the in-sandbox gateway.** Non-negotiable — see below.

## Three things that will waste your afternoon

**Relay is already installed. `pip show` lies.** The sandbox venv has no `pip`, so
`pip show nemo-relay` reports "not installed" for a package that imports fine.
Always test with `python -c "import nemo_relay"`.

**Relay fails open.** A malformed `plugins.toml` logs a warning and runs with
tracing off — a perfectly healthy agent exporting nothing. Never assume it
activated; check the counters.

**The env var is read once, at process start.** Writing the TOML or exporting the
variable after the gateway is running does nothing. A module-level singleton
caches the decision for the process lifetime.

## The bug that makes runs render empty

**Symptom:** the LangSmith UI shows a run count, but every run opens empty, and
`last_run_start_time` never moves.

**Cause:** Relay exports a span when its scope closes. A gateway session stays
open for days, so the enclosing `hermes.session` scope never closes and never
exports. Every span Relay *does* send is therefore an **orphan** — it references a
parent the backend never received. LangSmith accepts them, counts them, and cannot
render them.

One-line check — zero roots is the tell:

```bash
docker logs --since 3m otel-collector 2>&1 | grep -cE "^ *Parent ID *: *$"
```

**Fix:** the `transform/root` processor in `otel-collector-config.yaml` clears the
dangling parent so `hermes.turn` becomes a real root.

`session_segments` does **not** fix this. Rotation only fires when
`segment_turns >= max_turns` within one process, and every CLI invocation is a
fresh process, so the counter resets and rotation never triggers.

## Verifying it works

**Exporter counters are the only trustworthy signal:**

```bash
curl -s localhost:8889/metrics | grep -E \
  "otelcol_(receiver_accepted_spans|exporter_sent_spans|exporter_send_failed_spans)"
```

Healthy:

```
otelcol_receiver_accepted_spans{receiver="otlp"}             50
otelcol_exporter_sent_spans{exporter="otlphttp/langsmith"}   50
# send_failed absent or 0
```

**Do not** grep the collector log for agent names unless `verbosity: detailed` is
set — `basic` hides attributes and absence proves nothing.

**Do not** trust LangSmith's `runs/query` API for a health check; it returned 0
runs for spans LangSmith had answered 200 on. Use `last_run_start_time` from
`GET /api/v1/sessions`, and **wait at least 3 minutes** — indexing lags 30-90s.
Checking too early produces phantom failures.

## What you get

```
hermes.turn                    ← root, renderable
└── hermes.task_run
    └── hermes.logical_llm_call
        └── chat <model>       ← gen_ai.usage.*, finish_reasons
```

Attributes include `gen_ai.input.messages`, `gen_ai.output.messages`,
`gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`,
`gen_ai.response.finish_reasons`, `gen_ai.request.model`.

## Known limitation: one tree per agent, not per round

A `message_teammate` handoff currently appears as **two separate traces**. The
peer plugin sends only `Content-Type` and `Authorization`, so no causal context
crosses the boundary.

Relay ships the API to fix this — verified working inside a sandbox:

```python
ctx = nemo_relay.capture_propagation_context()
ctx.to_json()   # {"version":1,"parent_uuid":"01a03ef5-…"}
nemo_relay.PropagationContext.from_json(j)
nemo_relay._create_scope_stack_from_propagation(ctx)
```

The sender half is a small plugin patch. The receiver half needs
`gateway/platforms/api_server.py` — Hermes core, ~1600 lines — to read the header
and seed the scope, which means a patch that a `hermes update` would overwrite.
Deliberately not done here.
