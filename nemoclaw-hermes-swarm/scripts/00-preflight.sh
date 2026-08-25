#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# 00-preflight.sh — verify every prerequisite BEFORE you spend time on a spawn.
# Fails loudly and tells you the fix. Read-only: changes nothing.
set -uo pipefail

pass=0; fail=0; warn=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; pass=$((pass+1)); }
bad()  { printf "  \033[31m✗\033[0m %s\n     → %s\n" "$1" "$2"; fail=$((fail+1)); }
note() { printf "  \033[33m!\033[0m %s\n     → %s\n" "$1" "$2"; warn=$((warn+1)); }

echo "NemoClaw Hermes Swarm — preflight"
echo

# ── config ──────────────────────────────────────────────────────────────────
echo "Configuration"
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
  ok ".env found"
  [[ -n "${INFERENCE_URL:-}" ]] \
    && ok "INFERENCE_URL is set" \
    || bad "INFERENCE_URL is empty" "set it in .env, e.g. http://172.18.0.1:18001/v1"
  [[ -n "${INFERENCE_MODEL:-}" ]] \
    && ok "INFERENCE_MODEL is set ($INFERENCE_MODEL)" \
    || bad "INFERENCE_MODEL is empty" "set the model name your endpoint serves"
else
  bad ".env not found" "cp .env.example .env, then edit it"
fi
echo

# ── docker ──────────────────────────────────────────────────────────────────
echo "Docker"
if command -v docker >/dev/null 2>&1; then
  ok "docker present ($(docker --version 2>/dev/null | cut -d, -f1))"
  docker info >/dev/null 2>&1 \
    && ok "docker daemon reachable" \
    || bad "cannot talk to the docker daemon" "start docker, or add yourself to the docker group"
else
  bad "docker not installed" "the OpenShell Docker compute driver requires it"
fi
echo

# ── openshell ───────────────────────────────────────────────────────────────
echo "OpenShell"
if command -v openshell >/dev/null 2>&1; then
  ok "openshell present ($(openshell --version 2>/dev/null | head -1))"
  gw=$(openshell gateway list 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' \
        | awk '/^\*/ {print $2; exit}')
  if [[ -n "$gw" ]]; then
    ok "active gateway: $gw"
  else
    bad "no active OpenShell gateway" \
        "start it, then re-run. On Debian/Ubuntu a headless host often needs:
       sudo loginctl enable-linger \$USER
       export XDG_RUNTIME_DIR=/run/user/\$(id -u)
       systemctl --user start openshell-gateway"
  fi
  # nemoclaw is optional but changes how policies are applied
  if command -v nemoclaw >/dev/null 2>&1; then
    ok "nemoclaw present ($(nemoclaw --version 2>/dev/null | head -1)) — policy edits will be ADDITIVE"
  else
    note "nemoclaw not found" \
         "without it, policy changes use 'openshell policy set', which REPLACES a
       sandbox's whole policy. Installing nemoclaw is strongly recommended."
  fi
else
  bad "openshell not installed" "see https://github.com/NVIDIA/OpenShell"
fi
echo

# ── hermes on the host ──────────────────────────────────────────────────────
echo "Hermes Agent (host)"
if command -v hermes >/dev/null 2>&1; then
  ok "hermes present ($(hermes --version 2>/dev/null | head -1))"
  # non-interactive SSH must find it too, or the desktop app cannot probe the host
  if bash -lc 'command -v hermes' >/dev/null 2>&1; then
    ok "hermes is on PATH for a login shell (desktop app can find it)"
  else
    note "hermes is not on PATH in a login shell" \
         "the desktop app probes with 'bash -lc command -v hermes'. Add
       export PATH=\$HOME/.local/bin:\$PATH to ~/.bash_profile"
  fi
else
  bad "hermes not installed on the host" "see https://hermes-agent.nousresearch.com"
fi
echo

# ── inference endpoint ──────────────────────────────────────────────────────
echo "Inference endpoint"
if [[ -n "${INFERENCE_URL:-}" ]]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
           ${INFERENCE_KEY:+-H "Authorization: Bearer $INFERENCE_KEY"} \
           "${INFERENCE_URL%/}/models" 2>/dev/null || echo 000)
  case "$code" in
    200) ok "endpoint answers 200 from the host" ;;
    401|403) bad "endpoint returned $code" "INFERENCE_KEY looks wrong" ;;
    000) bad "endpoint unreachable from the host" \
             "check INFERENCE_URL. NOTE: a sandbox cannot reach 127.0.0.1 on the
       host — if your server binds loopback, use scripts/01-build-image.sh's
       relay (see README 'The bridge, not loopback')" ;;
    *)   note "endpoint returned $code" "expected 200 from ${INFERENCE_URL%/}/models" ;;
  esac
else
  bad "cannot test the endpoint" "INFERENCE_URL is not set"
fi
echo

# ── the bridge ──────────────────────────────────────────────────────────────
echo "OpenShell bridge"
bridge=$(docker network inspect openshell-docker \
           --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)
if [[ -n "$bridge" ]]; then
  ok "openshell bridge gateway is $bridge (this is host.openshell.internal)"
  [[ "$bridge" == "172.17.0.1" ]] && note "that is the DEFAULT docker bridge" \
    "unusual; the OpenShell bridge is normally a separate network"
else
  note "could not determine the OpenShell bridge address" \
       "it is created on first sandbox launch; re-run after 01-build-image.sh"
fi
echo

printf "%d passed, %d failed, %d warnings\n" "$pass" "$fail" "$warn"
if [[ "$fail" -gt 0 ]]; then
  echo "Fix the ✗ items above before continuing."
  exit 1
fi
echo "Preflight clean — next: ./scripts/01-build-image.sh"
