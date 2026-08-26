# Documentation

Which document answers which question.

| Question | Document |
|---|---|
| What is this and how do I start? | [../README.md](../README.md) |
| How do the pieces fit together? | [architecture.md](architecture.md) |
| Something is broken | [troubleshooting.md](troubleshooting.md) |
| How do I change an agent's behaviour, tools, or model? | [customizing-agents.md](customizing-agents.md) |
| How do I see what my agents actually did? | [../observability/README.md](../observability/README.md) |
| Can my own agent set this up for me? | [../skill/README.md](../skill/README.md) |

## Reading order for a first run

1. **README** — Scope and Prerequisites. Confirm you have what you need before
   building anything.
2. **README Quickstart** — five commands from clone to two working agents.
3. **architecture.md** — read the two-gateway diagram. Conflating those two
   gateways is the most common way this breaks.
4. **troubleshooting.md** — first section only, the four-step check for "is an
   agent really down". Read it before you need it.

Come back to `customizing-agents.md` when the default researcher and critic are
working and you want agents of your own.

`observability/README.md` is optional. It is worth doing if you plan to debug
multi-agent behaviour, because it makes "the agent claimed it checked something but
made no tool calls" visible at a glance.

## If you only read one page

`troubleshooting.md`, first section. Most reported agent failures are not agent
failures, and checking in the wrong order is what wastes time.
