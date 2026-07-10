# Installation

## The binary

```bash
nix run github:lambdasistemi/sideband -- status
# or into the profile:
nix profile install github:lambdasistemi/sideband
```

## The hub daemon

The hub is the only Telegram poller; every agent reads its routed
messages from the spool. Run it per machine:

```bash
tg daemon start
```

Or, on NixOS, enable the module:

```nix
{
  inputs.sideband.url = "github:lambdasistemi/sideband";
  # ...
  imports = [ sideband.nixosModules.default ];
  services.sideband = {
    enable = true;
    user = "youruser";                     # same user the agents run as
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

Spool state lives in `~/.local/state/sideband` (override with
`TG_STATE`).

## First-run setup

1. Create a bot with [@BotFather](https://t.me/BotFather); put the
   token in the env file as `AGENT_TELEGRAM_BOT_TOKEN`.
2. `tg setup` — message the bot once; the chat id is captured.
3. For per-agent topics: create a group, add the bot, enable Topics
   (the group becomes a supergroup — its id changes), make the bot
   admin with **Manage Topics**, and set `AGENT_TELEGRAM_GROUP_ID`.
4. For voice notes: run a
   [whisper-server](https://github.com/paolino/whisper-server) and set
   `WHISPER_URL`.
5. Start the hub: `tg daemon start`.
