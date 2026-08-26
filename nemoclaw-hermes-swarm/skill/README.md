# Hermes skill

`SKILL.md` is a portable [Hermes Agent skill](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills).
Install it and your own agent can drive this example: spawn agents, diagnose a
silent bot, repair the desktop layer, and verify the result.

Useful because the failure modes here are not guessable. An agent without this
skill will check things in the wrong order and conclude an agent is broken when the
desktop client has simply exited.

## Install

```bash
mkdir -p ~/.hermes/skills/hermes-swarm-setup
cp skill/SKILL.md ~/.hermes/skills/hermes-swarm-setup/
```

Confirm it loaded:

```bash
hermes skills list | grep hermes-swarm-setup
```

For a specific profile, use `~/.hermes/profiles/<name>/skills/` instead.

## Then just ask

```
Set up a two-agent swarm from this repo and verify it works.
Add an agent called reviewer that audits code for security problems.
alpha is not responding in the group chat — find out why.
```

The agent loads the skill, follows the ordering, and runs the scripts in this repo.

## What it encodes

Knowledge that cost real debugging time:

- **Check the client app first.** Most "agent is down" reports are a desktop client
  that exited, not an agent fault. The four-step ordering is the most valuable
  thing in the file.
- **Two gateways per agent.** One serves the api_server, one makes the agent
  visible in the roster. Conflating them produces an agent that works over HTTP and
  is invisible in the app.
- **Never `openshell policy set`.** It replaces a sandbox's whole policy. Additive
  edits only.
- **Install hangs are usually a GitHub 429**, because sandboxes share one apparent
  source through the OpenShell proxy.
- **Role wording that prevents stalls.** Two paragraphs that turned an observed
  six-minute failure into a 57-second answer with ten cited sources.
- **Traps in your own diagnostics**, including `gateway.pid` holding JSON rather
  than a bare PID, and nested shell quoting mangling API keys into false 401s.

## Adapting it

The file assumes this repo's script names and the OpenShell bridge at
`172.18.0.1`. If you rename scripts or run a different bridge, edit those
references. Everything else is deployment-independent.
