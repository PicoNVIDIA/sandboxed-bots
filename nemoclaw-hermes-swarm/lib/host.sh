# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Host side of a bot: a Hermes profile on this machine whose "model" is the
# bot's sandbox api_server. Hermes Desktop lists host profiles as Bots; every
# turn it sends to this profile executes inside the sandbox.
#
# One gateway per host. Since Hermes 0.21.4 the default profile's gateway
# serves every named profile (`served_profiles` in ~/.hermes/gateway_state.json)
# and a named profile refuses `gateway run` of its own. So this file starts
# exactly one gateway, from the default profile, and every shim rides it.
# A running gateway picks up new profiles on its own (`hermes profile create`
# notifies it), so adding a bot never restarts the gateway.
#
# HOST_GATEWAY (on|off): off skips the gateway entirely (bots still answer to
# `hermes -p NAME chat`; Desktop will not list them).

: "${HOST_GATEWAY:=on}"

host_profile_state() {
  hermes profile list 2>/dev/null | strip_ansi | awk -v n="$1" '$1==n{print $3}' | head -1
}

# The one host gateway: state file, pid, and whether it is live.
_hgw_state() { printf '%s/.hermes/gateway_state.json' "$HOME"; }
_hgw_log()   { printf '%s/logs/host-gateway.log' "$SWARM_STATE"; }
host_gateway_pid() {
  python3 -c 'import json,sys,os
try:
    d=json.load(open(sys.argv[1])); p=int(d.get("pid") or 0)
    os.kill(p, 0); print(p)
except Exception:
    pass' "$(_hgw_state)" 2>/dev/null
}
host_gateway_running() { [[ -n "$(host_gateway_pid)" ]]; }

# host_profile_ensure NAME PORT KEY SOUL(optional)
# A host profile with our bot's name that this tool did not create belongs to
# the operator. Refuse to reconfigure or delete it.
_profile_marker() { printf '%s/.hermes/profiles/%s/.swarm-owner' "$HOME" "$1"; }
host_profile_owned() { [[ -f "$(_profile_marker "$1")" ]]; }

host_profile_ensure() {
  local name="$1" port="$2" key="$3" soul="$4"
  if hermes profile list 2>/dev/null | strip_ansi | awk '{print $1}' | grep -qx "$name"; then
    if ! host_profile_owned "$name"; then
      # Legacy adoption: the profile already points at this bot's sandbox port.
      if grep -qs "base_url: http://$HOST_API_ADDR:$port/v1" "$HOME/.hermes/profiles/$name/config.yaml"; then
        touch "$(_profile_marker "$name")"
      else
        die "a Hermes profile named $name already exists and was not created by this deployment; refusing to reconfigure it"
      fi
    fi
  else
    hermes profile create "$name" >/dev/null 2>&1 || die "could not create host profile $name"
    touch "$(_profile_marker "$name")"
  fi
  local prov
  prov=$(jq -cn --arg url "http://$HOST_API_ADDR:$port/v1" \
    '{name:"sandbox", base_url:$url, key_env:"SANDBOX_API_KEY", models:["hermes-agent"], default_model:"hermes-agent"}')
  hermes -p "$name" config set providers.sandbox "$prov" >/dev/null 2>&1
  hermes -p "$name" config set model.provider sandbox >/dev/null 2>&1
  hermes -p "$name" config set model.default hermes-agent >/dev/null 2>&1
  # The shim is itself a Hermes agent. With supports_vision off it strips
  # image parts before they reach the sandbox and leaves a text note with a
  # host path, which is useless in there. Always pass images through: whether
  # this bot can see is decided by the model config INSIDE the sandbox, and a
  # text bot that receives the image can forward it to a teammate that can.
  hermes -p "$name" config set model.supports_vision true >/dev/null 2>&1
  # The shim's "main model" is the bot. Auxiliary calls that default to the
  # main model (title generation, and compression if it ever triggers) would
  # each become a second full agent turn inside the sandbox, with tools and
  # without the image. Title generation fires on every message; turn it off.
  hermes -p "$name" config set auxiliary.title_generation.enabled false >/dev/null 2>&1
  hermes -p "$name" config set model.base_url "http://$HOST_API_ADDR:$port/v1" >/dev/null 2>&1
  hermes -p "$name" config set model.max_tokens "$INFERENCE_MAX_TOKENS" >/dev/null 2>&1
  hermes -p "$name" config set model.context_length "$INFERENCE_CONTEXT_LENGTH" >/dev/null 2>&1
  local envf="$HOME/.hermes/profiles/$name/.env"
  touch "$envf"; chmod 600 "$envf"
  sed_delete '^SANDBOX_API_KEY=' "$envf"
  printf 'SANDBOX_API_KEY=%s\n' "$key" >> "$envf"
  [[ -n "$soul" && -f "$soul" ]] && cp "$soul" "$HOME/.hermes/profiles/$name/SOUL.md"
  host_dropbox_ensure "$name"
  ok "host profile $name -> $HOST_API_ADDR:$port"

  if [[ "$HOST_GATEWAY" == on ]]; then
    host_gateway_ensure
    host_profile_wait_served "$name"
  fi
}

# Dropped videos. Desktop attaches a dropped file as @file:/host/path, which
# means nothing in a sandbox. The dropbox plugin, installed in every host shim
# when a vss bot is in the fleet, uploads the clip into that bot's
# /sandbox/videos before the turn is forwarded and tells the bot the name.
# Host code, host tool (openshell sandbox upload), one target, videos only.
# Content-hashed like the sandbox plugins; removed when no vss bot exists.
host_dropbox_ensure() {
  local name="$1" vss="" b pdir dst envf want have
  for b in $(bot_list); do [[ "$(bot_short "$b")" == vss ]] && vss=$(sandbox_of "$b"); done
  pdir="$HOME/.hermes/profiles/$name/plugins"; dst="$pdir/dropbox"
  envf="$HOME/.hermes/profiles/$name/.env"
  sed_delete '^SWARM_VSS_SANDBOX=' "$envf"
  if [[ -z "$vss" || "$(bot_short "$name")" == vss ]]; then
    rm -rf "$dst"; return 0
  fi
  printf 'SWARM_VSS_SANDBOX=%s\n' "$vss" >> "$envf"
  want=$(cat "$SWARM_ROOT/plugins/dropbox/plugin.yaml" "$SWARM_ROOT/plugins/dropbox/__init__.py" > /tmp/dropbox.$$ && sha16 /tmp/dropbox.$$; rm -f /tmp/dropbox.$$)
  have=$(cat "$dst/.hash" 2>/dev/null || true)
  if [[ "$want" != "$have" ]]; then
    mkdir -p "$pdir"; rm -rf "$dst"; cp -R "$SWARM_ROOT/plugins/dropbox" "$dst"
    printf '%s' "$want" > "$dst/.hash"
    hermes -p "$name" plugins enable dropbox >/dev/null 2>&1 || true
    dim "dropbox plugin -> $name (videos land in $vss:/sandbox/videos)"
    # The gateway loaded this profile's plugins when it started serving it;
    # ask for a restart so the new plugin lands. One gateway, one restart.
    _hgw_restart_wanted=1
  fi
}

# Start the one host gateway if it is not running. Idempotent. Login shell +
# setsid so it survives the SSH session that started it.
host_gateway_ensure() {
  if host_gateway_running; then
    if [[ -n "${_hgw_restart_wanted:-}" ]]; then
      dim "restarting the host gateway to load new plugins"
      host_gateway_stop
    else
      return 0
    fi
  fi
  _hgw_restart_wanted=""
  daemonize "$(_hgw_log)" hermes gateway run
  local i
  for ((i = 0; i < 12; i++)); do
    sleep 5
    host_gateway_running && { ok "host gateway running (pid $(host_gateway_pid), serves every bot profile)"; return 0; }
  done
  warn "host gateway did not come up; log: $(_hgw_log)"
  return 1
}

# The profile shows `running` in `hermes profile list` once the gateway
# serves it. A new profile is picked up within a few seconds.
host_profile_wait_served() {
  local name="$1" i st
  for ((i = 0; i < 12; i++)); do
    st=$(host_profile_state "$name")
    [[ "$st" == running ]] && { ok "host profile $name served by the gateway (visible to Desktop)"; return 0; }
    sleep 5
  done
  warn "profile $name still '$st' after 60s; log: $(_hgw_log)"
  return 1
}

host_gateway_stop() {
  local pid; pid=$(host_gateway_pid)
  hermes gateway stop >/dev/null 2>&1 || true
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  local i
  for ((i = 0; i < 10; i++)); do host_gateway_running || return 0; sleep 1; done
  [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
  return 0
}

# Removing a profile: the gateway notices the tombstone and stops serving it.
# The gateway itself stays up for the other bots. `swarm down` of the last bot
# leaves the default gateway running; that is the operator's process, not ours.
host_profile_remove() {
  local name="$1"
  if hermes profile list 2>/dev/null | strip_ansi | awk '{print $1}' | grep -qx "$name" && ! host_profile_owned "$name"; then
    warn "host profile $name was not created by this deployment; leaving it"
    return 0
  fi
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
