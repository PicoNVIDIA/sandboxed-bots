# Two more bots: one that can see, one that can watch video

The default swarm is two text-only bots. These two are what we added when a
colleague asked whether the demo could do more than text. You don't need them.
They're here because the way they work is the point of the whole repo, made
visible: only one bot's model accepts images, only one bot's egress reaches
the video model, and everyone else gets there by asking in plain language
across a sandbox boundary.

| Bot | What it can do that the others can't | What it needs |
|---|---|---|
| `nemoclaw-vision` | its model accepts images; a picture attached in Desktop reaches it as pixels | a vision-capable model on your endpoint |
| `nemoclaw-vss` | watches a video clip through NVIDIA RT-VLM and reports timestamped findings | an RT-VLM container it is allowed to reach |

Everything in this directory is picked up by name. `swarm add nemoclaw-vision`
finds `examples/souls/nemoclaw-vision.md`; `swarm add nemoclaw-vss` finds its
soul, `examples/policies/nemoclaw-vss.yaml`, `examples/plugins/vss/`,
`examples/skills/vss-video/`, and the clips in `examples/videos/`. Nothing
here touches the two default bots.

## The vision bot

Two lines in `swarm.env`, then add it:

```bash
INFERENCE_MODEL_NEMOCLAW_VISION=nvidia/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning
INFERENCE_VISION_NEMOCLAW_VISION=on

./swarm add nemoclaw-vision
```

Same endpoint and key as the other bots; only the model differs. The second
line matters: Hermes strips image parts before they reach any model it can't
find on models.dev, which is every model behind a custom endpoint, so a
vision model has to be declared. Without it the bot says "I cannot see the
attached image" and means it.

Any model that takes `image_url` parts and calls tools will do. On the NVIDIA
inference API we tested `nemotron-3-nano-omni-30b-a3b-reasoning` (works; it is
a reasoning model, keep `INFERENCE_MAX_TOKENS` at 8192 or the answer ends up
in the reasoning field). `nemotron-nano-12b-v2-vl` sees images but rejects
`tool_choice: auto`, so it cannot be a bot.

Test it from the host, the same path Desktop uses:

```bash
hermes -p nemoclaw-vision chat --image photo.jpg -q "What is in this picture?"
```

## The VSS bot

The bot is text-only. What it has that the others don't is two tools,
`vss_describe_video` and `vss_ask_video`, that put a clip in front of NVIDIA
RT-VLM and return text, plus a skill that says when to use which. RT-VLM is
the vision model from the [Video Search and Summarization blueprint](https://github.com/NVIDIA-AI-Blueprints/video-search-and-summarization);
we run only that container, not the full blueprint.

### 1. Run RT-VLM

On the host with the GPU. One container, one GPU, an NGC key for the model
weights.

```bash
cd examples/vss
cp .env.example .env
$EDITOR .env                        # VSS_GPU, and VSS_BIND to your bridge address
NGC_API_KEY=$(cat ~/.secrets/ngc.key) docker compose up -d
docker compose logs -f              # first start downloads ~16 GB of weights; 10 to 20 min
curl -s http://172.18.0.1:8018/v1/models | jq -r '.data[].id'
```

It binds to the OpenShell bridge address, not `0.0.0.0`. Sandboxes can reach
it if their policy says so; nothing off the host can.

### 2. Add the bot

```bash
# swarm.env
VSS_BASE_URL=http://host.openshell.internal:8018

./swarm add nemoclaw-vss
```

`swarm` installs the plugin and skill into that one sandbox, applies
`examples/policies/nemoclaw-vss.yaml` (egress to port 8018 on the bridge,
nothing else), writes `VSS_BASE_URL` into the sandbox's `.env`, and copies
the clips from `examples/videos/` to `/sandbox/videos`. The other bots'
policies do not change; try `curl` to 8018 from the reviewer's sandbox and
you get a 403.

Test it:

```bash
hermes -p nemoclaw-vss chat -q "What happens in forklift-training.mp4?"
```

Your own footage: drop files into `examples/videos/` (or point
`VSS_VIDEOS_DIR` elsewhere) before `swarm add`, or give the bot an `http(s)`
URL the RT-VLM container can fetch. Clips up to about a minute and 40 MB
travel inline; longer ones need a URL.

## The demo

Room: reviewer, vision, vss.

1. Attach a photo, ask `@nemoclaw-reviewer what safety issues do you see?`
   The reviewer's model can't read the image. It asks `nemoclaw-vision`
   through `message_teammate`, relays the description with attribution, and
   adds its own read.
2. `@nemoclaw-vss what happens in forklift-training.mp4? Flag anything the
   reviewer should look at.` The vss bot watches the clip and reports with
   timestamps; the reviewer weighs in.

Three bots, three sandboxes, two handoffs across the boundary, no pixels in
either handoff. That last part is deliberate: the text bots never receive
image data they can't process, and the vision bots never receive anything
but a question.

## What's here

```
souls/nemoclaw-vision.md      the role
souls/nemoclaw-vss.md         the role
policies/nemoclaw-vss.yaml    egress to RT-VLM on the bridge
plugins/vss/                  vss_describe_video, vss_ask_video
skills/vss-video/SKILL.md     how and when to use them
vss/compose.yml, .env.example RT-VLM standalone
videos/                       two public-domain clips + LICENSES.md
```
