#!/usr/bin/env bash
# fix-desktop-backends.sh — repair the desktop backend layer.
#
# Symptom this fixes: one or more bots silently receive nothing in a group chat
# while others respond normally. `hermes profile list` shows every profile
# `running` and every api_server returns 200, so nothing looks broken — but an
# orphaned backend from a previous app session is still holding the lock, and the
# app routes to it instead of spawning a fresh one.
#
# The tell is backend UPTIME, not agent health: an orphan is much older than its
# siblings (observed 1h23m vs ~8m).
#
# Safe: touches only ~/.hermes/desktop-ssh/*/backend.lock.json and the backend
# processes they name. Never touches agents, sandboxes, engines, or forwards.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

# An orphan is this many seconds older than the newest backend.
DRIFT="${DRIFT:-1800}"

inspect() {
  for f in "$HOME"/.hermes/desktop-ssh/*/backend.lock.json; do
    [ -f "$f" ] || continue
    python3 - "$f" <<'PY'
import json, os, sys, subprocess
f = sys.argv[1]
try:
    d = json.load(open(f))
except Exception:
    print(f"?\t?\t0\t{f}"); raise SystemExit
pid = d.get("pid"); prof = d.get("profile") or "(default)"
alive = pid is not None and os.path.exists(f"/proc/{pid}")
secs = 0
if alive:
    out = subprocess.run(["ps", "-o", "etimes=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    secs = int(out) if out.isdigit() else 0
print(f"{prof}\t{pid}\t{secs}\t{f}\t{'alive' if alive else 'dead'}")
PY
  done
}

echo "==> current desktop backends"
mapfile -t rows < <(inspect)
newest=0
for r in "${rows[@]}"; do
  IFS=$'\t' read -r prof pid secs f state <<<"$r"
  printf "  %-10s pid=%-9s up=%-7s %s\n" "$prof" "$pid" "${secs}s" "$state"
  [ "$state" = alive ] && [ "$secs" -gt 0 ] && [ "$secs" -lt 100000 ] && \
    { [ "$newest" -eq 0 ] || [ "$secs" -lt "$newest" ]; } && newest="$secs"
done

echo "==> repairing"
fixed=0
for r in "${rows[@]}"; do
  IFS=$'\t' read -r prof pid secs f state <<<"$r"
  if [ "$state" = dead ]; then
    echo "  dead lock       $prof -> cleared (blocks respawn)"
    mv "$f" "$f.stale" 2>/dev/null && fixed=$((fixed+1))
  elif [ "$newest" -gt 0 ] && [ $((secs - newest)) -gt "$DRIFT" ]; then
    echo "  orphan  $prof pid=$pid up=${secs}s (newest ${newest}s) -> stopping"
    kill "$pid" 2>/dev/null; sleep 3
    [ -e "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
    mv "$f" "$f.stale" 2>/dev/null
    fixed=$((fixed+1))
  fi
done
[ "$fixed" -eq 0 ] && echo "  nothing to repair"

echo "==> remaining backends"
inspect | awk -F'\t' '{printf "  %-10s pid=%-9s up=%-7s %s\n", $1, $2, $3"s", $5}'

echo "==> agents (unaffected by backend repair)"
hermes profile list 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' \
  | awk 'NR>2 && $1!="" && $1!~/^[-─]/ {printf "  %-10s %s\n", $1, $3}'

cat <<'EOF'

Next: restart the Hermes desktop app. Any profile whose backend was stopped gets
a fresh one on launch; the others keep theirs.
EOF
