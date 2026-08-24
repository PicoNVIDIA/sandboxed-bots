#!/bin/bash
# Bring up the full sandboxed-bot stack. Idempotent: safe to re-run.
export PATH=$HOME/.local/bin:$PATH
set -u

echo "[1/4] inference relays (host loopback vLLM -> openshell bridge)"
docker start relay-8001 relay-8002 >/dev/null 2>&1
for p in 18001 18002; do
  printf "      172.18.0.1:%s -> " $p
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 http://172.18.0.1:$p/v1/models
done

echo "[2/4] sandbox gateways (each bots api_server)"
for b in alpha beta; do
  if ! pgrep -f "sandbox exec -n bot-$b" >/dev/null 2>&1; then
    nohup setsid openshell sandbox exec -n bot-$b --timeout 0 -- /bin/sh -c \
      "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes; \
       /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run" \
      > ~/poc-logs/sbgw-$b.log 2>&1 < /dev/null &
    echo "      started bot-$b gateway"
  else
    echo "      bot-$b gateway already running"
  fi
done
sleep 45

echo "[3/4] gRPC forwards (sandbox api_server -> bridge)"
for pair in "alpha 8477" "beta 8478"; do
  set -- $pair
  if ! pgrep -f "forward service --target-port $2" >/dev/null 2>&1; then
    nohup setsid openshell forward service --target-port $2 --local 172.18.0.1:$2 bot-$1 \
      > ~/poc-logs/fwd-$1.log 2>&1 < /dev/null &
    echo "      forwarding bot-$1 :$2"
  else
    echo "      bot-$1 forward already running"
  fi
done
sleep 15

echo "[4/4] health"
for pair in "alpha 8477" "beta 8478"; do
  set -- $pair
  K=$(cat ~/poc-sandbox/secrets/$1.key)
  printf "      %s api_server -> " $1
  curl -s -o /dev/null -w "%{http_code} (200=ready)\n" --max-time 10 -H "Authorization: Bearer $K" http://172.18.0.1:$2/v1/models
done
echo
echo "Profiles route through sandboxes:"
for b in alpha beta; do printf "  %-6s " $b; grep -A6 "^model:" ~/.hermes/profiles/$b/config.yaml | grep base_url; done
