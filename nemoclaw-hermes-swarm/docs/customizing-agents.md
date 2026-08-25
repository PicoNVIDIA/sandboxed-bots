# Customizing your agents

Three things define an agent. You can change any of them independently.

| What | Where | Changes what |
|---|---|---|
| **Role (SOUL)** | `souls/<name>.md` | How the agent thinks, what it refuses, how it writes |
| **Policy** | `policies/policy-bot-<name>.yaml` | What it can reach on the network and disk |
| **Model config** | in-sandbox `config.yaml` | Which endpoint, context length, token budget |

Start with the role. Most of what makes an agent useful is there, and it needs no
infrastructure change.

---

## 1. The role (SOUL.md)

A SOUL is a markdown file that becomes the agent's system prompt. `spawn-agent.sh`
writes it to `/sandbox/.hermes/SOUL.md` inside the sandbox and to the host profile.

```bash
./scripts/spawn-agent.sh --name auditor --role-file ./souls/reviewer.md
# or inline, for something quick
./scripts/spawn-agent.sh --name auditor --role "You audit Terraform for security problems."
```

### What separates a useful role from a decorative one

The example souls in `souls/` follow a pattern worth copying:

**Give it a method, not just an identity.** "You are a researcher" produces
generic output. A numbered procedure produces consistent output:

```markdown
## Method

1. **Planning** — restate the question, decompose it, state what a good answer
   would contain. Say what you will not cover.
2. **Research** — gather findings per sub-question, preferring primary sources.
3. **Cross-validation** — actively try to disconfirm your own findings.
4. **Finalization** — deliver the report.
```

**Write the rules that stop the failure you actually care about.** These are not
decoration — each line below was added in response to a real, observed failure:

```markdown
## Hard rules

- Never invent a source, citation, URL, number, or quote.
- Never cite an issue or PR you did not fetch in THIS session. Recalling an
  identifier from memory is fabrication even when it happens to exist.
- Separate what you *found* from what you *inferred* from what you *assume*,
  and use those words.
- If a tool cannot reach what you need, name the blocker. A blocked source is a
  finding, not something to work around.
```

That second rule matters more than it looks. An agent with web access will
confidently produce plausible issue numbers from training data unless told not to.

**Tell it how to work with teammates.** Agents cannot see each other's
conversations, so be explicit:

```markdown
## Working with your teammates

You have a `message_teammate` tool. Call `list_teammates` if unsure who exists.
Include all context in your message — the teammate cannot see this conversation.
When you receive a request, treat it as real work, not a question about yourself.
```

**Set the output shape.** If you want consistent structure, specify it:

```markdown
## Output

## Bottom line
<one or two sentences someone could forward>

## Findings
<numbered, each with the evidence it rests on>

## Confidence and gaps
<what is solid, what is shaky, what you could not verify>
```

### Changing a role after the agent exists

SOUL edits do not reach a running session — Hermes caches the system prompt.

```bash
# host profile
$EDITOR ~/.hermes/profiles/<name>/SOUL.md

# inside the sandbox (this is the one the agent actually reads)
B=$(base64 -w0 ~/.hermes/profiles/<name>/SOUL.md)
openshell sandbox exec -n bot-<name> -- /bin/sh -c \
  "echo $B | base64 -d > /sandbox/.hermes/SOUL.md"
```

Then start a **new** session. If the agent still behaves the old way, it is
replaying an old session — clear it or start fresh.

---

## 2. The policy (what the agent can reach)

Egress is deny-by-default. An agent reaches only what its policy lists, so giving
it a new capability is always two steps: **credential + policy**. Neither works
alone.

`policies/agent-base.yaml` is the template. Per-agent policies are generated as
`policies/policy-bot-<name>.yaml`.

### Adding a capability

Applied **additively**, so existing rules survive:

```bash
nemoclaw bot-<name> policy-add --from-file ./policies/my-capability.yaml --yes
```

Use `nemoclaw policy-add`, never `openshell policy set` — the latter **replaces**
the sandbox's entire policy and will silently remove the agent's inference and
peer rules.

### Example: read-only GitHub

```yaml
version: 3
preset:
  name: github-readonly
  description: "Read-only GitHub REST for one agent"
network_policies:
  github-readonly:
    name: github-readonly
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        enforcement: enforce
        rules:
          - allow: { method: GET, path: /repos/** }
          - allow: { method: GET, path: /search/** }
          - allow: { method: GET, path: /rate_limit }
    binaries:
      - { path: /sandbox/.hermes/hermes-agent/venv/bin/python }
      - { path: /usr/bin/python3 }
      - { path: /usr/bin/curl }
      - { path: /bin/sh }
```

Method-level rules are what make this genuinely read-only: a `POST` to create an
issue is rejected before it leaves the sandbox. Verify rather than assume:

```bash
openshell sandbox exec -n bot-<name> -- /bin/sh -c '
  curl -s -o /dev/null -w "read=%{http_code} " -H "Authorization: Bearer $TOKEN" \
    https://api.github.com/repos/OWNER/REPO
  curl -s -o /dev/null -w "write=%{http_code}\n" -X POST -d "{}" \
    -H "Authorization: Bearer $TOKEN" https://api.github.com/repos/OWNER/REPO/issues'
# want: read=200 write=<not 2xx>
```

### The two rules people get wrong

**Policies bind to binary paths, not just hosts.** Allowlisting a host is not
enough — the calling program must be in `binaries`. Observed with `pypi.org`
allowed: `curl` got 200 while `uv` got 403, purely because only curl was listed.

**Redirects are separate decisions.** `curl -L https://astral.sh/...` fails even
with `astral.sh` allowed, because the 301 target `releases.astral.sh` is evaluated
independently. Allowlist both.

### Giving different agents different powers

This is the main reason to run several agents rather than one. A sensible split:

| Agent | Policy adds | Why |
|---|---|---|
| researcher | web search | needs to find things |
| reviewer | read-only source access | needs to read code, never write it |
| operator | one internal API | narrow, audited blast radius |

An agent with no extra policy can still reason and talk to teammates — which is
sometimes exactly right, and sometimes means it has no way to do its stated job.
Decide deliberately.

---

## 3. Model configuration

Set in `.env` before spawning:

```bash
INFERENCE_URL=http://host.openshell.internal:18001/v1
INFERENCE_MODEL=my-model
AGENT_MAX_TOKENS=8192
AGENT_CONTEXT_LENGTH=65536
```

`AGENT_MAX_TOKENS` is not optional for local servers. Hermes otherwise requests
the entire context window as **output** tokens, and many servers reject that with
a 400.

### Pointing one agent at a different model

Useful for genuine diversity — a second opinion from the same weights is
correlated by construction.

```bash
# 1. allow the new port in that sandbox's policy
nemoclaw bot-<name> policy-add --from-file ./policies/other-engine.yaml --yes

# 2. repoint the in-sandbox config
openshell sandbox exec -n bot-<name> -- /bin/sh -c '
  export HOME=/sandbox HERMES_HOME=/sandbox/.hermes
  H=/sandbox/.hermes/hermes-agent/venv/bin/python
  $H -m hermes_cli.main config set model.base_url http://host.openshell.internal:18002/v1
  $H -m hermes_cli.main config set model.default other-model'

# 3. restart that sandbox's gateway so it picks up the change
```

A running gateway holds its config in memory; without the restart nothing changes.

---

## 4. Sandbox resources

```bash
SANDBOX_MEMORY=8Gi
SANDBOX_CPU=4
```

Applied at creation. To change an existing agent, destroy and re-spawn it — the
sandbox spec is fixed once created.

---

## 5. Adding a shared skill

Skills are markdown procedures an agent loads on demand. To install one into every
agent:

```bash
tar czf /tmp/skill.tgz -C ./skills my-skill
B=$(base64 -w0 /tmp/skill.tgz)
for a in $(./scripts/spawn-agent.sh --list | awk 'NR>1{print $1}'); do
  openshell sandbox exec -n bot-$a -- /bin/sh -c \
    "mkdir -p /sandbox/.hermes/skills && echo $B | base64 -d | tar xzf - -C /sandbox/.hermes/skills"
done
```

Ship one tarball rather than looping per file: each `sandbox exec` is a fresh
shell, and per-file base64 arguments hit the ~32KB exec limit.

---

## Verify after any change

```bash
./scripts/e2e-test.sh
```

Do not trust an agent's self-description — it can recite a role from its prompt
with every tool broken. The suite checks evidence: isolation via unique markers,
messaging via a secret only a teammate can read, and policy enforcement via
allowed-vs-blocked status codes.
