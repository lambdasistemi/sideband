# sideband

Telegram side channel for unattended coding agents.

One bot, one forum group, many agents: each agent gets its own forum
topic as an ephemeral channel on the operator's phone. Agents send
tagged notifications and blocking questions; a single hub daemon owns
the inbound direction, routes the operator's replies to per-agent
inbox spools, and transcribes voice notes through a
[whisper-server](https://github.com/paolino/whisper-server).

sideband is **not** a harness or an approval gateway. It doesn't
intercept or control the agent — it's a **skill the agent chooses to
use** to reach out on its own initiative, and it's model-agnostic
(Claude, Codex, Gemini). That distinction is the point; see
[Why sideband is different](docs/philosophy.md).

```bash
tg send "PR #12 opened, CI green"
answer=$(tg ask "Merge now or wait for review?")
tg inbox        # instructions the operator sent meanwhile
```

## Install

```bash
nix run github:paolino/sideband -- status
# or into the profile:
nix profile install github:paolino/sideband
```

The hub daemon runs per machine. Either `tg daemon start`, or on
NixOS:

```nix
{
  inputs.sideband.url = "github:paolino/sideband";
  # ...
  imports = [ sideband.nixosModules.default ];
  services.sideband = {
    enable = true;
    user = "youruser";  # same user the agents run as
    environmentFile = "/home/youruser/.config/sideband/env";
  };
}
```

## Configuration

An env file (default `~/.config/sideband/env`, override with
`TG_AGENT_ENV`):

```
AGENT_TELEGRAM_BOT_TOKEN=...   # from @BotFather
AGENT_TELEGRAM_CHAT_ID=...     # captured by `tg setup`
AGENT_TELEGRAM_GROUP_ID=...    # forum supergroup for per-agent topics
WHISPER_URL=http://localhost:9003/transcribe   # voice notes (optional)
```

Spool state lives in `~/.local/state/sideband` (`TG_STATE` to
override).

## Agents

This repo ships its own agent skill: see
[AGENTS.md](AGENTS.md) and `skills/telegram/SKILL.md` for the
protocol coding agents follow on the channel (any agent supporting
the [agentskills.io](https://agentskills.io) convention picks it up).

## Development

`nix develop`, then `just --list`. CI runs `just CI` (build, unit
tests, fourmolu check, hlint).
