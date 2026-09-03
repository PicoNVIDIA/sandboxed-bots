# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Host side of a bot: a Hermes profile on this machine whose "model" is the
# bot's sandbox api_server. Hermes Desktop lists host profiles as Bots; every
# turn it sends to this profile executes inside the sandbox.
#
# Whether the roster also needs a host-side gateway per profile is decided by
# HOST_GATEWAY (auto|on|off). "auto" follows what Task 0 of the plan found.

: "${HOST_GATEWAY:=on}"

host_profile_state() {
  hermes profile list 2>/dev/null | strip_ansi | awk -v n="$1" '$1==n{print $3}' | head -1
}

# host_profile_ensure NAME PORT KEY SOUL(optional)
host_profile_ensure() {
  local name="$1" port="$2" key="$3" soul="$4"
  hermes profile list 2>/dev/null | strip_ansi | awk '{print $1}' | grep -qx "$name" \
    || hermes profile create "$name" >/dev/null 2>&1 || true
  local prov
  prov=$(jq -cn --arg url "http://$HOST_API_ADDR:$port/v1" \
    '{name:"sandbox", base_url:$url, key_env:"SANDBOX_API_KEY", models:["hermes-agent"], default_model:"hermes-agent"}')
  hermes -p "$name" config set providers.sandbox "$prov" >/dev/null 2>&1
  hermes -p "$name" config set model.provider sandbox >/dev/null 2>&1
  hermes -p "$name" config set model.default hermes-agent >/dev/null 2>&1
  hermes -p "$name" config set model.base_url "http://$HOST_API_ADDR:$port/v1" >/dev/null 2>&1
  hermes -p "$name" config set model.max_tokens "$INFERENCE_MAX_TOKENS" >/dev/null 2>&1
  hermes -p "$name" config set model.context_length "$INFERENCE_CONTEXT_LENGTH" >/dev/null 2>&1
  local envf="$HOME/.hermes/profiles/$name/.env"
  touch "$envf"; chmod 600 "$envf"
  sed_delete '^SANDBOX_API_KEY=' "$envf"
  printf 'SANDBOX_API_KEY=%s\n' "$key" >> "$envf"
  [[ -n "$soul" && -f "$soul" ]] && cp "$soul" "$HOME/.hermes/profiles/$name/SOUL.md"
  ok "host profile $name -> $HOST_API_ADDR:$port"

  if [[ "$HOST_GATEWAY" == on ]]; then
    host_gateway_start "$name"
  fi
}

# The profile shows `running` in `hermes profile list` only when a gateway for
# it runs on this host. Login shell + setsid so it survives the SSH session.
host_gateway_start() {
  local name="$1" i st
  st=$(host_profile_state "$name")
  [[ "$st" == running ]] && { dim "host gateway for $name already running"; return 0; }
  rm -f "$HOME/.hermes/profiles/$name"/gateway.{pid,lock}
  daemonize "$(bot_log "$name" host-gateway)" hermes -p "$name" gateway run
  for ((i = 0; i < 12; i++)); do
    sleep 5
    [[ "$(host_profile_state "$name")" == running ]] && { ok "host gateway for $name running"; return 0; }
  done
  warn "profile $name still '$(host_profile_state "$name")'; log: $(bot_log "$name" host-gateway)"
}

host_gateway_stop() {
  local name="$1" pidf="$HOME/.hermes/profiles/$name/gateway.pid" pid
  hermes -p "$name" gateway stop >/dev/null 2>&1 || true
  # gateway.pid holds a JSON record, not a bare pid.
  if [[ -f "$pidf" ]]; then
    pid=$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); print(d.get("pid") or "")
except Exception:
    print(open(sys.argv[1]).read().strip())' "$pidf" 2>/dev/null | tr -dc '0-9')
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  fi
  pkill_pattern "hermes -p $name gateway run"
  pkill_pattern "profile $name serve"
}

host_profile_remove() {
  local name="$1"
  host_gateway_stop "$name"
  if hermes profile delete -y "$name" >/dev/null 2>&1; then ok "host profile $name deleted"
  else rm -rf "$HOME/.hermes/profiles/$name"; dim "host profile dir removed"; fi
}

host_desktop_hint() {
  if is_macos; then
    cat <<EOF

  Hermes Desktop (this Mac)
    Quit and reopen the app. The bots above appear in the Bots roster under
    Local. Seat them in a group chat and @mention them.
EOF
    return
  fi
  # Remote host: the address the Desktop should SSH to, from the default route.
  local ip; ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1)
  [[ -n "$ip" ]] || ip=$(host_reach_addr)
  cat <<EOF

  Hermes Desktop
    Settings -> Connections -> Add connection -> SSH: $(whoami)@${ip:-<this host>}
    Then quit and reopen the app; every bot above appears in the Bots roster.
    Seat them in a group chat and @mention them.
EOF
}
