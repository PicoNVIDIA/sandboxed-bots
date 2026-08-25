#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# 02-bootstrap-two-agents.sh — create a working pair of agents.
#
# Two agents is the smallest interesting swarm: one produces, one checks, and they
# can hand work to each other without you relaying. Each gets its own sandbox.
#
#   researcher — gathers evidence with a four-phase method
#   critic     — stress-tests the researcher's output
#
# Both roles are plain markdown in souls/ — edit them, or pass your own with
# --role-file. See docs/customizing-agents.md.
#
# Idempotent: safe to re-run. Existing agents are repaired, not duplicated.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

AGENT_A="${AGENT_A:-researcher}"
AGENT_B="${AGENT_B:-critic}"

echo "==> bootstrapping a two-agent swarm: $AGENT_A + $AGENT_B"
echo "    each in its own sandbox, sharing one inference endpoint"
echo

for pair in "$AGENT_A:souls/researcher.md" "$AGENT_B:souls/critic.md"; do
  name="${pair%%:*}"
  soul="${pair##*:}"

  if [[ ! -f "$soul" ]]; then
    echo "  FAIL missing role file: $soul" >&2
    exit 1
  fi

  echo "──────────────────────────────────────────────────────────────"
  echo " $name  (role: $soul)"
  echo "──────────────────────────────────────────────────────────────"
  # The second spawn automatically peers with the first, in both directions.
  ./scripts/spawn-agent.sh --name "$name" --role-file "$soul"
  echo
done

echo "=============================================================="
echo " swarm ready"
echo "=============================================================="
./scripts/spawn-agent.sh --list
echo
cat <<EOF
Try them from the CLI:

  hermes -p $AGENT_A chat -q "Research the tradeoffs of running agents in separate sandboxes."
  hermes -p $AGENT_B chat -q "Ask $AGENT_A for that research, then tell me what is weak in it."

The second command is the interesting one: $AGENT_B reaches $AGENT_A through its
message_teammate tool, and $AGENT_A runs a real turn in its own sandbox.

To use them together in the Hermes desktop app:
  1. restart the app (the profile list is read at launch)
  2. both agents appear in the Bots roster
  3. put them in a group chat and ask a question

Verify everything with evidence rather than vibes:
  ./scripts/e2e-test.sh

Customize roles, policies, and models:
  docs/customizing-agents.md
EOF
