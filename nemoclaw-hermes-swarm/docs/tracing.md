# Tracing with NeMo Relay

See what each bot did: per-turn spans with inputs, outputs, token usage, and
tool calls, filterable by bot. NeMo Relay is part of Hermes, so this is
configuration, not code, and `./swarm up` does it by default.

## Why

Four failures from building this example, and the span that exposes each:

| Symptom | What the trace shows |
|---|---|
| one bot silently receives no work while others reply | no turn span for that bot in the round |
| a chained task deadlocks | a turn that closes with zero tool-call children |
| a bot claims it verified sources but invented them | a turn asserting verification with no tool spans beneath it |
| a bot says `(pass)`: broken, or correct? | a completed turn span with short output means working |

The third took an hour to catch by hand. As a trace it is one glance.

## Shape

```
 sandbox v2-<bot>                              host
 ┌──────────────────────────────┐  OTLP/HTTP   ┌──────────────────────┐
 │ Hermes + Relay (in-process)  │─────────────▶│ swarm-otel  :4319    │──▶ debug log
 │ /sandbox/.hermes/            │   bridge     │  LangSmith key from  │──▶ LangSmith
 │   relay-plugins.toml         │  172.18.0.1  │  host file, env only │    (optional)
 └──────────────────────────────┘              └──────────────────────┘
```

The collector is not decoration. It keeps the LangSmith key on the host.
Sandboxes are agent-writable, so a credential inside one belongs to the agent.

## What `swarm` does

For every bot, `swarm up` and `swarm add`:

1. render `observability/relay-plugins.toml.tmpl` with the bot's name and the
   collector port, and copy it to `/sandbox/.hermes/relay-plugins.toml`
2. set `HERMES_NEMO_RELAY_PLUGINS_TOML=/sandbox/.hermes/relay-plugins.toml` in
   `/sandbox/.hermes/.env`
3. apply `policies/otlp-export.yaml` additively so the bot may reach the collector
4. restart the in-sandbox gateway, because the variable is read once at start

Once, it starts the collector from `observability/otel-collector-config.yaml.tmpl`.
If `LANGSMITH_KEY_FILE` (default `~/.langsmith/api_key`) exists, spans also go to
LangSmith under `LANGSMITH_PROJECT`. If not, they go to the collector's debug log
and the counters, which is enough to verify the pipeline.

Turn it off with `TRACING=off` in `swarm.env`.

## Verifying

```bash
./swarm traces researcher
```

prints the bot's relay state (config present, env set, activation line in its
`agent.log`) and the collector's counters. The counters are the only trustworthy
delivery signal:

```
otelcol_receiver_accepted_spans   45
otelcol_exporter_sent_spans       45     (per exporter)
otelcol_exporter_send_failed      0
```

`./swarm test` section 9 sends a real turn and fails unless `sent` increases.

## Three things that waste an afternoon

**Relay fails open.** A missing or malformed `relay-plugins.toml` logs one
warning and runs with tracing off: a healthy bot exporting nothing. Never assume
it activated. Check counters.

**The env var is read once, at process start.** Writing the TOML or the variable
while the gateway runs does nothing. `swarm` always restarts the gateway after
touching either.

**The activation line is in `agent.log`, not `gateway.log`.** Relay logs
`Relay plugins are active process-wide` at INFO through Hermes' own logger, which
writes `/sandbox/.hermes/logs/agent.log` inside the sandbox. It is not in the
stderr captured on the host and not in `gateway.log`.

## The bug that makes LangSmith runs render empty

Symptom: LangSmith shows a run count, every run opens empty, and
`last_run_start_time` never moves.

Cause: Relay exports a span when its scope closes. A gateway session stays open
for days, so the enclosing `hermes.session` scope never closes and never exports.
Every span Relay does send references a parent LangSmith never receives. It
accepts them, counts them, and cannot render them.

Fix: the `transform/root` processor in the collector config clears the dangling
parent on `hermes.turn` and `hermes.task_run`, so each turn is a real root. The
template ships with it. Note the 16-zero form: `set(parent_span_id.string, "")`
passes validation and does nothing.

## What a trace looks like

```
hermes.turn                                root
└── hermes.task_run
    └── hermes.logical_llm_call
        └── chat <model>                   gen_ai.usage.*, finish_reasons
```

Attributes follow the OTel GenAI conventions: `gen_ai.input.messages`,
`gen_ai.output.messages`, `gen_ai.usage.input_tokens`,
`gen_ai.usage.output_tokens`, `gen_ai.request.model`, plus `agent.name` from the
resource attributes so you can filter by bot.

## Known limitation: one tree per bot, not per handoff

A `message_teammate` handoff appears as two traces: the researcher's turn, and
separately the reviewer's turn it triggered. The plugin sends only
`Content-Type` and `Authorization`; no causal context crosses the boundary.

Relay has the API to link them (`capture_propagation_context`, verified working
inside a sandbox). The sender half is a small plugin change. The receiver half
needs the api_server in Hermes core to read a header and seed the scope, which is
a patch `hermes update` would overwrite. Deliberately not done here; if Hermes
grows a hook for it, this example will use it.

## Other backends

The collector speaks OTLP; point `exporters` at anything that accepts it. For
Arize Phoenix, set `type = "openinference"` in the relay template instead of
`gen_ai`. For debugging Relay itself, `type = "full"` emits every
`nemo_relay.*` attribute. Two endpoints of different types must not share an
endpoint and transport; Relay derives span IDs deterministically and rejects
the collision.
