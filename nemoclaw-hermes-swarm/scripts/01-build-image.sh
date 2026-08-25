#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# 01-build-image.sh — build the sandbox base image (and optionally the relay).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && { set -a; . "$HERE/.env"; set +a; }

SANDBOX_IMAGE="${SANDBOX_IMAGE:-hermes-swarm-sandbox:base}"
RELAY_IMAGE="${RELAY_IMAGE:-hermes-swarm-relay:base}"

echo "==> building $SANDBOX_IMAGE"
docker build -f "$HERE/Dockerfile.sandbox" -t "$SANDBOX_IMAGE" "$HERE"
echo "  ok  $SANDBOX_IMAGE"

# The relay is only needed when a host service an agent must reach is bound to
# 127.0.0.1: a sandbox has its own netns and cannot see host loopback.
echo "==> building $RELAY_IMAGE (used only for loopback-bound endpoints)"
docker build -f "$HERE/Dockerfile.relay" -t "$RELAY_IMAGE" "$HERE"
echo "  ok  $RELAY_IMAGE"

BRIDGE="$(docker network inspect openshell-docker \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"

cat <<EOF

Images built.

  sandbox: $SANDBOX_IMAGE
  relay:   $RELAY_IMAGE
  bridge:  ${BRIDGE:-<not created yet — appears after the first sandbox>}

If your inference endpoint is bound to 127.0.0.1 on this host, republish it on the
bridge so sandboxes can reach it (adjust ports to match your server):

  docker run -d --name relay-inference --network host --restart unless-stopped \\
    $RELAY_IMAGE \\
    socat TCP-LISTEN:18001,fork,reuseaddr,bind=${BRIDGE:-172.18.0.1} TCP:127.0.0.1:8000

then set in .env:
  INFERENCE_URL=http://host.openshell.internal:18001/v1

Next: ./scripts/spawn-agent.sh --name alpha --role "You are Alpha, a research assistant."
EOF
