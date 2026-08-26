#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# 03-enable-tracing.sh — turn on NeMo Relay OTLP export for every agent.
#
# Replaces four hand-editing steps per agent. That matters more than convenience:
# Relay FAILS OPEN, so a typo in relay-plugins.toml gives you a healthy agent that
# exports nothing and says nothing. This script asserts delivery via the collector's
# exporter counters and exits non-zero if spans do not arrive.
#
# Prerequisites: a collector reachable from the sandboxes (see observability/README.md).
#
# Usage:
#   ./scripts/03-enable-tracing.sh                    # all agents
#   ./scripts/03-enable-tracing.sh alpha beta         # named agents only
#   OTLP_PORT=4329 METRICS_PORT=8899 ./scripts/03-enable-tracing.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && { set -a; . "$HERE/.env"; set +a; }
export PATH="$HOME/.local/bin:$PATH"

OTLP_PORT="${OTLP_PORT:-4319}"          # collector OTLP/HTTP port on the bridge
METRICS_PORT="${METRICS_PORT:-8889}"    # collector prometheus port on the host
LANGSMITH_PROJECT="${LANGSMITH_PROJECT:-hermes-swarm}"

ok()   { printf "  \033[32mok\033[0m   %s\n" "$*"; }
warn() { printf "  \033[33mwarn\033[0m %s\n" "$*"; }
die()  { printf "  \033[31mFAIL\033[0m %s\n" "$*" >&2; exit 1; }

# Discover agents from host profiles that route to a sandbox.
discover() {
  local d name
  for d in "$HOME"/.hermes/profiles/*/; do
    name=$(basename "$d")
    [[ "$name" == "default" ]] && continue
    grep -q "host.openshell.internal\|172\.18\.0\.1" "$d/config.yaml" 2>/dev/null \
      && printf '%s\n' "$name"
  done
}

if [[ $# -gt 0 ]]; then
  AGENTS="$*"
else
  AGENTS=$(discover)
fi
[[ -n "${AGENTS// }" ]] || die "no agents found (pass names explicitly, or spawn one first)"

# Read a counter out of the collector's prometheus endpoint. Empty when absent.
counter() {
  curl -s --max-time 10 "http://127.0.0.1:$METRICS_PORT/metrics" 2>/dev/null \
    | awk -v k="$1" 'index($0,k)==1 {print $NF; exit}'
}

echo "==> collector check"
BEFORE=$(counter 'otelcol_exporter_sent_spans{exporter="otlphttp/langsmith"')
if [[ -z "$BEFORE" ]]; then
  warn "no exporter counter on :$METRICS_PORT — cannot verify delivery"
  warn "start the collector first (observability/README.md), or set METRICS_PORT"
  VERIFY=0
else
  ok "collector reachable, spans sent so far: $BEFORE"
  VERIFY=1
fi

for a in $AGENTS; do
  SB="bot-$a"
  echo "==> $a"

  # api_server port from the host profile, so the resource attributes are accurate
  PORT=$(grep -oE '(host\.openshell\.internal|172\.18\.0\.1):[0-9]+' \
          "$HOME/.hermes/profiles/$a/config.yaml" 2>/dev/null | head -1 | cut -d: -f2)

  TOML="version = 1

[[components]]
kind = \"observability\"
enabled = true

[components.config]
version = 3

[components.config.opentelemetry]
enabled = true

[[components.config.opentelemetry.endpoints]]
type = \"gen_ai\"
endpoint = \"http://host.openshell.internal:$OTLP_PORT/v1/traces\"
transport = \"http_binary\"
service_name = \"hermes-$a\"
service_namespace = \"$LANGSMITH_PROJECT\"
timeout_millis = 8000

[components.config.opentelemetry.endpoints.resource_attributes]
\"agent.name\" = \"$a\"
"
  B64=$(printf '%s' "$TOML" | base64 | tr -d '\n')

  # Write config + env var idempotently. sed -i deletes any prior line first.
  if ! timeout 200 openshell sandbox exec -n "$SB" --timeout 170 -- /bin/sh -c \
      "echo $B64 | base64 -d > /sandbox/.hermes/relay-plugins.toml
       E=/sandbox/.hermes/.env
       touch \$E
       sed -i '/^HERMES_NEMO_RELAY_PLUGINS_TOML=/d' \$E
       echo 'HERMES_NEMO_RELAY_PLUGINS_TOML=/sandbox/.hermes/relay-plugins.toml' >> \$E
       chmod 600 \$E
       test -s /sandbox/.hermes/relay-plugins.toml" >/dev/null 2>&1; then
    warn "$a: could not write config (sandbox reachable?) — skipping"
    continue
  fi
  ok "$a: relay-plugins.toml + env var written"

  timeout 200 openshell sandbox exec -n "$SB" --timeout 170 -- /bin/sh -c \
    'export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
     /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main \
       config set telemetry.shared_metrics.enabled true' >/dev/null 2>&1 \
    && ok "$a: shared metrics enabled"

  # The env var is read ONCE at gateway start. Without this restart, nothing changes.
  timeout 200 openshell sandbox exec -n "$SB" --timeout 170 -- /bin/sh -c \
    'export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
     /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway stop \
       >/dev/null 2>&1 || true
     rm -f /sandbox/.hermes/gateway.pid /sandbox/.hermes/gateway.lock' >/dev/null 2>&1
  sleep 3
  setsid openshell sandbox exec -n "$SB" --timeout 0 -- /bin/sh -c \
    'export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
     export HERMES_NEMO_RELAY_PLUGINS_TOML=/sandbox/.hermes/relay-plugins.toml
     exec /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run' \
    > "${LOG_DIR:-$HERE/logs}/sbgw-$a.log" 2>&1 < /dev/null &
  ok "$a: gateway restarted (port ${PORT:-unknown})"
done

echo "==> waiting for gateways"
sleep 30

# Relay fails open, so a config that looks right proves nothing. Only spans do.
if [[ "$VERIFY" -eq 1 ]]; then
  echo "==> verifying delivery with a real turn"
  FIRST=$(printf '%s\n' $AGENTS | head -1)
  timeout 300 hermes -p "$FIRST" chat -q "Reply with exactly TRACING-ON" >/dev/null 2>&1
  sleep 25
  AFTER=$(counter 'otelcol_exporter_sent_spans{exporter="otlphttp/langsmith"')
  FAILED=$(counter 'otelcol_exporter_send_failed_spans')
  echo "  spans sent: ${BEFORE:-0} -> ${AFTER:-0}   failed: ${FAILED:-0}"
  if [[ -n "$AFTER" && -n "$BEFORE" && "$AFTER" -gt "$BEFORE" ]]; then
    ok "tracing confirmed: spans are reaching the collector"
  else
    die "no new spans after a real turn. Relay fails OPEN, so the agent is healthy
     but exporting nothing. Check: the bridge port is allowed by the sandbox's
     egress policy (403 = denied), and the gateway restarted after the config was
     written."
  fi
else
  warn "config written but delivery NOT verified (no collector metrics)"
  warn "start the collector, then re-run this script"
  exit 1
fi

cat <<EOF

Traces should now appear in the "$LANGSMITH_PROJECT" project. Allow 30-90s for
LangSmith to index them.

Verify at any time:
  curl -s localhost:$METRICS_PORT/metrics | grep otelcol_exporter_sent_spans
EOF
