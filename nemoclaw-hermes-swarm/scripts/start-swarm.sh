#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# start-sandboxed-bots.sh — restore the full sandboxed-agent stack.
# Idempotent and agent-count agnostic: discovers every sandbox-routed profile
# instead of hardcoding names, so agents added by spawn-agent.sh come back too.
export PATH="$HOME/.local/bin:$PATH"
POC="$SWARM_HOME"
BRIDGE=${BRIDGE}
mkdir -p "$LOG_DIR"

ok(){ printf "  \033[32mok\033[0m   %s\n" "$*"; }
no(){ printf "  \033[31mFAIL\033[0m %s\n" "$*"; }

# ── discover agents (profiles whose model points at a sandbox api_server) ────
mapfile -t AGENTS < <(
  for d in "$HOME"/.hermes/profiles/*/; do
    n=$(basename "$d"); [[ "$n" == "default" ]] && continue
    [[ -f "$d/config.yaml" ]] || continue
    grep -Eq 'base_url:[[:space:]]*http://172\.18\.0\.1:8[0-9]+' "$d/config.yaml" && echo "$n"
  done
)
echo "==> agents: ${AGENTS[*]:-none}"

# ── 1. vLLM engines ─────────────────────────────────────────────────────────
echo "==> inference engines"
for c in $(docker ps -a --format '{{.Names}}' | grep -E '^vllm-'); do
  st=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null)
  [[ "$st" == running ]] || { docker start "$c" >/dev/null 2>&1; sleep 3; }
  st=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null)
  [[ "$st" == running ]] && ok "$c $st" || no "$c $st"
done

# ── 2. relays (host loopback -> openshell bridge) ───────────────────────────
echo "==> relays"
for c in $(docker ps -a --format '{{.Names}}' | grep -E '^relay-'); do
  st=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null)
  if [[ "$st" != running ]]; then docker start "$c" >/dev/null 2>&1; sleep 2; fi
  st=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null)
  [[ "$st" == running ]] && ok "$c" || no "$c ($st)"
done

# ── 3. host-side recipe services ────────────────────────────────────────────
echo "==> host services"
for c in extras-postgres-1 extras-postgrest-1 extras-forums-etl-1 extras-phoenix-1 deep-research-worker; do
  docker inspect "$c" >/dev/null 2>&1 || continue
  st=$(docker inspect "$c" --format '{{.State.Status}}' 2>/dev/null)
  [[ "$st" == running ]] || docker start "$c" >/dev/null 2>&1
  ok "$c"
done

# ── 4. per-agent: in-sandbox gateway + gRPC forward ─────────────────────────
echo "==> agent gateways and forwards"
for a in "${AGENTS[@]}"; do
  sb="bot-$a"
  port=$(grep -oE '172\.18\.0\.1:8[0-9]+' "$HOME/.hermes/profiles/$a/config.yaml" | head -1 | cut -d: -f2)
  [[ -n "$port" ]] || { no "$a: cannot resolve api port"; continue; }

  # gateway inside the sandbox (refuses politely if already running)
  if ! pgrep -f "sandbox exec -n $sb" >/dev/null 2>&1; then
    setsid openshell sandbox exec -n "$sb" --timeout 0 -- /bin/sh -c \
      "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
       /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run" \
      > "$LOG_DIR/sbgw-$a.log" 2>&1 < /dev/null &
    sleep 20
  fi

  # forward: exactly one per agent. setsid so it outlives this shell.
  n=$(pgrep -fc "forward service --target-port $port" 2>/dev/null || echo 0)
  if [[ "$n" -ne 1 ]]; then
    pkill -f "forward service --target-port $port" 2>/dev/null
    sleep 2
    setsid openshell forward service --target-port "$port" --local "$BRIDGE:$port" "$sb" \
      > "$LOG_DIR/fwd-$a.log" 2>&1 < /dev/null &
    sleep 8
  fi

  key=$(cat "$POC/secrets/$a.key" 2>/dev/null)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
           -H "Authorization: Bearer ***" "http://$BRIDGE:$port/v1/models" || true)
  [[ "$code" == 200 ]] && ok "$a api_server :$port (200)" || no "$a api_server :$port ($code)"

  # HOST gateway — required for the profile to show `running` and appear in the
  # desktop Bots roster. Separate from the in-sandbox gateway above.
  # Ask hermes rather than testing the pid file: gateway_running needs an active
  # gateway.lock AND a start_time match, so a stale pid can pass kill -0 yet
  # still report `stopped`.
  cur=$(hermes profile list 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' | awk -v n="$a" '$1==n{print $3}')
  if [[ "$cur" == running ]]; then
    ok "$a host gateway alive"
  else
    setsid hermes -p "$a" gateway run > "$HOME/poc-listing-$a.tmp" 2>&1 < /dev/null &
    sleep 20
    st=$(hermes profile list 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' | awk -v n="$a" '$1==n{print $3}')
    [[ "$st" == running ]] && ok "$a host gateway started (running)" || no "$a shows '${st:-?}'"
  fi
done

# ── 5. health summary ───────────────────────────────────────────────────────
echo "==> endpoints"
for p in 8001 8002; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$p/v1/models" || true)
  [[ "$code" == 200 ]] && ok "vllm :$p" || no "vllm :$p ($code)"
done
for pair in "9050 deep-research" "3100 etl-mirror"; do
  set -- $pair
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$BRIDGE:$1/" || true)
  [[ "$code" =~ ^(200|404)$ ]] && ok "$2 :$1" || no "$2 :$1 ($code)"
done

echo
echo "  agents up: ${#AGENTS[@]}   next: $SWARM_HOME/e2e-test.sh"
