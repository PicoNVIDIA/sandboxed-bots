# sandboxed-bots

Staging repository for the **nemoclaw-hermes-swarm** example: Hermes bots, each
in its own NVIDIA OpenShell sandbox managed by NemoClaw, traced with NeMo Relay,
driven from Hermes Desktop as a group chat.

The example lives in [`nemoclaw-hermes-swarm/`](nemoclaw-hermes-swarm/) and is
laid out to drop into
[`NVIDIA/nemoclaw-community/examples`](https://github.com/NVIDIA/nemoclaw-community/tree/main/examples).
Start with its [README](nemoclaw-hermes-swarm/README.md).

```bash
cd nemoclaw-hermes-swarm
cp swarm.env.example swarm.env      # endpoint + model
./swarm up
./swarm test
```

`plans/` holds the working notes behind each revision.
