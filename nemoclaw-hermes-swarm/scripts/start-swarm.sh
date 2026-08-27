#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# start-swarm.sh — restore agents created by THIS checkout after a host reboot.
#
# Does not start or manage inference servers, generic vllm-/relay- containers, or
# unrelated NemoClaw recipes. Model deployment is out of scope for this example.
# Agent ownership is defined by non-empty key files in this checkout's secrets/.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && { set -a; . "$HERE/.env"; set +a; }
export PATH="$HOME/.local/bin:$PATH"

SWARM_HOME="${SWARM_HOME:-$HERE}"
SECRETS_DIR="${SECRETS_DIR:-$SWARM_HOME/secrets}"
LOG_DIR="${LOG_DIR:-$SWARM_HOME/logs}"
BRIDGE="${BRIDGE:-$(docker network inspect openshell-docker \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo 172.18.0.1)}"
mkdir -p "$LOG_DIR"

ok(){ printf "  \033[32mok\033[0m   %s\n" "$*"; }
no(){ printf "  \033[31mFAIL\033[0m %s\n" "$*"; fail=$((fail+1)); }
fail=0

shopt -s nullglob
KEY_FILES=("$SECRETS_DIR"/*.key)
AGENTS=()
for f in "${KEY_FILES[@]+"${KEY_FILES[@]}"}"; do
  [[ -s "$f" ]] && AGENTS+=("$(basename "$f" .key)")
done

if [[ ${#AGENTS[@]} -eq 0 ]]; then
  echo "No agents owned by this checkout (no non-empty keys in $SECRETS_DIR)."
  echo "Run ./scripts/02-bootstrap-two-agents.sh first."
  exit 1
fi
echo "==> agents: ${AGENTS[*]}"

# The inference endpoint is user-owned. Check it; never start it implicitly.
echo "==> inference endpoint"
if [[ -z "${INFERENCE_URL:-}" ]]; then
  no "INFERENCE_URL is not set in $HERE/.env"
else
  probe="${INFERENCE_URL%/}/models"
  probe="${probe//host.openshell.internal/$BRIDGE}"
  if [[ -n "${INFERENCE_KEY:-}" ]]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      -H "Authorization: Bearer $INFERENCE_KEY" "$probe")
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$probe")
  fi
  [[ "$code" == 200 ]] && ok "inference endpoint (200)" \
                         || no "inference endpoint returned ${code:-000}; start it before the swarm"
fi

echo "==> agent gateways and forwards"
for a in "${AGENTS[@]}"; do
  sb="bot-$a"
  profile="$HOME/.hermes/profiles/$a/config.yaml"
  [[ -f "$profile" ]] || { no "$a host profile missing"; continue; }
  port=$(grep -oE '(host\.openshell\.internal|172\.18\.0\.1):[0-9]+' "$profile" \
    | cut -d: -f2 | sed -n '1p')
  [[ -n "$port" ]] || { no "$a: cannot resolve api port"; continue; }

  phase=$(openshell sandbox list 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' \
    | awk -v n="$sb" '$1==n{print $NF}')
  [[ "$phase" == Ready ]] || { no "$a sandbox phase=${phase:-missing}"; continue; }

  # Check the endpoint inside the sandbox, not the host-side sandbox-exec wrapper:
  # wrappers die with SSH while the gateway keeps running.
  listening=$(timeout 80 openshell sandbox exec -n "$sb" --timeout 60 -- /bin/sh -c \
    "ss -lnt 2>/dev/null | grep -c ':$port'" 2>/dev/null \
    | grep -v Permission | tr -d ' \r\n' | sed -n '1p')
  if [[ "$listening" != 1 ]]; then
    relay_export=""
    if timeout 60 openshell sandbox exec -n "$sb" --timeout 45 -- /bin/sh -c \
         'test -s /sandbox/.hermes/relay-plugins.toml && echo yes' 2>/dev/null \
         | grep -q yes; then
      relay_export='export HERMES_NEMO_RELAY_PLUGINS_TOML=/sandbox/.hermes/relay-plugins.toml'
    fi
    setsid openshell sandbox exec -n "$sb" --timeout 0 -- /bin/sh -c \
      "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
       $relay_export
       exec /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run" \
      > "$LOG_DIR/sbgw-$a.log" 2>&1 < /dev/null &
    sleep 20
  fi

  # Exactly one bridge forward per port. Kill only matching PIDs, never pkill -f.
  mapfile -t fpids < <(pgrep -f "openshell forward service --target-port $port" 2>/dev/null || true)
  if [[ ${#fpids[@]} -ne 1 ]]; then
    for p in "${fpids[@]+"${fpids[@]}"}"; do kill "$p" 2>/dev/null || true; done
    sleep 2
    setsid openshell forward service --target-port "$port" --local "$BRIDGE:$port" "$sb" \
      > "$LOG_DIR/fwd-$a.log" 2>&1 < /dev/null &
    sleep 8
  fi

  key=$(cat "$SECRETS_DIR/$a.key" 2>/dev/null)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer $key" "http://$BRIDGE:$port/v1/models")
  [[ "$code" == 200 ]] && ok "$a api_server :$port (200)" \
                         || no "$a api_server :$port (${code:-000})"

  # Host gateway makes the profile visible in the desktop roster.
  cur=$(hermes profile list 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' \
    | awk -v n="$a" '$1==n{print $3}')
  if [[ "$cur" == running ]]; then
    ok "$a host gateway alive"
  else
    setsid hermes -p "$a" gateway run > "$LOG_DIR/host-gw-$a.log" 2>&1 < /dev/null &
    sleep 20
    st=$(hermes profile list 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' \
      | awk -v n="$a" '$1==n{print $3}')
    [[ "$st" == running ]] && ok "$a host gateway started" \
                             || no "$a profile shows ${st:-missing}"
  fi
done

echo
echo "agents: ${#AGENTS[@]}   failures: $fail"
echo "next: $HERE/scripts/e2e-test.sh"
exit "$(( fail > 255 ? 255 : fail ))"
