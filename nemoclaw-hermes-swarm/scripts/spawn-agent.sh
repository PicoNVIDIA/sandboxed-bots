#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# spawn-agent.sh — add, list, or remove a sandboxed Hermes agent.
#
# Each agent gets: its own OpenShell sandbox, Hermes installed inside it, a role
# (SOUL.md), an api_server published on the OpenShell bridge, a host profile that
# routes to it, and a peer link to every existing agent in both directions.
#
# Usage:
#   ./spawn-agent.sh --name alpha --role "You are Alpha, a research assistant."
#   ./spawn-agent.sh --name beta  --role-file ./souls/critic.md
#   ./spawn-agent.sh --list
#   ./spawn-agent.sh --name alpha --destroy
#
# Configuration comes from .env (see .env.example). Every step is idempotent, so
# re-running for an existing agent repairs it rather than duplicating it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && { set -a; . "$HERE/.env"; set +a; }

export PATH="$HOME/.local/bin:$PATH"
SWARM_HOME="${SWARM_HOME:-$HERE}"
LOG_DIR="${LOG_DIR:-$HERE/logs}"
SECRETS_DIR="${SECRETS_DIR:-$HERE/secrets}"
POLICY_DIR="${POLICY_DIR:-$HERE/policies}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-hermes-swarm-sandbox:base}"
API_PORT_BASE="${API_PORT_BASE:-8477}"
SANDBOX_MEMORY="${SANDBOX_MEMORY:-8Gi}"
SANDBOX_CPU="${SANDBOX_CPU:-4}"
AGENT_MAX_TOKENS="${AGENT_MAX_TOKENS:-8192}"
AGENT_CONTEXT_LENGTH="${AGENT_CONTEXT_LENGTH:-65536}"
INFERENCE_URL="${INFERENCE_URL:-}"
INFERENCE_MODEL="${INFERENCE_MODEL:-}"
INFERENCE_KEY="${INFERENCE_KEY:-local-noauth}"

# Only used by the optional --new-engine path, which starts a local vLLM. This
# example assumes you already have an endpoint, so these are normally empty.
MODEL_PATH="${MODEL_PATH:-}"
MODEL_NAME="${MODEL_NAME:-$INFERENCE_MODEL}"

# The OpenShell docker bridge. This is what host.openshell.internal resolves to
# inside a sandbox, and it is NOT the default docker bridge (172.17.0.1).
BRIDGE="${BRIDGE:-$(docker network inspect openshell-docker \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo 172.18.0.1)}"

mkdir -p "$LOG_DIR" "$SECRETS_DIR" "$POLICY_DIR"

# Fail fast with a clear message rather than dying halfway through a spawn.
need_cfg() {
  local missing=()
  [[ -n "$INFERENCE_URL" ]]   || missing+=(INFERENCE_URL)
  [[ -n "$INFERENCE_MODEL" ]] || missing+=(INFERENCE_MODEL)
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '  \033[31mFAIL\033[0m missing required config: %s\n' "${missing[*]}" >&2
    printf '     → cp .env.example .env and edit it, then re-run\n' >&2
    exit 1
  fi
}

log()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
ok()   { printf "  \033[32mok\033[0m   %s\n" "$*"; }
warn() { printf "  \033[33mwarn\033[0m %s\n" "$*"; }
die()  { printf "  \033[31mFAIL\033[0m %s\n" "$*" >&2; exit 1; }

# ── discovery ───────────────────────────────────────────────────────────────
free_gpu() {
  # first GPU using <1GB — a 149GB model needs the whole card
  nvidia-smi --query-gpu=index,memory.used --format=csv,noheader \
    | awk -F', ' '{gsub(/ MiB/,"",$2); if ($2+0 < 1024) {print $1; exit}}'
}
port_free() { ! ss -lnt | grep -q ":$1\b"; }
next_port() {
  local p=$1
  while ! port_free "$p"; do p=$((p+1)); done
  echo "$p"
}
existing_agents() {
  # profiles whose model.base_url points at a sandbox api_server on the bridge
  local d n
  for d in "$HOME"/.hermes/profiles/*/; do
    n=$(basename "$d")
    [[ "$n" == "default" ]] && continue
    [[ -f "$d/config.yaml" ]] || continue
    if grep -Eq 'base_url:[[:space:]]*http://172\.18\.0\.1:8[0-9]+' "$d/config.yaml"; then
      echo "$n"
    fi
  done
}

usage() { sed -n '2,20p' "$0"; exit 0; }

NAME=""; ROLE=""; ROLE_FILE=""; RECIPE=""; SHARE=""; DESTROY=0; LIST=0; NEW_ENGINE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         NAME="$2"; shift 2;;
    --role)         ROLE="$2"; shift 2;;
    --role-file)    ROLE_FILE="$2"; shift 2;;
    --recipe)       RECIPE="$2"; shift 2;;
    --share-engine) SHARE="$2"; shift 2;;
    --new-engine)   NEW_ENGINE=1; shift;;
    --destroy)      DESTROY=1; shift;;
    --list)         LIST=1; shift;;
    -h|--help)      usage;;
    *) die "unknown flag: $1";;
  esac
done

# ── --list ──────────────────────────────────────────────────────────────────
if [[ $LIST -eq 1 ]]; then
  printf "%-10s %-14s %-6s %-8s %-8s %s\n" AGENT SANDBOX GPU INFER API PEERS
  set +e
  for a in $(existing_agents); do
    cfg="$HOME/.hermes/profiles/$a/config.yaml"
    api=$(grep -oE '172\.18\.0\.1:8[0-9]+' "$cfg" 2>/dev/null | head -1 | cut -d: -f2)
    # the engine may be a shared one; look up whichever vllm container serves it
    inf=$(grep -oE 'host\.openshell\.internal:1800[0-9]+|172\.18\.0\.1:1800[0-9]+' \
            "$HOME/.hermes/profiles/$a/config.yaml" 2>/dev/null | head -1 | cut -d: -f2)
    [[ -z "$inf" ]] && inf=$(openshell policy get "bot-$a" --full -o json 2>/dev/null \
            | grep -oE '"port": 1800[0-9]+' | head -1 | grep -oE '1800[0-9]+')
    gpu=$(docker inspect "vllm-$a" --format '{{range .HostConfig.DeviceRequests}}{{.DeviceIDs}}{{end}}' 2>/dev/null | tr -d '[]')
    [[ -z "$gpu" ]] && gpu="shared/—"
    phase=$(openshell sandbox list 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' | awk -v n="bot-$a" '$1==n{print $NF}')
    peers=$(hermes -p "$a" peer list 2>/dev/null | awk 'NF{printf "%s ", $1}')
    printf "%-10s %-14s %-9s %-8s %-8s %s\n" "$a" "bot-$a ${phase:-?}" "${gpu}" "${inf:-—}" "${api:-—}" "${peers:-none}"
  done
  set -e
  exit 0
fi

[[ -n "$NAME" ]] || die "need --name"
[[ $DESTROY -eq 1 ]] || need_cfg
[[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || die "name must be lowercase alnum/dash"

SB="bot-$NAME"

# ── --destroy ───────────────────────────────────────────────────────────────
if [[ $DESTROY -eq 1 ]]; then
  log "destroying agent $NAME (sandbox + engine + relays + profile)"
  # de-register from every peer first
  for a in $(existing_agents); do
    [[ "$a" == "$NAME" ]] && continue
    hermes -p "$a" peer remove "$NAME" >/dev/null 2>&1 && ok "$a un-peered $NAME"
  done
  pkill -f "profile $NAME serve" 2>/dev/null || true
  pkill -f "forward service .* $SB" 2>/dev/null || true
  # host-side gateway (leaves a stale gateway.pid/.lock if not stopped)
  if [[ -f "$HOME/.hermes/profiles/$NAME/gateway.pid" ]]; then
    kill "$(cat "$HOME/.hermes/profiles/$NAME/gateway.pid")" 2>/dev/null \
      && ok "host gateway stopped"
  fi
  pkill -f "hermes -p $NAME gateway run" 2>/dev/null || true
  # gateway.lock is the runtime lock gateway_running keys off; a leftover lock or
  # pid record blocks the next start for a re-created agent of the same name.
  rm -f "$HOME/.hermes/profiles/$NAME"/gateway.{pid,lock,sock} \
        "$HOME/.hermes/profiles/$NAME/gateway_state.json" 2>/dev/null || true
  openshell sandbox delete "$SB" >/dev/null 2>&1 && ok "sandbox deleted"
  for c in "vllm-$NAME" "relay-$NAME"; do
    docker rm -f "$c" >/dev/null 2>&1 && ok "container $c removed"
  done
  rm -rf "$HOME/.hermes/profiles/$NAME" && ok "profile removed"
  rm -f "$SECRETS_DIR/$NAME.key"
  ok "agent $NAME destroyed"
  exit 0
fi

# ── allocate ────────────────────────────────────────────────────────────────
log "allocating resources for '$NAME'"
# Idempotent: if this agent already has a profile, keep its existing api port
# instead of allocating a new one (re-running must not shift ports).
API_PORT=""
if [[ -f "$HOME/.hermes/profiles/$NAME/config.yaml" ]]; then
  API_PORT=$(grep -oE '172\.18\.0\.1:8[0-9]+' "$HOME/.hermes/profiles/$NAME/config.yaml" \
               2>/dev/null | head -1 | cut -d: -f2)
  [[ -n "$API_PORT" ]] && ok "reusing existing api_server port $API_PORT"
fi
if [[ -z "$API_PORT" ]]; then
  API_PORT=$(next_port "$API_PORT_BASE")
  ok "api_server port  $API_PORT"
fi
# reuse the stored key too, so peers stay valid across re-runs
if [[ -s "$SECRETS_DIR/$NAME.key" ]]; then
  KEY=$(cat "$SECRETS_DIR/$NAME.key")
  ok "reusing existing api key"
fi

# Engine: SHARE an existing one by default (agent-only spawn, no GPU, no ~11min
# model load). Only start a dedicated vLLM when --new-engine is passed.
if [[ $NEW_ENGINE -eq 1 ]]; then
  [[ -n "$MODEL_PATH" ]] || die "--new-engine needs MODEL_PATH set (path to your model weights)"
  GPU=$(free_gpu || true)
  [[ -n "$GPU" ]] || die "no free GPU for --new-engine (drop the flag to share)"
  VLLM_PORT=$(next_port 8003)
  INFER_PORT=$(next_port 18003)
  ok "NEW engine: GPU $GPU  vllm :$VLLM_PORT  bridge :$INFER_PORT (~11 min load)"
else
  # pick the named engine, else the first healthy existing one
  if [[ -n "$SHARE" ]]; then
    CAND="$SHARE"
  else
    # NB: `existing_agents | head -1` gets SIGPIPE and aborts under `pipefail`.
    # Collect into an array instead of piping.
    mapfile -t _cands < <(existing_agents)
    CAND="${_cands[0]:-}"
    [[ -n "$CAND" ]] || die "no existing agent to share an engine with — use --new-engine"
  fi
  # NB: a failing grep inside $( ) aborts the script under `set -e`; guard it.
  SRC_POL=$(openshell policy get "bot-$CAND" --full -o json 2>/dev/null \
             | grep -oE '"port": 1800[0-9]+' | head -1 | grep -oE '1800[0-9]+' || true)
  if [[ -z "$SRC_POL" ]]; then
    # fall back to the sibling profile's own base_url
    SRC_POL=$(grep -oE '1800[0-9]+' "$HOME/.hermes/profiles/$CAND/config.yaml" 2>/dev/null | head -1 || true)
  fi
  INFER_PORT="${SRC_POL:-}"
  [[ -n "$INFER_PORT" ]] || die "cannot resolve $CAND inference port"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
           "http://$BRIDGE:$INFER_PORT/v1/models" || true)
  [[ "$code" == "200" ]] || die "shared engine :$INFER_PORT not healthy (got $code)"
  GPU="shared:$CAND"
  ok "sharing $CAND engine on :$INFER_PORT — no new GPU, no model load"
fi

# ── 1. vLLM engine ──────────────────────────────────────────────────────────
if [[ $NEW_ENGINE -eq 1 ]]; then
  log "starting vLLM on GPU $GPU (first load ~11 min)"
  docker rm -f "vllm-$NAME" >/dev/null 2>&1 || true
  docker run -d --name "vllm-$NAME" --restart unless-stopped \
    --gpus "\"device=$GPU\"" --ipc=host \
    -v "$MODEL_PATH:/models" \
    -p "127.0.0.1:$VLLM_PORT:8000" \
    vllm/vllm-openai:latest \
    --model "$MODEL_PATH/models--deepseek-ai--DeepSeek-V4-Flash/snapshots"/* \
    --served-model-name "$MODEL_NAME" \
    --max-model-len 65536 --kv-cache-dtype fp8 \
    --gpu-memory-utilization 0.95 --tool-call-parser deepseek_v4 \
    >/dev/null || die "vLLM failed to start"
  ok "vllm-$NAME starting"

  docker rm -f "relay-$NAME" >/dev/null 2>&1 || true
  docker run -d --name "relay-$NAME" --network host --restart unless-stopped \
    bot-relay:base \
    socat "TCP-LISTEN:$INFER_PORT,fork,reuseaddr,bind=$BRIDGE" "TCP:127.0.0.1:$VLLM_PORT" \
    >/dev/null && ok "relay :$INFER_PORT -> :$VLLM_PORT"
fi

# ── 2. policy ───────────────────────────────────────────────────────────────
log "writing policy"
mkdir -p "$SECRETS_DIR"
POL="$POLICY_DIR/policy-$SB.yaml"
python3 - "$POL" "$INFER_PORT" <<'PY'
import sys, yaml
pol, infer = sys.argv[1], int(sys.argv[2])
BINS = [{"path": p} for p in (
    "/usr/bin/python3", "/usr/bin/python3.11", "/usr/bin/curl", "/usr/bin/git",
    "/sandbox/.hermes/hermes-agent/venv/bin/python",
    "/sandbox/.hermes/hermes-agent/venv/bin/*",
    "/sandbox/.hermes/bin/uv", "/sandbox/.hermes/bin/*",
    "/sandbox/.hermes/node/bin/node", "/sandbox/.hermes/node/bin/npm",
    "/bin/sh", "/bin/bash")]
INSTALL = ["hermes-agent.nousresearch.com","github.com","codeload.github.com",
  "objects.githubusercontent.com","raw.githubusercontent.com","pypi.org",
  "files.pythonhosted.org","astral.sh","releases.astral.sh","registry.npmjs.org",
  "nodejs.org","api.github.com","deb.debian.org","archive.ubuntu.com",
  "security.ubuntu.com"]
doc = {
  "version": 3,
  "filesystem_policy": {
    "include_workdir": True,
    "read_only": ["/usr","/lib","/etc","/dev/urandom"],
    "read_write": ["/sandbox","/sandbox/.hermes","/tmp","/var/tmp",
                   "/dev/null","/dev/pts","/home/sandbox"],
  },
  "landlock": {"compatibility": "best_effort"},
  "network_policies": {
    "host-inference": {
      "name": "host-inference",
      "endpoints": [
        {"host": "host.openshell.internal", "port": infer, "tls": "skip"},
        {"host": "172.18.0.1", "port": infer, "tls": "skip"},
      ],
      "binaries": BINS,
    },
    "install": {
      "name": "install",
      "endpoints": [{"host": h, "port": 443, "tls": "skip"} for h in INSTALL],
      "binaries": BINS,
    },
  },
}
yaml.safe_dump(doc, open(pol, "w"), sort_keys=False)
print("policy written")
PY
ok "$POL"

# ── 3. sandbox ──────────────────────────────────────────────────────────────
log "creating sandbox $SB (can take ~2 min)"
if openshell sandbox list 2>/dev/null | grep -qE "^\s*$SB\s"; then
  warn "$SB already exists — reusing"
else
  openshell sandbox create --name "$SB" --from $SANDBOX_IMAGE \
    --policy "$POL" --memory 8Gi --cpu 4 >/dev/null 2>&1 || true
fi
for i in $(seq 1 24); do
  phase=$(openshell sandbox list 2>/dev/null | awk -v n="$SB" '$1==n{print $NF}' | sed -r 's/\x1B\[[0-9;]*[mK]//g')
  [[ "$phase" == "Ready" ]] && { ok "$SB Ready"; break; }
  sleep 10
done
[[ "${phase:-}" == "Ready" ]] || die "$SB never reached Ready (phase=${phase:-none})"

sbexec() { timeout "${2:-400}" openshell sandbox exec -n "$SB" --timeout "$((${2:-400}-40))" -- \
             /bin/sh -c "$1" 2>&1 | grep -v "profile: Permission"; }

# ── 4. Hermes inside the sandbox ────────────────────────────────────────────
log "installing Hermes in $SB"

# Seed from an already-built sandbox when one exists.
#
# Why: the installer clones from GitHub, and every sandbox egresses through the
# OpenShell proxy, so they share one apparent source address. Creating two or
# three agents back to back reliably trips GitHub's unauthenticated rate limit:
#   remote: This request was rate-limited due to too many requests.
#   fatal: ... returned error: 429   ->   "✗ Failed to clone repository"
# Copying the installed tree sidesteps the clone entirely and is much faster.
seed_from_sibling() {
  local src_sb="" a
  for a in $(existing_agents); do
    [[ "$a" == "$NAME" ]] && continue
    if timeout 90 openshell sandbox exec -n "bot-$a" --timeout 70 -- /bin/sh -c \
         'test -x /sandbox/.hermes/hermes-agent/venv/bin/python && echo yes' 2>/dev/null \
         | grep -q yes; then
      src_sb="bot-$a"; break
    fi
  done
  [[ -n "$src_sb" ]] || return 1

  local src_ctr dst_ctr stage
  src_ctr=$(docker ps --format '{{.Names}}' | grep "^openshell-${src_sb}-" | head -1)
  dst_ctr=$(docker ps --format '{{.Names}}' | grep "^openshell-${SB}-" | head -1)
  [[ -n "$src_ctr" && -n "$dst_ctr" ]] || return 1

  log "seeding Hermes from $src_sb (avoids a GitHub clone)"
  timeout 600 openshell sandbox exec -n "$src_sb" --timeout 550 -- /bin/sh -c \
    'cd /sandbox && tar czf /tmp/hermes-seed.tgz .hermes/hermes-agent .hermes/bin .hermes/node 2>/dev/null; echo done' \
    >/dev/null 2>&1 || return 1

  stage=$(mktemp -d)
  docker cp "$src_ctr:/tmp/hermes-seed.tgz" "$stage/seed.tgz" >/dev/null 2>&1 || { rm -rf "$stage"; return 1; }
  docker cp "$stage/seed.tgz" "$dst_ctr:/tmp/hermes-seed.tgz" >/dev/null 2>&1 || { rm -rf "$stage"; return 1; }
  rm -rf "$stage"

  timeout 600 openshell sandbox exec -n "$SB" --timeout 550 -- /bin/sh -c \
    'cd /sandbox && mkdir -p .hermes && tar xzf /tmp/hermes-seed.tgz -C /sandbox
     test -x /sandbox/.hermes/hermes-agent/venv/bin/python && echo SEED-OK' 2>/dev/null \
    | grep -q SEED-OK
}

if sbexec 'test -x /sandbox/.hermes/hermes-agent/venv/bin/python && echo yes' 120 | grep -q yes; then
  ok "Hermes already installed"
elif seed_from_sibling; then
  ok "Hermes seeded from an existing sandbox"
else
  sbexec 'export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
          cd /sandbox
          curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash >/sandbox/install.log 2>&1
          test -x /sandbox/.hermes/hermes-agent/venv/bin/python && echo INSTALL-OK || tail -5 /sandbox/install.log' 1700 | tail -3
  if ! sbexec 'test -x /sandbox/.hermes/hermes-agent/venv/bin/python && echo yes' 120 | grep -q yes; then
    # Surface the real cause instead of a generic failure — 429 is the common one.
    if sbexec 'grep -qi "rate-limited\|error: 429" /sandbox/install.log && echo ratelimited' 120 | grep -q ratelimited; then
      die "Hermes install hit a GitHub rate limit (429) in $SB.
     → wait a few minutes and re-run this command, or create the first agent,
       let it finish, then create the rest so they can be seeded from it."
    fi
    die "Hermes install failed — inspect /sandbox/install.log in $SB"
  fi
  ok "Hermes installed"
fi

# ── 5. model + api_server + SOUL ────────────────────────────────────────────
log "configuring agent"
# Reuse the stored key if we already have one: regenerating it invalidates every
# peer registration that other agents hold for us.
if [[ -z "${KEY:-}" && -s "$SECRETS_DIR/$NAME.key" ]]; then
  KEY=$(cat "$SECRETS_DIR/$NAME.key")
fi
KEY="${KEY:-$(openssl rand -hex 32)}"
printf '%s\n' "$KEY" > "$SECRETS_DIR/$NAME.key"; chmod 600 "$SECRETS_DIR/$NAME.key"

# SOUL: from --role, --role-file, or a recipe README
SOUL_BODY=""
if [[ -n "$ROLE_FILE" ]]; then
  SOUL_BODY=$(cat "$ROLE_FILE")
elif [[ -n "$RECIPE" ]]; then
  RD="$HOME/nemoclaw-community/examples/recipes/$RECIPE"
  [[ -f "$RD/README.md" ]] || die "recipe not found: $RD/README.md"
  SOUL_BODY="# ${NAME^} — $(basename "$RECIPE")

Role derived from the NemoClaw recipe \`$RECIPE\`.

$(sed -n '/^## /,$p' "$RD/README.md" | head -60)"
  ok "role seeded from recipe $RECIPE"
elif [[ -n "$ROLE" ]]; then
  SOUL_BODY="# ${NAME^}

$ROLE"
else
  die "need --role, --role-file, or --recipe"
fi

SOUL="$SOUL_BODY

## Runtime
You run INSIDE an NVIDIA OpenShell sandbox named $SB (kernel-enforced
isolation). Your inference endpoint is host.openshell.internal:$INFER_PORT.
Your egress is deny-by-default: only what your policy allows is reachable.
Report a blocked source as a finding rather than guessing around it.

## Hard rules
- Never invent a source, citation, URL, number, or quote. Label inference as
  inference and say when you could not verify something.
- Never cite an issue/PR number, title, or state you did not fetch this session.
- If a tool cannot reach what you need, name the blocker plainly."

B_SOUL=$(printf '%s' "$SOUL" | base64 -w0)
sbexec "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
H=/sandbox/.hermes/hermes-agent/venv/bin/python
\$H -m hermes_cli.main config set model.provider custom            >/dev/null 2>&1
\$H -m hermes_cli.main config set model.default $MODEL_NAME        >/dev/null 2>&1
\$H -m hermes_cli.main config set model.base_url http://host.openshell.internal:$INFER_PORT/v1 >/dev/null 2>&1
\$H -m hermes_cli.main config set model.api_key local-noauth       >/dev/null 2>&1
\$H -m hermes_cli.main config set model.max_tokens 8192            >/dev/null 2>&1
\$H -m hermes_cli.main config set model.context_length 65536       >/dev/null 2>&1
\$H -m hermes_cli.main config set gateway.platforms.api_server.enabled true >/dev/null 2>&1
\$H -m hermes_cli.main config set gateway.platforms.api_server.extra.port $API_PORT >/dev/null 2>&1
sed -i '/^API_SERVER_KEY=/d' /sandbox/.hermes/.env 2>/dev/null || true
echo API_SERVER_KEY=$KEY >> /sandbox/.hermes/.env
chmod 600 /sandbox/.hermes/.env
echo '$B_SOUL' | base64 -d > /sandbox/.hermes/SOUL.md
echo CONFIGURED" 400 | tail -1
ok "model -> :$INFER_PORT, api_server :$API_PORT, SOUL written"

# ── 6. gateway + forward ────────────────────────────────────────────────────
log "starting in-sandbox gateway"
# A gateway already running from a previous attempt holds the OLD API_SERVER_KEY in
# memory, so a re-run that regenerates the key gets 401 until it is restarted.
# Stop any existing one first — this is what makes re-runs actually idempotent.
timeout 120 openshell sandbox exec -n "$SB" --timeout 90 -- /bin/sh -c \
  'export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
   /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway stop >/dev/null 2>&1 || true
   rm -f /sandbox/.hermes/gateway.pid /sandbox/.hermes/gateway.lock' >/dev/null 2>&1 || true
mkdir -p "$LOG_DIR"
pkill -f "sandbox exec -n $SB .* gateway run" 2>/dev/null || true
nohup setsid openshell sandbox exec -n "$SB" --timeout 0 -- /bin/sh -c \
  "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
   /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run" \
  > "$LOG_DIR/sbgw-$NAME.log" 2>&1 < /dev/null &
sleep 25
pkill -f "forward service --target-port $API_PORT" 2>/dev/null || true
nohup setsid openshell forward service --target-port "$API_PORT" \
  --local "$BRIDGE:$API_PORT" "$SB" > "$LOG_DIR/fwd-$NAME.log" 2>&1 < /dev/null &
sleep 6
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
  -H "Authorization: Bearer ***" "http://$BRIDGE:$API_PORT/v1/models")
[[ "$code" == "200" ]] && ok "api_server reachable on bridge (200)" || warn "api_server returned $code"

# ── 7. host profile ─────────────────────────────────────────────────────────
log "creating host profile '$NAME'"
hermes profile create "$NAME" >/dev/null 2>&1 || true
hermes -p "$NAME" config set model.provider custom      >/dev/null 2>&1
hermes -p "$NAME" config set model.default hermes-agent >/dev/null 2>&1
hermes -p "$NAME" config set model.base_url "http://$BRIDGE:$API_PORT/v1" >/dev/null 2>&1
hermes -p "$NAME" config set model.api_key "$KEY"       >/dev/null 2>&1
hermes -p "$NAME" config set model.max_tokens 8192      >/dev/null 2>&1
hermes -p "$NAME" config set model.context_length 65536 >/dev/null 2>&1
printf '%s' "$SOUL" > "$HOME/.hermes/profiles/$NAME/SOUL.md"
ok "profile routes through $SB"

# HOST-side gateway. Without this the profile shows `stopped` in
# `hermes profile list` and NEVER appears in the desktop Bots roster, even
# though the in-sandbox gateway is healthy and the api_server answers 200.
# It must be a login shell + setsid or it dies with this SSH session.
# Authoritative check: `hermes profile list` computes gateway_running from the
# gateway.lock runtime lock PLUS a gateway.pid whose recorded start_time matches
# the live process (a PID-reuse guard). A pid file alone can be stale, so ask
# Hermes rather than testing kill -0 ourselves.
prof_status() {
  hermes profile list 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' \
    | awk -v n="$1" '$1==n{print $3}'
}
if [[ "$(prof_status "$NAME")" == "running" ]]; then
  ok "host gateway already running"
else
  setsid hermes -p "$NAME" gateway run \
    > "$LOG_DIR/host-gw-$NAME.log" 2>&1 < /dev/null &
  sleep 25
  status=$(prof_status "$NAME")
  [[ "$status" == "running" ]] && ok "host gateway up ($NAME shows running)" \
    || warn "$NAME still shows '${status:-?}' — desktop roster may not list it"
fi

# ── 8. peer mesh: wire the new agent to every existing one, both ways ───────
log "wiring peer mesh"
for a in $(existing_agents); do
  [[ "$a" == "$NAME" ]] && continue
  a_cfg="$HOME/.hermes/profiles/$a/config.yaml"
  a_port=$(grep -oE '172\.18\.0\.1:8[0-9]+' "$a_cfg" | head -1 | cut -d: -f2)
  a_key=$(cat "$SECRETS_DIR/$a.key" 2>/dev/null || true)
  [[ -n "$a_port" && -n "$a_key" ]] || { warn "skip $a (no port/key)"; continue; }

  # host profiles (what the desktop uses)
  hermes -p "$NAME" peer add "$a" --url "http://$BRIDGE:$a_port" --key "$a_key" \
    --note "$a" >/dev/null 2>&1
  hermes -p "$a" peer add "$NAME" --url "http://$BRIDGE:$API_PORT" --key "$KEY" \
    --note "$NAME" >/dev/null 2>&1

  # IN-SANDBOX peers — the agent loop runs here, so message_teammate reads THIS
  # config. Registering only on the host gives "Unknown teammate".
  sbexec "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
          H=/sandbox/.hermes/hermes-agent/venv/bin/python
          \$H -m hermes_cli.main peer add $a --url http://host.openshell.internal:$a_port --key $a_key --note '$a' >/dev/null 2>&1
          echo done" 300 >/dev/null
  timeout 300 openshell sandbox exec -n "bot-$a" --timeout 260 -- /bin/sh -c \
    "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
     H=/sandbox/.hermes/hermes-agent/venv/bin/python
     \$H -m hermes_cli.main peer add $NAME --url http://host.openshell.internal:$API_PORT --key $KEY --note '$NAME' >/dev/null 2>&1
     echo done" >/dev/null 2>&1
  ok "in-sandbox peers registered ($NAME <-> $a)"

  # allow each direction through the sandbox egress policy
  for pair in "$SB|$a|$a_port" "bot-$a|$NAME|$API_PORT"; do
    IFS='|' read -r sb peer port <<<"$pair"
    tmp="$POLICY_DIR/.peer-$sb-$peer.yaml"
    python3 - "$tmp" "$peer" "$port" <<'PYPOL'
import sys, yaml
out, peer, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
doc = {
  "preset": {"name": f"peer-{peer}",
             "description": f"Reach teammate {peer} api_server"},
  "network_policies": {
    f"peer-{peer}": {
      "name": f"peer-{peer}",
      "endpoints": [
        {"host": "host.openshell.internal", "port": port, "tls": "skip"},
        {"host": "172.18.0.1", "port": port, "tls": "skip"},
      ],
      "binaries": [{"path": p} for p in (
        "/sandbox/.hermes/hermes-agent/venv/bin/python",
        "/usr/bin/python3", "/usr/bin/python3.11",
        "/usr/bin/curl", "/bin/sh", "/bin/bash")],
    }
  },
}
yaml.safe_dump(doc, open(out, "w"), sort_keys=False)
PYPOL
    if nemoclaw "$sb" policy-add --from-file "$tmp" --yes >/dev/null 2>&1; then
      ok "$sb may reach $peer:$port"
    else
      warn "$sb policy-add for $peer failed (see $tmp)"
    fi
    rm -f "$tmp"
  done
done

# ── 9. peer-messaging plugin ────────────────────────────────────────────────
if [[ -d "$SWARM_HOME/plugins/peer-messaging" ]]; then
  log "installing peer-messaging plugin"
  # Ship the whole plugin as ONE tarball. Writing files individually in a loop
  # dropped everything after the first file (each sbexec is a fresh shell and
  # large base64 args hit the 32KB exec limit).
  tar czf /tmp/peer-plugin.tgz -C "$SWARM_HOME/plugins" peer-messaging
  B=$(base64 -w0 /tmp/peer-plugin.tgz)
  sbexec "mkdir -p /sandbox/.hermes/plugins
          echo $B | base64 -d > /tmp/pp.tgz
          tar xzf /tmp/pp.tgz -C /tmp
          rm -rf /sandbox/.hermes/plugins/peer-messaging
          mv /tmp/peer-messaging /sandbox/.hermes/plugins/peer-messaging
          rm -rf /sandbox/.hermes/plugins/peer-messaging/__pycache__ /tmp/pp.tgz
          ls /sandbox/.hermes/plugins/peer-messaging | wc -l" 300 | tail -1 >/dev/null
  sbexec "export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
          /sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main plugins enable peer-messaging >/dev/null 2>&1
          echo PLUGIN-OK" 300 | tail -1 >/dev/null
  mkdir -p "$HOME/.hermes/profiles/$NAME/plugins"
  cp -r "$SWARM_HOME/plugins/peer-messaging" "$HOME/.hermes/profiles/$NAME/plugins/peer-messaging"
  hermes -p "$NAME" plugins enable peer-messaging >/dev/null 2>&1
  ok "message_teammate available"
fi

# ── 10. verify ──────────────────────────────────────────────────────────────
log "verifying"
resp=$(timeout 400 hermes -p "$NAME" chat -q "Reply with exactly: $NAME-SPAWN-OK" 2>&1 \
        | grep -aoE "$NAME-SPAWN-OK" | head -1)
[[ "$resp" == "$NAME-SPAWN-OK" ]] && ok "agent answers through its sandbox" \
  || warn "no clean reply yet (engine may still be warming — retry in a few minutes)"

[[ -x "$SWARM_HOME/scripts/verify.sh" ]] && { "$SWARM_HOME/scripts/verify.sh" >/dev/null 2>&1 \
  && ok "existing agents unaffected (verify.sh green)" \
  || warn "verify.sh reported a problem — check it"; }

cat <<EOF

  agent    $NAME
  sandbox  $SB      GPU $GPU
  infer    :$INFER_PORT
  api      :$API_PORT
  peers    $(hermes -p "$NAME" peer list 2>/dev/null | awk '{printf "%s ", $1}')

  try it:  hermes -p $NAME chat -q "who are you?"
  desktop: restart Hermes, then @$NAME appears in the Bots roster
EOF
