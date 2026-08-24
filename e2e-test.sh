#!/bin/bash
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
  chk "bridge 172.18.0.1:$p" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://172.18.0.1:$p/v1/models)" "200"
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
  K=$(cat ~/poc-sandbox/secrets/$1.key 2>/dev/null)
  chk "$1 api_server authed" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $K" http://172.18.0.1:$2/v1/models)" "200"
  chk "$1 api_server rejects no-auth" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://172.18.0.1:$2/v1/models)" "401"
done
chk "gRPC forwards running" "$(pgrep -fc 'forward service')" "2"
chk "sandbox gateways running" "$(pgrep -fc 'sandbox exec -n bot-')" "2"

echo "=============================================="
echo "5. HOST PROFILE CONFIG (what desktop uses)"
echo "=============================================="
for pair in "alpha 8477" "beta 8478"; do
  set -- $pair
  chk "$1 base_url -> sandbox :$2" "$(grep -A8 '^model:' ~/.hermes/profiles/$1/config.yaml | grep -oE '172.18.0.1:[0-9]+' | head -1)" "172.18.0.1:$2"
  chk "$1 model id" "$(grep -A8 '^model:' ~/.hermes/profiles/$1/config.yaml | grep -oE 'default: [a-z0-9.-]+' | head -1 | awk '{print $2}')" "hermes-agent"
  chk "$1 max_tokens set" "$(grep -A8 '^model:' ~/.hermes/profiles/$1/config.yaml | grep -c 'max_tokens')" "1"
done

echo "=============================================="
echo "6. PEER-MESSAGING PLUGIN INSTALLED (4 places)"
echo "=============================================="
for b in alpha beta; do
  chk "host $b plugin files" "$(ls ~/.hermes/profiles/$b/plugins/peer-messaging/ 2>/dev/null | wc -l)" "4"
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
  '/sandbox/.hermes/hermes-agent/venv/bin/python -c "import sqlite3;print(list(sqlite3.connect(\"/sandbox/.hermes/state.db\").execute(\"select count(*) from sessions\"))[0][0])"' \
  2>/dev/null | grep -v "profile: Permission" | tr -d " \r\n"; }

for b in alpha beta; do
  BEFORE=$(CNT $b)
  OUT=$(timeout 300 hermes -p $b chat -q "Reply with exactly: ${b}-E2E-OK" 2>&1 | grep -aoE "${b}-E2E-OK" | head -1)
  AFTER=$(CNT $b)
  chk "$b replies via host profile" "$OUT" "${b}-E2E-OK"
  if [ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$AFTER" -gt "$BEFORE" ]; then
    ok "$b turn EXECUTED INSIDE sandbox (sessions $BEFORE -> $AFTER)"
  else
    no "$b turn executed inside sandbox" "sessions $BEFORE -> $AFTER (no increase)"
  fi
done

echo "=============================================="
echo "9. LIVE: agent-initiated bot-to-bot messaging"
echo "=============================================="
for pair in "alpha beta" "beta alpha"; do
  set -- $pair
  R=$(timeout 400 openshell sandbox exec -n bot-$1 --timeout 350 -- /bin/sh -c \
    "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes; cd /sandbox/.hermes/plugins/peer-messaging; \
     /sandbox/.hermes/hermes-agent/venv/bin/python -c \"
import sys,json; sys.path.insert(0,'.')
import tools as T
r=json.loads(T.message_teammate({'teammate':'$2','message':'Reply with only your sandbox name.'}))
print('REPLY:'+str(r.get('reply','ERR:'+str(r.get('error')))))
\"" 2>&1 | grep -a "REPLY:" | head -1)
  if echo "$R" | grep -q "bot-$2"; then
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
echo "SUMMARY: $pass passed, $fail failed"
echo "=============================================="
exit $fail
