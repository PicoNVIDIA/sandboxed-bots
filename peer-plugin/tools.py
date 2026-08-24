"""Handlers for peer-messaging.

Sends a message to a teammate bot's api_server (OpenAI-compatible
/v1/chat/completions) and returns their reply.

Peers are read from the profile's own config (bot_peers) so this works
unchanged on a host profile or inside an OpenShell sandbox. Keys are read
from the environment (HERMES_PEER_<NAME>_KEY), never hardcoded.
"""

import json
import os
import urllib.error
import urllib.request

_TIMEOUT_S = 300
_HERMES_HOME = os.environ.get("HERMES_HOME") or os.path.join(
    os.path.expanduser("~"), ".hermes"
)


def _load_peers() -> dict:
    """Read bot_peers from this profile's config.yaml. Returns {name: {url, note}}."""
    cfg_path = os.path.join(_HERMES_HOME, "config.yaml")
    peers: dict = {}
    try:
        import yaml  # bundled with Hermes

        with open(cfg_path, "r", encoding="utf-8") as fh:
            cfg = yaml.safe_load(fh) or {}
        raw = cfg.get("bot_peers") or {}
        for name, entry in raw.items():
            if isinstance(entry, dict) and entry.get("url"):
                peers[str(name)] = {
                    "url": str(entry["url"]).rstrip("/"),
                    "note": str(entry.get("note") or ""),
                }
    except FileNotFoundError:
        pass
    except Exception:
        # A malformed config should not crash the tool; report empty.
        pass
    return peers


def _peer_key(name: str) -> str | None:
    """Key for a peer, as stored by `hermes peer add`.

    Checks the process environment first, then falls back to reading
    $HERMES_HOME/.env directly — plugin handlers do not always run with the
    profile's .env already exported.
    """
    var = f"HERMES_PEER_{name.upper()}_KEY"
    val = os.environ.get(var)
    if val:
        return val
    env_path = os.path.join(_HERMES_HOME, ".env")
    try:
        with open(env_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                if k.strip() == var:
                    return v.strip().strip("'\"") or None
    except FileNotFoundError:
        return None
    except Exception:
        return None
    return None


def list_teammates(args: dict, **kwargs) -> str:
    peers = _load_peers()
    if not peers:
        return json.dumps(
            {
                "teammates": [],
                "note": "No teammates configured. An operator must run: hermes peer add <name> --url <url> --key <key>",
            }
        )
    return json.dumps(
        {
            "teammates": [
                {
                    "name": n,
                    "role_note": p["note"],
                    "reachable": bool(_peer_key(n)),
                }
                for n, p in sorted(peers.items())
            ]
        }
    )


def message_teammate(args: dict, **kwargs) -> str:
    teammate = str(args.get("teammate") or "").strip()
    message = str(args.get("message") or "").strip()

    if not teammate:
        return json.dumps({"error": "No teammate specified. Call list_teammates first."})
    if not message:
        return json.dumps({"error": "No message provided."})

    peers = _load_peers()
    if teammate not in peers:
        return json.dumps(
            {
                "error": f"Unknown teammate '{teammate}'.",
                "known_teammates": sorted(peers.keys()),
            }
        )

    key = _peer_key(teammate)
    if not key:
        return json.dumps(
            {
                "error": f"No API key available for '{teammate}'. "
                f"Expected env var HERMES_PEER_{teammate.upper()}_KEY."
            }
        )

    url = f"{peers[teammate]['url']}/v1/chat/completions"
    payload = json.dumps(
        {
            "model": "hermes-agent",
            "messages": [{"role": "user", "content": message}],
        }
    ).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=_TIMEOUT_S) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8")[:300]
        except Exception:
            pass
        hint = ""
        if e.code == 403:
            hint = "403 usually means the sandbox egress policy does not allow this port."
        elif e.code == 401:
            hint = "401 means the peer API key is wrong or missing."
        return json.dumps(
            {"error": f"{teammate} rejected the request (HTTP {e.code})", "hint": hint, "detail": detail}
        )
    except urllib.error.URLError as e:
        return json.dumps(
            {"error": f"Could not reach {teammate} at {peers[teammate]['url']}: {e.reason}"}
        )
    except Exception as e:  # noqa: BLE001
        return json.dumps({"error": f"Unexpected failure contacting {teammate}: {e}"})

    try:
        reply = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        return json.dumps({"error": "Malformed reply from teammate", "raw": str(body)[:400]})

    usage = body.get("usage") or {}
    return json.dumps(
        {
            "teammate": teammate,
            "reply": reply,
            "tokens": usage.get("total_tokens"),
        }
    )
