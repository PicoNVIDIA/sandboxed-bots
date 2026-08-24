#!/bin/bash
# Verifies assets that must never break. Exit 0 = all good.
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got \"$2\" want \"$3\")"; fail=1; fi; }
for c in vllm-a vllm-b openshell-hermes-edd08f40-57c7-4c2a-acbe-509b1f4ef5a2; do
  st=$(docker inspect "$c" --format "{{.State.Status}}" 2>/dev/null || echo missing)
  chk "container $c" "$st" "running"
done
for p in 8001 8002; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:$p/v1/models")
  chk "vllm :$p" "$code" "200"
done
for p in 8377 8378; do
  n=$(ss -lnt | grep -c ":$p ")
  chk "api_server :$p listening" "$n" "1"
done
sb=$(PATH=$HOME/.local/bin:$PATH openshell sandbox list 2>/dev/null | grep -c "^hermes ")
chk "pre-existing sandbox hermes" "$sb" "1"
exit $fail
