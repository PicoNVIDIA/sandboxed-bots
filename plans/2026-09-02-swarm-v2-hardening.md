# nemoclaw-hermes-swarm v2: harden, clean, and move to Hermes 0.21

> For agentic workers: execute with subagent-driven-development, one task per
> subagent, diff every result before trusting it. Steps use `- [ ]` for tracking.

**Goal:** a Hermes user points their agent at one skill and gets Hermes bots
running in NemoClaw sandboxes, observable through NeMo Relay, in one command.

**Architecture:** one bash entrypoint (`./swarm`) with a small library of
modules. Config lives in `swarm.env`. Inference is any OpenAI-compatible URL
(default in the example: NVIDIA Inference Hub, Nemotron 3 Super). Each bot is a
Hermes 0.21 install baked into the sandbox image, one OpenShell sandbox per bot,
an api_server on the bridge, a host profile that proxies to it, and a Relay
plugins file that ships spans to an OTel collector on the host.

**Tech stack:** bash 5 (host), OpenShell 0.0.85 / NemoClaw 0.0.97, Docker,
Hermes Agent pinned to tag `v2026.8.31`, otel-collector-contrib, NeMo Relay
(bundled in Hermes), Hermes Desktop over an SSH connection.

---

## Decisions already taken (from the 0.21 review)

| Topic | Decision | Why |
|---|---|---|
| Hermes version | Pin tag `v2026.8.31` in image build; never `main` | Mixed fleets were the main migration risk |
| Inference | External OpenAI-compatible endpoint only; no vLLM, no GPU code, no socat relays | Removes ~40% of the old script and every engine-debugging section |
| Peer messaging | Keep our plugin (renamed `teammates`) | Core `message_agent` is injected only into a bot's local "Bot Chat" session; the sandbox api_server ignores client-supplied `tools` (verified in `api_server.py`, tools are only used for the idempotency fingerprint). A proxying host profile therefore never gives the sandboxed model that tool. |
| Cross-agent trace tree | Out of scope | Needs Hermes core changes |
| Relay | On by default; collector always runs; LangSmith exporter enabled only when a key file exists | Relay is the product story; the example must not depend on a SaaS key |
| Desktop | SSH connection to the host, host profiles proxy to sandbox api_servers | Proven; 0.21 adds lossless replay and reason codes on top |
| Old fleet | Destroy alpha/beta/gamma/delta and rebuild with the new scripts | Proves the revamp end to end |
| Default fleet | two bots (researcher, reviewer) + skill to add more | Smallest example that shows a handoff |

## Open questions the spike answers (Task 0)

1. Does Hermes 0.21 Desktop still need a host-side `hermes -p <bot> gateway run`
   for the bot to appear in the roster over an SSH connection? Docs say SSH
   sources are "inventoried without spawning anything". If the answer is no,
   the two-gateway design collapses to one and `start` gets simpler.
2. Does a Hermes install baked into the image survive OpenShell's landlock and
   the `sandbox` user mapping (`/sandbox/.hermes` pre-populated at build time)?
3. Does `HERMES_NEMO_RELAY_PLUGINS_TOML` on 0.21 print the activation line
   `Relay plugins are active processing...` in the in-sandbox gateway log, and
   does the collector receive spans without the `transform/root` hack?
4. Does egress to `inference-api.nvidia.com:443` work from the sandbox with a
   `binaries` list of just the venv python and curl?

Verified already on the Mac with Hermes 0.21: `nvidia/nvidia/nemotron-3-super-v3`
on `https://inference-api.nvidia.com/v1` answers and calls tools (terminal tool
ran `echo SMOKE-42`), using a named provider block with `key_env:
NVIDIA_API_KEY`. `provider: custom` with `OPENAI_API_KEY` got a 401 from the
same key, so the spawn must write the named-provider shape.

---

## Target repo layout

```
nemoclaw-hermes-swarm/
├── README.md                  hero, 5-minute quickstart, one diagram, links
├── SECURITY.md                threat model: what the sandbox gives, what it does not, secrets
├── CHANGELOG.md
├── swarm                      the only entrypoint (bash)
├── swarm.env.example          every knob, commented
├── lib/
│   ├── common.sh              log/ok/warn/die, ansi strip, ssh-safe helpers
│   ├── preflight.sh           12 checks (tools, docker, openshell, bridge, endpoint auth)
│   ├── image.sh               build bot image with Hermes baked in at the pinned tag
│   ├── policy.sh              render per-bot policy from templates, additive policy-add
│   ├── sandbox.sh             create/wait/exec/upload helpers, 32KB arg guard
│   ├── bot.sh                 configure model, api_server, SOUL, gateway, forward
│   ├── host.sh                host profile, host gateway (if still needed), desktop hints
│   ├── mesh.sh                peer registration both directions + policy
│   ├── tracing.sh             collector container, relay-plugins.toml, otlp policy
│   └── verify.sh              health ladder used by `swarm status` and `swarm test`
├── image/
│   └── Dockerfile             ubuntu 24.04 + python3.11 + node deps + Hermes @ tag
├── policies/
│   ├── bot.template.yaml      version 3, deny-by-default, {{INFERENCE_HOST}} etc.
│   └── otlp-export.yaml
├── plugins/teammates/         message_teammate + list_teammates (from v1, renamed)
├── souls/researcher.md  reviewer.md  security.md  qa.md
├── observability/
│   ├── otel-collector-config.yaml   logging exporter always; otlphttp/langsmith when key present
│   └── relay-plugins.toml.tmpl
├── tests/
│   └── e2e.sh                 portable suite, discovers bots from `swarm ls --json`
├── skill/
│   ├── SKILL.md               "deploy a Hermes bot in a NemoClaw sandbox"
│   └── references/            traps, verification, desktop
└── docs/
    ├── architecture.md        diagrams (request flow, isolation, tracing)
    ├── customizing.md         SOUL, policy, tools, model per bot
    ├── observability.md       Relay -> collector -> LangSmith/anything OTLP
    └── troubleshooting.md     desktop-first ordering, status-code ladder
```

`swarm` subcommands:

```
swarm up              preflight -> image -> collector -> bots in swarm.env -> mesh -> verify
                      idempotent: same command restores after a reboot
swarm add NAME --role "..." | --role-file f | --soul souls/qa.md
swarm rm NAME         sandbox, forward, host profile, peers, policy, relay file
swarm ls [--json]     name, sandbox phase, api port, peers, gateway state
swarm status          health ladder per bot (sandbox -> api 200 -> chat OK -> peers -> relay)
swarm test            tests/e2e.sh
swarm down            rm every bot in swarm.env (asks unless --yes)
swarm doctor          preflight + desktop hints (connection kind, restart the app)
```

---

## Task 0: Spike on the box (direct, not delegated; ~2h)

**Where:** `poc-nvaie`, sandbox name `spike0`, api port 8499. Existing bots and
the `hermes`/`deep-research-worker` sandboxes untouched.

- [ ] Build `image/Dockerfile` draft with Hermes baked in:
      `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --branch v2026.8.31`
      as the `sandbox` user with `HOME=/sandbox HERMES_HOME=/sandbox/.hermes`.
      Verify inside the image: `/sandbox/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main --version` prints `v0.21.0 (2026.8.31)`.
- [ ] Create `spike0` from it with a policy allowing only `inference-api.nvidia.com:443`
      for `{venv python, /usr/bin/curl}`. Ladder: curl `/v1/models` with the key
      read from `~/.secrets/inference.key` -> expect 200 (403 = policy, 502 = route).
- [ ] Write the named-provider config, `API_SERVER_KEY`, start the gateway, forward
      8499 to the bridge, `curl 172.18.0.1:8499/v1/models` -> 200; one chat turn via
      the host profile -> a tool call executes inside the sandbox.
- [ ] Relay: write `relay-plugins.toml` pointing at the existing collector `:4319`,
      set `HERMES_NEMO_RELAY_PLUGINS_TOML` in the sandbox `.env`, restart the gateway,
      grep the activation line, run a turn, confirm span count grows at the collector.
- [ ] Desktop question: with NO host gateway for `spike0`, restart Hermes Desktop on
      the Mac and check whether `@spike0` appears in the roster and answers in a DM.
      Record the answer; it decides `lib/host.sh`.
- [ ] Tear down `spike0` by name. Write findings into this file under "Spike results".

## Task 1: Repo skeleton and `swarm` CLI shell

**Files:** `swarm`, `lib/common.sh`, `swarm.env.example`, `.gitignore`
(`swarm.env`, `secrets/`, `logs/`, `*.key`).

- [ ] `swarm` parses subcommands, sources `swarm.env` (dies with the fix if missing
      or if a required var is empty), sources `lib/*.sh`, dispatches.
- [ ] `swarm.env.example`:
      ```
      INFERENCE_BASE_URL=https://inference-api.nvidia.com/v1
      INFERENCE_MODEL=nvidia/nvidia/nemotron-3-super-v3
      INFERENCE_KEY_FILE=$HOME/.secrets/inference.key      # mode 600, never copied into the repo
      INFERENCE_CONTEXT_LENGTH=131072
      HERMES_REF=v2026.8.31
      BOTS="researcher reviewer"                            # names; souls/<name>.md must exist
      API_PORT_BASE=8477
      BRIDGE_IP=172.18.0.1
      TRACING=on                                            # on|off
      OTLP_PORT=4319
      LANGSMITH_KEY_FILE=$HOME/.secrets/langsmith.key       # optional; exporter added only if present
      LANGSMITH_PROJECT=hermes-swarm
      ```
- [ ] `lib/common.sh`: `log ok warn die`, `strip_ansi`, `require_cmd`, `read_secret FILE`
      (checks mode 600, non-empty), `with_login_shell`, `retry N CMD`.
- [ ] Test: `./swarm` with no env prints usage and exits 2; with the example copied,
      `./swarm ls` prints an empty table. Commit.

## Task 2: Preflight, image, policy

**Files:** `lib/preflight.sh`, `lib/image.sh`, `image/Dockerfile`,
`lib/policy.sh`, `policies/bot.template.yaml`, `policies/otlp-export.yaml`.

- [ ] Preflight checks (each prints PASS/FAIL and the fix): docker, openshell,
      nemoclaw, hermes on host >= 0.21, bridge `172.18.0.1` present, `openshell
      sandbox list` works, `INFERENCE_KEY_FILE` mode 600, endpoint auth (curl
      `/v1/models` 200), model id present in that list, free api ports, disk >= 20G.
- [ ] Image build from Task 0 Dockerfile; tag `hermes-bot:${HERMES_REF}`; skip if
      present unless `--rebuild`.
- [ ] Policy template render with `sed` from `swarm.env` values; `policy_add` wrapper
      writes to a `.yaml` tempfile (NemoClaw rejects other extensions) and always uses
      `nemoclaw <sandbox> policy-add --from-file --yes`.
- [ ] Test: `./swarm up --only preflight` on the box prints 12 PASS. Commit.

## Task 3: One bot end to end (`swarm add`)

**Files:** `lib/sandbox.sh`, `lib/bot.sh`, `lib/host.sh`, `souls/researcher.md`.

- [ ] `sandbox_create NAME`: `timeout 180 openshell sandbox create ... || true`, then
      poll `Ready` with ANSI stripped first. `sbexec` guards the 32KB arg cap and
      stages larger payloads via base64 file.
- [ ] `bot_configure NAME PORT`: write `providers.inference` block + `model.*` via
      `hermes_cli.main config set` with JSON literals; `API_SERVER_KEY` reused from
      `secrets/NAME.key` if present else `openssl rand -hex 32`; SOUL from `souls/NAME.md`.
- [ ] `bot_start NAME`: stop stale gateway first (holds the old key), start with
      `--timeout 0` under `setsid`, forward `PORT` to `BRIDGE_IP:PORT` under `setsid`
      in a login shell, kill duplicates by exact port before starting.
- [ ] `host_profile NAME PORT`: `hermes profile create`, `model.base_url` ->
      `http://BRIDGE_IP:PORT/v1`, key, `model.default hermes-agent`, context length.
      Host gateway only if Task 0 says the roster needs it.
- [ ] Verify ladder: api 200 on bridge -> `hermes -p NAME chat -q "Reply exactly: NAME-OK"`.
- [ ] Test on the box with name `t1`, port 8498; then `./swarm rm t1` leaves no
      sandbox, forward, profile dir, `gateway.pid`, or key. Commit.

## Task 4: Mesh and teammates plugin

**Files:** `lib/mesh.sh`, `plugins/teammates/*` (moved from `plugins/peer-messaging`).

- [ ] For each existing bot B when adding A: `hermes peer add` inside both
      sandboxes (A->B with B's key, B->A with A's key), policy group `peer-B` on A
      allowing `host.openshell.internal:PORT_B` and vice versa, plugin tarball
      installed once per sandbox.
- [ ] `swarm rm` un-peers on every other bot and removes the policy group entries
      it added (policy-add cannot remove; document the residual allow rule or
      regenerate the policy with `openshell policy set` only on the bot being removed).
- [ ] Test: plant `E2E-<rand>` in `/sandbox/secret.txt` of `t2`; ask `t1` to fetch it
      via `message_teammate`; reply must contain it. Commit.

## Task 5: Tracing

**Files:** `lib/tracing.sh`, `observability/otel-collector-config.yaml`,
`observability/relay-plugins.toml.tmpl`, `docs/observability.md`.

- [ ] Collector container `swarm-otel` on the bridge `:OTLP_PORT`, `restart
      unless-stopped`; config rendered by a python heredoc-free script (the old sed
      corrupted `${env:...}`). Exporters: `debug` always; `otlphttp/langsmith` only if
      `LANGSMITH_KEY_FILE` exists, key passed via `-e`.
- [ ] Per bot: write `relay-plugins.toml`, add `HERMES_NEMO_RELAY_PLUGINS_TOML` to
      the sandbox `.env`, apply `policies/otlp-export.yaml`, restart the gateway,
      assert the activation line in the log (fail loudly, Relay fails open).
- [ ] `swarm status` shows collector span count; `swarm traces NAME` tails the
      collector debug output filtered to that bot.
- [ ] Test: two turns -> span count grows; if LangSmith key present, project last
      run time updates. Commit.

## Task 6: `swarm up`, `status`, `test`, restore

**Files:** `lib/verify.sh`, `tests/e2e.sh`, `swarm` (up/down/status).

- [ ] `swarm up` = preflight, image, collector, for each `BOTS` add-if-missing,
      mesh, status. Re-running after a reboot restarts gateways/forwards for
      existing sandboxes without recreating anything (discover from `openshell
      sandbox list` + profiles, never hardcode names).
- [ ] `tests/e2e.sh`: sections preflight, sandbox isolation (namespaces differ from
      host and each other, same path different content), api, chat, mesh secret,
      tracing, desktop prerequisites; summary line `N passed, M failed`; exit code.
- [ ] Test: fresh `./swarm up` builds researcher + reviewer; `./swarm test` all pass;
      `sudo reboot` is out of scope, simulate with killing gateways and forwards then
      `./swarm up` again -> all pass. Commit.

## Task 7: Destroy the old fleet and rebuild the four-role demo

- [ ] Back up `~/poc-sandbox/` to `~/poc-sandbox.bak-<date>` (contains keys; stays
      on the box). Destroy `bot-alpha bot-beta bot-gamma bot-delta` with the OLD
      `spawn-agent.sh --destroy` so their forwards, host gateways, and profiles go
      with them; delete stale `zzone`/`zztwo` profiles. Leave `hermes` and
      `deep-research-worker` alone.
- [ ] `./swarm up` (researcher, reviewer), then `./swarm add security --soul
      souls/security.md` and `./swarm add qa --soul souls/qa.md`.
- [ ] Restart Hermes Desktop; group chat with all four; sequential handoff works;
      `reason` codes appear if a bot fails. Record timings in CHANGELOG.

## Task 8: Docs, skill, presubmit

- [ ] README: what you get (one diagram), prerequisites table, 5 commands to a
      running swarm, "add a bot", "watch traces", "what the sandbox does and does
      not protect" (link SECURITY.md), scope list in nemoclaw-community style.
- [ ] `SECURITY.md`: isolation proof commands, egress deny-by-default, secrets on
      the host only (`~/.secrets`, mode 600), what a compromised bot can still do
      (talk to peers it is allowed to, call the inference endpoint).
- [ ] `skill/SKILL.md` rewritten: trigger phrases, prerequisites, the exact
      commands (`git clone`, copy env, `./swarm up`, `./swarm add`), verification,
      traps list from Task 0 findings. Drop every vLLM/NCCL section.
- [ ] Acceptance test for the skill: a fresh Hermes profile on the Mac with only
      this skill and SSH access spawns `demo5` on the box from the prompt "deploy a
      Hermes bot named demo5 in a NemoClaw sandbox on poc-nvaie that reviews PRs".
      Then `./swarm rm demo5`.
- [ ] `scripts/presubmit-check.sh` -> `tests/presubmit.sh`: SPDX headers, no
      secrets (`sk-`, `lsv2_`, 32-hex), no empty dirs, shellcheck clean, `bash -n`.
- [ ] Remove v1 files from the repo root (`Dockerfile.bot`, `policy-bot-*.yaml`,
      `start-sandboxed-bots.sh`, `peer-plugin/`, ...) so the example is the only
      thing in the repo, or move them under `archive/v1/` with one README line.
- [ ] Push to `PicoNVIDIA/sandboxed-bots`, tag `v2.0.0`.

---

## Spike results

(filled in by Task 0)
