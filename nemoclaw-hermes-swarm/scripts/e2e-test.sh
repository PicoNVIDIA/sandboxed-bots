#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# End-to-end test for the two-bot sandboxed setup.
# Every check prints PASS or FAIL. Exit 0 only if all pass.
export PATH=$HOME/.local/bin:$PATH
pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1  [$2]"; fail=$((fail+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got '$2' want '$3'"; fi; }

echo "=============================================="
echo "1. INFERENCE ENGINES (vLLM on host)"
echo "=============================================="
for c in vllm-a vllm-b; do
  chk "container $c running" "$(docker inspect $c --format '{{.State.Status}}' 2>/dev/null || echo missing)" "running"
done
for p in 8001 8002; do
  chk "vLLM :$p serving" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:$p/v1/models)" "200"
done

echo "=============================================="
echo "2. RELAYS (host loopback -> openshell bridge)"
echo "=============================================="
for c in relay-8001 relay-8002; do
  chk "relay $c running" "$(docker inspect $c --format '{{.State.Status}}' 2>/dev/null || echo missing)" "running"
done
for p in 18001 18002; do
  chk "bridge ${BRIDGE}:$p" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${BRIDGE}:$p/v1/models)" "200"
done

echo "=============================================="
echo "3. SANDBOXES"
echo "=============================================="
nocolor(){ sed -r 's/\x1B\[[0-9;]*[mK]//g'; }
for s in bot-alpha bot-beta; do
  chk "sandbox $s Ready" "$(openshell sandbox list 2>/dev/null | nocolor | awk -v n=$s '$1==n{print $NF}')" "Ready"
done
chk "other team sandbox 'hermes' untouched" "$(openshell sandbox list 2>/dev/null | nocolor | awk '$1=="hermes"{print $NF}')" "Ready"
chk "other team container alive" "$(docker inspect openshell-hermes-edd08f40-57c7-4c2a-acbe-509b1f4ef5a2 --format '{{.State.Status}}' 2>/dev/null || echo missing)" "running"

echo "=============================================="
echo "4. SANDBOX API SERVERS (for peer messaging)"
echo "=============================================="
for pair in "alpha 8477" "beta 8478"; do
  set -- $pair
  K=$(cat $SWARM_HOME/secrets/$1.key 2>/dev/null)
  chk "$1 api_server authed" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ***" http://${BRIDGE}:$2/v1/models)" "200"
  chk "$1 api_server rejects no-auth" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${BRIDGE}:$2/v1/models)" "401"
done
NAGENTS=$(ls -d ~/.hermes/profiles/*/ 2>/dev/null | xargs -n1 basename | grep -vx default | wc -l | tr -d ' ')
chk "gRPC forwards running" "$(pgrep -fc 'forward service')" "$NAGENTS"
# NB: the host-side `sandbox exec` wrapper dies with its SSH session while the
# in-sandbox gateway keeps running — counting wrappers gives false failures.
# Test what actually matters: each agent's api_server answering on the bridge.
GW_OK=0
for _a in $(ls -d ~/.hermes/profiles/*/ 2>/dev/null | xargs -n1 basename | grep -vx default); do
  _p=$(grep -oE '172\.18\.0\.1:8[0-9]+' ~/.hermes/profiles/$_a/config.yaml 2>/dev/null | head -1 | cut -d: -f2)
  _k=$(cat $SWARM_HOME/secrets/$_a.key 2>/dev/null)
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Authorization: Bearer ***" http://${BRIDGE}:$_p/v1/models)" = "200" ] && GW_OK=$((GW_OK+1))
done
chk "agent api_servers answering" "$GW_OK" "$NAGENTS"

echo "=============================================="
echo "5. HOST PROFILE CONFIG (what desktop uses)"
echo "=============================================="
for pair in "alpha 8477" "beta 8478"; do
  set -- $pair
  chk "$1 base_url -> sandbox :$2" "$(grep -A8 '^model:' ~/.hermes/profiles/$1/config.yaml | grep -oE '${BRIDGE}:[0-9]+' | head -1)" "${BRIDGE}:$2"
  chk "$1 model id" "$(grep -A8 '^model:' ~/.hermes/profiles/$1/config.yaml | grep -oE 'default: [a-z0-9.-]+' | head -1 | awk '{print $2}')" "hermes-agent"
  chk "$1 max_tokens set" "$(grep -A8 '^model:' ~/.hermes/profiles/$1/config.yaml | grep -c 'max_tokens')" "1"
done

echo "=============================================="
echo "6. PEER-MESSAGING PLUGIN INSTALLED (4 places)"
echo "=============================================="
for b in alpha beta; do
  chk "host $b plugin files" "$(ls ~/.hermes/profiles/$b/plugins/peer-messaging/ 2>/dev/null | grep -cE '^(plugin\.yaml|schemas\.py|tools\.py|__init__\.py)$')" "4"
  chk "host $b plugin enabled" "$(grep -A3 '^plugins:' ~/.hermes/profiles/$b/config.yaml 2>/dev/null | grep -c 'peer-messaging')" "1"
done

echo "=============================================="
echo "7. BOT PEERS REGISTERED"
echo "=============================================="
chk "host alpha knows beta" "$(hermes -p alpha peer list 2>/dev/null | grep -c '^beta')" "1"
chk "host beta knows alpha" "$(hermes -p beta peer list 2>/dev/null | grep -c '^alpha')" "1"


echo "=============================================="
echo "8. LIVE: each bot answers through its sandbox"
echo "=============================================="
CNT(){ timeout 90 openshell sandbox exec -n bot-$1 --timeout 70 -- /bin/sh -c \
  '/sandbox/.hermes/hermes-agent/venv/bin/python -c "import sqlite3;print(list(sqlite3.connect(\"/sandbox/.hermes/state.db\").execute(\"select count(*) from messages\"))[0][0])"' \
  2>/dev/null | grep -v "profile: Permission" | tr -d " \r\n"; }

for b in $(ls -d ~/.hermes/profiles/*/ 2>/dev/null | xargs -n1 basename | grep -vx default); do
  BEFORE=$(CNT $b)
  OUT=$(timeout 300 hermes -p $b chat -q "Reply with exactly: ${b}-E2E-OK" 2>&1 | grep -aoE "${b}-E2E-OK" | head -1)
  AFTER=$(CNT $b)
  chk "$b replies via host profile" "$OUT" "${b}-E2E-OK"
  if [ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$AFTER" -gt "$BEFORE" ]; then
    ok "$b turn EXECUTED INSIDE sandbox (messages $BEFORE -> $AFTER)"
  else
    no "$b turn executed inside sandbox" "messages $BEFORE -> $AFTER (no increase)"
  fi
done

echo "=============================================="
echo "9. LIVE: agent-initiated bot-to-bot messaging"
echo "=============================================="
mapfile -t _AG < <(ls -d ~/.hermes/profiles/*/ 2>/dev/null | xargs -n1 basename | grep -vx default)
PAIRS=""
for _s in "${_AG[@]}"; do for _d in "${_AG[@]}"; do [ "$_s" = "$_d" ] || PAIRS="$PAIRS $_s:$_d"; done; done
for pair in $PAIRS; do
  set -- $(echo "$pair" | tr ':' ' ')
  R=$(timeout 400 openshell sandbox exec -n bot-$1 --timeout 350 -- /bin/sh -c \
    "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes; cd /sandbox/.hermes/plugins/peer-messaging; \
     /sandbox/.hermes/hermes-agent/venv/bin/python -c \"
import sys,json; sys.path.insert(0,'.')
import tools as T
r=json.loads(T.message_teammate({'teammate':'$2','message':'Reply with only your sandbox name.'}))
print('REPLY:'+str(r.get('reply','ERR:'+str(r.get('error')))))
\"" 2>&1 | grep -a "REPLY:" | head -1)
  if echo "$R" | grep -qiE "bot-$2|$2"; then
    ok "$1 -> $2 messaging (got: $(echo "$R" | cut -c1-60))"
  else
    no "$1 -> $2 messaging" "$(echo "$R" | cut -c1-90)"
  fi
done

echo "=============================================="
echo "10. DESKTOP READINESS"
echo "=============================================="
chk "hermes on PATH for desktop probe" "$(bash -lc 'command -v hermes' >/dev/null 2>&1 && echo yes || echo no)" "yes"
chk "profiles enumerable" "$(hermes profile list 2>/dev/null | grep -cE '^\s+(alpha|beta)\s')" "2"
STALE=$(ls ~/.hermes/desktop-ssh/*/backend.lock.json 2>/dev/null | while read -r f; do
  PID=$(python3 -c "import json;print(json.load(open('$f')).get('pid'))" 2>/dev/null)
  ps -p "$PID" >/dev/null 2>&1 || echo stale
done | grep -c stale)
chk "no stale desktop backend locks" "${STALE:-0}" "0"


echo "=============================================="
echo "11. NEMOCLAW RECIPES (read-only)"
echo "=============================================="
# Deep Research Worker (beta's research backend)
chk "deep-research worker container" "$(docker inspect deep-research-worker --format '{{.State.Status}}' 2>/dev/null || echo missing)" "running"
chk "worker health on bridge" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${BRIDGE}:9050/health)" "200"
chk "deep-research CLI in bot-beta" "$(timeout 90 openshell sandbox exec -n bot-beta --timeout 70 -- /bin/sh -c 'test -x /sandbox/bin/deep-research && echo yes || echo no' 2>/dev/null | grep -v 'profile: Permission' | tr -d ' \r\n')" "yes"

# Chief of Staff host services (alpha's data sources)
for c in extras-postgres-1 extras-postgrest-1; do
  chk "COS $c" "$(docker inspect $c --format '{{.State.Status}}' 2>/dev/null || echo missing)" "running"
done
chk "ETL mirror on bridge" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://${BRIDGE}:3100/)" "200"
chk "COS skills in bot-alpha" "$(timeout 90 openshell sandbox exec -n bot-alpha --timeout 70 -- /bin/sh -c 'ls /sandbox/.hermes/skills/nemoclaw-cos 2>/dev/null | wc -l' 2>/dev/null | grep -v 'profile: Permission' | tr -d ' \r\n')" "7"

echo "=============================================="
echo "12. READ-ONLY ENFORCEMENT (must stay read-only)"
echo "=============================================="
GHTOK=$(grep '^GITHUB_TOKEN=' ~/nemoclaw-community/examples/recipes/nvidia/developer-community-chief-of-staff/.env 2>/dev/null | cut -d= -f2-)
RO=$(timeout 200 openshell sandbox exec -n bot-alpha --timeout 170 -- /bin/sh -c "
curl -s -o /dev/null -w 'R%{http_code} ' --max-time 15 -H 'Authorization: Bearer ***' https://api.github.com/repos/NVIDIA/OpenShell
curl -s -o /dev/null -w 'W%{http_code}' --max-time 15 -X POST -H 'Authorization: Bearer ***' -d '{}' https://api.github.com/repos/NVIDIA/OpenShell/issues
" 2>/dev/null | grep -v 'profile: Permission' | tr -d '\r\n')
case "$RO" in
  *R200*) ok "GitHub read allowed (200)";;
  *) no "GitHub read allowed" "$RO";;
esac
case "$RO" in
  *W200*|*W201*) no "GitHub write BLOCKED" "write succeeded: $RO";;
  *) ok "GitHub write blocked (not 2xx): ${RO##*W}";;
esac


echo "=============================================="
echo "13. HANDOFF PROOF (secret only the teammate can see)"
echo "=============================================="
# Echo-proof: plant a random secret inside bot-beta, then require alpha to
# retrieve it. Asking for a fact from the SOUL (sandbox name, GPU) is NOT proof —
# the agent answers from its prompt with 0 tool calls.
# Two handoffs so a third agent is genuinely exercised: alpha<-beta and gamma<-alpha
SECRET="ZEBRA-$(shuf -i 10000-99999 -n1)"
timeout 120 openshell sandbox exec -n bot-beta --timeout 90 -- /bin/sh -c \
  "echo $SECRET > /sandbox/secret.txt" >/dev/null 2>&1
OUT=$(timeout 500 openshell sandbox exec -n bot-alpha --timeout 450 -- /bin/sh -c \
  "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
   /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main chat -q \
   'Use message_teammate to ask beta to read /sandbox/secret.txt and return its contents. Report the exact string.'" 2>&1 \
  | grep -v 'profile: Permission')
if echo "$OUT" | grep -q "$SECRET"; then
  ok "alpha retrieved beta-only secret ($SECRET)"
else
  no "alpha retrieved beta-only secret" "expected $SECRET"
fi
CALLS=$(echo "$OUT" | grep -aoE '[0-9]+ tool calls' | head -1 | grep -oE '^[0-9]+')
if [ "${CALLS:-0}" -gt 0 ]; then
  ok "handoff used real tool calls (${CALLS})"
else
  no "handoff used real tool calls" "0 tool calls = echoed, not fetched"
fi

# gamma must be able to fetch a secret only alpha can see
SEC2="LYNX-$(shuf -i 10000-99999 -n1)"
timeout 120 openshell sandbox exec -n bot-alpha --timeout 90 -- /bin/sh -c \
  "echo $SEC2 > /sandbox/secret.txt" >/dev/null 2>&1
OUT2=$(timeout 500 openshell sandbox exec -n bot-gamma --timeout 450 -- /bin/sh -c \
  "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
   /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main chat -q \
   'Use message_teammate to ask alpha to read /sandbox/secret.txt and return its contents. Report the exact string.'" 2>&1 \
  | grep -v 'profile: Permission')
if echo "$OUT2" | grep -q "$SEC2"; then
  ok "gamma retrieved alpha-only secret ($SEC2)"
else
  no "gamma retrieved alpha-only secret" "expected $SEC2"
fi


echo "=============================================="
echo "14. TAVILY WEB SEARCH (search-only)"
echo "=============================================="
for b in alpha beta; do   # gamma has no tavily provider by design
  R=$(timeout 200 openshell sandbox exec -n bot-$b --timeout 170 -- /bin/sh -c "
k=\$(grep '^TAVILY_API_KEY=' /sandbox/.hermes/.env | cut -d= -f2-)
curl -s -o /dev/null -w 'S%{http_code} ' --max-time 20 -X POST https://api.tavily.com/search \
  -H 'Content-Type: application/json' -H \"Authorization: Bearer ***" -d '{\"query\":\"test\",\"max_results\":1}'
curl -s -o /dev/null -w 'X%{http_code}' --max-time 20 -X POST https://api.tavily.com/extract \
  -H 'Content-Type: application/json' -H \"Authorization: Bearer ***" -d '{\"urls\":[\"https://example.com\"]}'
" 2>/dev/null | grep -v 'profile: Permission' | tr -d '\r\n')
  case "$R" in *S200*) ok "$b tavily search authenticated (200)";; *) no "$b tavily search" "$R";; esac
  case "$R" in *X200*) no "$b tavily /extract BLOCKED" "extract allowed - policy hole";; *) ok "$b tavily /extract blocked (search-only)";; esac
done


echo "=============================================="
echo "15. HOST GATEWAYS (desktop roster visibility)"
echo "=============================================="
# An agent can answer 200 on the bridge and still be INVISIBLE in the desktop:
# the roster enumerates profiles reporting `running`, which requires a HOST-side
# gateway (separate from the in-sandbox one). gateway_running needs an active
# gateway.lock AND a gateway.pid whose start_time matches the live process, so
# ask hermes rather than testing kill -0 on the pid file.
for a in $(ls -d ~/.hermes/profiles/*/ 2>/dev/null | xargs -n1 basename | grep -vx default); do
  st=$(hermes profile list 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' | awk -v n="$a" '$1==n{print $3}')
  chk "$a profile reports running" "${st:-missing}" "running"
  # a gateway.pid alone is not proof, but its ABSENCE is proof of no host gateway
  [ -f "$HOME/.hermes/profiles/$a/gateway.pid" ] \
    && ok "$a has gateway.pid" \
    || no "$a has gateway.pid" "no host gateway ever started"
done

echo "=============================================="
echo "SUMMARY: $pass passed, $fail failed"
echo "=============================================="
exit $fail
