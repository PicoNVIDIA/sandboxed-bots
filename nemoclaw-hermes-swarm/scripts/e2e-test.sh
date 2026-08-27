#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end verification for agents created by THIS checkout.
# Discovers agents from this checkout's secrets/ directory, so unrelated profiles
# on a shared host cannot contaminate the result.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && { set -a; . "$HERE/.env"; set +a; }
export PATH="$HOME/.local/bin:$PATH"

SWARM_HOME="${SWARM_HOME:-$HERE}"
SECRETS_DIR="${SECRETS_DIR:-$SWARM_HOME/secrets}"
BRIDGE="${BRIDGE:-$(docker network inspect openshell-docker \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo 172.18.0.1)}"
OTLP_PORT="${OTLP_PORT:-4319}"
METRICS_PORT="${METRICS_PORT:-8889}"

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1  [$2]"; fail=$((fail+1)); }
chk(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "got '$2' want '$3'"; fi; }
section(){ echo "=============================================="; echo "$1"; echo "=============================================="; }
nocolor(){ sed -r 's/\x1B\[[0-9;]*[mK]//g'; }

# Agent ownership boundary: a non-empty key file in THIS checkout.
shopt -s nullglob
KEY_FILES=("$SECRETS_DIR"/*.key)
AGENTS=()
for f in "${KEY_FILES[@]+"${KEY_FILES[@]}"}"; do
  [[ -s "$f" ]] && AGENTS+=("$(basename "$f" .key)")
done
NAGENTS=${#AGENTS[@]}

port_of(){
  grep -oE '(host\.openshell\.internal|172\.18\.0\.1):[0-9]+' \
    "$HOME/.hermes/profiles/$1/config.yaml" 2>/dev/null | cut -d: -f2 | sed -n '1p'
}
msg_count(){
  timeout 90 openshell sandbox exec -n "bot-$1" --timeout 70 -- /bin/sh -c \
    '/sandbox/.hermes/hermes-agent/venv/bin/python -c "import sqlite3; print(sqlite3.connect(\"/sandbox/.hermes/state.db\").execute(\"select count(*) from messages\").fetchone()[0])"' \
    2>/dev/null | grep -v 'profile: Permission' | tr -d ' \r\n'
}

section "1. CHECKOUT AND INFERENCE ENDPOINT"
chk "agents discovered from this checkout" "$NAGENTS" "${NAGENTS:-0}"
if [[ "$NAGENTS" -eq 0 ]]; then
  no "at least one agent exists" "run ./scripts/02-bootstrap-two-agents.sh first"
  echo "SUMMARY: $pass passed, $fail failed"
  exit "$fail"
fi
ok "local agents: ${AGENTS[*]}"

if [[ -z "${INFERENCE_URL:-}" ]]; then
  no "INFERENCE_URL configured" "copy .env.example to .env and set it"
else
  _probe="${INFERENCE_URL%/}/models"
  _probe="${_probe//host.openshell.internal/$BRIDGE}"
  if [[ -n "${INFERENCE_KEY:-}" ]]; then
    _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -H "Authorization: Bearer $INFERENCE_KEY" "$_probe")
  else
    _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$_probe")
  fi
  chk "inference endpoint answers" "$_code" "200"
fi

section "2. SANDBOXES AND API SERVERS"
for a in "${AGENTS[@]}"; do
  phase=$(openshell sandbox list 2>/dev/null | nocolor | awk -v n="bot-$a" '$1==n{print $NF}')
  chk "sandbox bot-$a Ready" "${phase:-missing}" "Ready"

  p=$(port_of "$a")
  [[ -n "$p" ]] && ok "$a profile routes to sandbox port $p" \
                   || no "$a profile base_url" "bridge port not found"
  k=$(cat "$SECRETS_DIR/$a.key" 2>/dev/null)
  auth=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer $k" "http://$BRIDGE:$p/v1/models")
  noauth=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "http://$BRIDGE:$p/v1/models")
  chk "$a api_server authenticated" "$auth" "200"
  chk "$a api_server rejects no-auth" "$noauth" "401"
done

section "3. PEER-MESSAGING PLUGIN"
for a in "${AGENTS[@]}"; do
  host_files=$(find "$HOME/.hermes/profiles/$a/plugins/peer-messaging" -maxdepth 1 \
    -type f 2>/dev/null | grep -cE '/(plugin\.yaml|schemas\.py|tools\.py|__init__\.py)$')
  chk "$a host plugin has 4 files" "$host_files" "4"
  host_on=$(grep -A3 '^plugins:' "$HOME/.hermes/profiles/$a/config.yaml" 2>/dev/null \
    | grep -cE '^[[:space:]]*-[[:space:]]+peer-messaging$')
  chk "$a host plugin enabled" "$host_on" "1"

  sb_files=$(timeout 90 openshell sandbox exec -n "bot-$a" --timeout 70 -- /bin/sh -c \
    'find /sandbox/.hermes/plugins/peer-messaging -maxdepth 1 -type f 2>/dev/null | grep -cE "/(plugin\.yaml|schemas\.py|tools\.py|__init__\.py)$"' \
    2>/dev/null | grep -v Permission | tr -d ' \r\n')
  chk "$a sandbox plugin has 4 files" "$sb_files" "4"
  sb_on=$(timeout 90 openshell sandbox exec -n "bot-$a" --timeout 70 -- /bin/sh -c \
    'grep -A3 "^plugins:" /sandbox/.hermes/config.yaml 2>/dev/null | grep -cE "^[[:space:]]*-[[:space:]]+peer-messaging$"' \
    2>/dev/null | grep -v Permission | tr -d ' \r\n')
  chk "$a sandbox plugin enabled" "$sb_on" "1"
done

section "4. PEER MESH"
if [[ "$NAGENTS" -lt 2 ]]; then
  echo "  SKIP  peer mesh needs at least 2 agents"
else
  for src in "${AGENTS[@]}"; do
    for dst in "${AGENTS[@]}"; do
      [[ "$src" == "$dst" ]] && continue
      n=$(hermes -p "$src" peer list 2>/dev/null | grep -c "^$dst")
      chk "$src knows $dst" "$n" "1"
    done
  done
fi

section "5. KERNEL AND FILESYSTEM ISOLATION"
NAMESPACES=()
host_ns=$(readlink /proc/self/ns/pid | tr -dc 0-9)
for a in "${AGENTS[@]}"; do
  marker="ISO-$a-$RANDOM"
  timeout 80 openshell sandbox exec -n "bot-$a" --timeout 60 -- /bin/sh -c \
    "echo $marker > /sandbox/e2e-isolation.txt" >/dev/null 2>&1
  got=$(timeout 80 openshell sandbox exec -n "bot-$a" --timeout 60 -- /bin/sh -c \
    'cat /sandbox/e2e-isolation.txt' 2>/dev/null | grep -v Permission | tr -d ' \r\n')
  chk "$a sees only its marker" "$got" "$marker"

  ns=$(timeout 80 openshell sandbox exec -n "bot-$a" --timeout 60 -- /bin/sh -c \
    'readlink /proc/self/ns/pid | tr -dc 0-9' 2>/dev/null \
    | grep -v Permission | tr -d ' \r\n')
  [[ -n "$ns" ]] && ok "$a PID namespace $ns" || no "$a PID namespace" "missing"
  [[ "$ns" != "$host_ns" ]] && ok "$a namespace differs from host" \
                              || no "$a namespace differs from host" "$ns"
  NAMESPACES+=("$ns")
done
uniq_ns=$(printf '%s\n' "${NAMESPACES[@]}" | sort -u | wc -l | tr -d ' ')
chk "every agent has a distinct PID namespace" "$uniq_ns" "$NAGENTS"

section "6. REAL AGENT TURNS"
for a in "${AGENTS[@]}"; do
  before=$(msg_count "$a")
  out=$(timeout 300 hermes -p "$a" chat -q "Reply with exactly ${a}-E2E-OK" 2>&1 \
    | grep -aoE "${a}-E2E-OK" | sed -n '1p')
  after=$(msg_count "$a")
  chk "$a replies via host profile" "$out" "${a}-E2E-OK"
  if [[ -n "$before" && -n "$after" && "$after" -gt "$before" ]]; then
    ok "$a turn executed inside sandbox ($before -> $after messages)"
  else
    no "$a turn executed inside sandbox" "$before -> $after"
  fi
done

section "7. AGENT-TO-AGENT MESSAGING"
if [[ "$NAGENTS" -lt 2 ]]; then
  echo "  SKIP  messaging needs at least 2 agents"
else
  for src in "${AGENTS[@]}"; do
    for dst in "${AGENTS[@]}"; do
      [[ "$src" == "$dst" ]] && continue
      stamp="$(date +%s)-$RANDOM"
      file="/sandbox/e2e-$src-to-$dst-$stamp.txt"
      secret="PEER-$src-$dst-$stamp"
      timeout 90 openshell sandbox exec -n "bot-$dst" --timeout 70 -- /bin/sh -c \
        "echo $secret > $file" >/dev/null 2>&1
      r=$(timeout 420 openshell sandbox exec -n "bot-$src" --timeout 380 -- /bin/sh -c \
        "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
         cd /sandbox/.hermes/plugins/peer-messaging
         /sandbox/.hermes/hermes-agent/venv/bin/python - <<'PY'
import json,sys
sys.path.insert(0,'.')
import tools
r=json.loads(tools.message_teammate({
  'teammate':'$dst',
  'message':'Read the file $file and reply with only its exact contents. Do not use cached content.'
}))
print(r.get('reply') or 'ERR:'+str(r.get('error')))
PY" 2>/dev/null | grep -v Permission)
      echo "$r" | grep -q "$secret" && ok "$src -> $dst retrieved unique secret" \
                                       || no "$src -> $dst messaging" "expected $secret, got $(echo "$r" | tail -1 | cut -c1-90)"
    done
  done
fi

section "8. DESKTOP ROSTER READINESS"
chk "hermes on login-shell PATH" "$(bash -lc 'command -v hermes' >/dev/null 2>&1 && echo yes || echo no)" "yes"
found=0
for a in "${AGENTS[@]}"; do
  st=$(hermes profile list 2>/dev/null | nocolor | awk -v n="$a" '$1==n{print $3}')
  chk "$a profile reports running" "${st:-missing}" "running"
  [[ -f "$HOME/.hermes/profiles/$a/gateway.pid" ]] \
    && ok "$a has gateway.pid" || no "$a has gateway.pid" "missing"
  [[ -n "$st" ]] && found=$((found+1))
done
chk "all local profiles enumerable" "$found" "$NAGENTS"

section "9. TRACING (NeMo Relay -> collector)"
any_trace=0
for a in "${AGENTS[@]}"; do
  timeout 80 openshell sandbox exec -n "bot-$a" --timeout 60 -- /bin/sh -c \
    'test -s /sandbox/.hermes/relay-plugins.toml && echo yes' 2>/dev/null \
    | grep -q yes && any_trace=1
done
if [[ "$any_trace" -eq 0 ]]; then
  echo "  SKIP  tracing not enabled (run ./scripts/03-enable-tracing.sh)"
else
  for a in "${AGENTS[@]}"; do
    t=$(timeout 80 openshell sandbox exec -n "bot-$a" --timeout 60 -- /bin/sh -c \
      'test -s /sandbox/.hermes/relay-plugins.toml && echo yes || echo no' 2>/dev/null \
      | grep -v Permission | tr -d ' \r\n')
    chk "$a relay-plugins.toml present" "$t" "yes"
    e=$(timeout 80 openshell sandbox exec -n "bot-$a" --timeout 60 -- /bin/sh -c \
      'grep -c "^HERMES_NEMO_RELAY_PLUGINS_TOML=" /sandbox/.hermes/.env 2>/dev/null || echo 0' \
      2>/dev/null | grep -v Permission | tr -d ' \r\n' | tail -c1)
    chk "$a relay env var set" "$e" "1"
    c=$(timeout 80 openshell sandbox exec -n "bot-$a" --timeout 60 -- /bin/sh -c \
      "curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST \
       -H 'Content-Type: application/json' -d '{}' \
       http://host.openshell.internal:$OTLP_PORT/v1/traces" 2>/dev/null \
      | grep -v Permission | tr -d ' \r\n')
    if [[ "$c" == "403" || "$c" == "000" || -z "$c" ]]; then
      no "$a can reach collector :$OTLP_PORT" "HTTP ${c:-000}"
    else
      ok "$a can reach collector :$OTLP_PORT (HTTP $c)"
    fi
  done
  sent=$(curl -s --max-time 10 "http://127.0.0.1:$METRICS_PORT/metrics" 2>/dev/null \
    | awk '/^otelcol_exporter_sent_spans\{exporter="otlphttp/ {print $NF; exit}')
  bad=$(curl -s --max-time 10 "http://127.0.0.1:$METRICS_PORT/metrics" 2>/dev/null \
    | awk '/^otelcol_exporter_send_failed_spans/ {print $NF; exit}')
  if [[ -z "$sent" ]]; then
    no "collector exporter counter available" "metrics missing on :$METRICS_PORT"
  else
    [[ "${sent%%.*}" -gt 0 ]] && ok "collector exported spans ($sent)" \
                               || no "collector exported spans" "$sent"
    chk "no failed span exports" "${bad:-0}" "0"
  fi
fi

echo "=============================================="
echo "SUMMARY: $pass passed, $fail failed"
echo "=============================================="
exit "$(( fail > 255 ? 255 : fail ))"
