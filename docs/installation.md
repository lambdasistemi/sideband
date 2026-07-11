# Installation

## The binary

=== "Nix"

    ```bash
    nix run github:lambdasistemi/sideband -- status
    # or into the profile:
    nix profile install github:lambdasistemi/sideband
    ```

=== "macOS (Homebrew, Apple Silicon)"

    ```bash
    brew tap lambdasistemi/tap
    brew install sideband
    tg --help
    ```

=== "Linux (AppImage / DEB / RPM)"

    Grab an artifact from the
    [releases page](https://github.com/lambdasistemi/sideband/releases/latest):

    ```bash
    curl -L https://github.com/lambdasistemi/sideband/releases/latest/download/sideband.AppImage -o tg
    chmod +x ./tg
    ./tg --help
    ```

    Or install the `.deb` / `.rpm` from the same release.

## The hub daemon

The hub is the only Telegram poller; every agent reads its routed
messages from the spool. Run it per machine:

```bash
tg daemon start
```

Or run it as a managed service.

=== "home-manager (systemd user service)"

    Runs the hub under your user, as the same user the agents run as:

    ```nix
    {
      inputs.sideband.url = "github:lambdasistemi/sideband";
      # ...
      imports = [ sideband.homeManagerModules.default ];
      services.sideband = {
        enable = true;
        environmentFile = "%h/.config/sideband/env";
      };
    }
    ```

=== "NixOS (system service)"

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

## The agent skill

The `tg` binary is the transport; the **skill** is the protocol an agent
follows on the channel — when to `send`, `ask`, and `watch`, the topic
lifecycle, and how to go mobile with a liaison. It ships in this repo
under `skills/telegram/` and follows the
[agentskills.io](https://agentskills.io) convention, so any compatible
agent picks it up once it is on that agent's skills path.

Install it by placing the **whole** `skills/telegram/` directory — its
`SKILL.md` **and** its `scripts/` — where your agent discovers skills:

=== "Claude Code"

    ```bash
    mkdir -p ~/.claude/skills
    # symlink the checkout so it tracks updates:
    ln -s "$PWD/skills/telegram" ~/.claude/skills/telegram
    # …or copy a snapshot instead:
    # cp -a skills/telegram ~/.claude/skills/telegram
    ```

=== "Codex / Gemini / other"

    Point the agent at this repo's `skills/` directory, or copy
    `skills/telegram/` into the skills path your agent scans. Any client
    that follows the agentskills.io convention discovers it. See
    [AGENTS.md](https://github.com/lambdasistemi/sideband/blob/main/AGENTS.md).

Install the **directory**, not just `SKILL.md`: the liaison helpers
(`go-mobile`, `mux`, `mux-selftest`, and the multiplexer backends) live in
`skills/telegram/scripts/` and must sit beside it. Verify they came
across by running the multiplexer conformance test from inside tmux —
it should report `5 passed, 0 failed`:

```bash
~/.claude/skills/telegram/scripts/mux-selftest
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
4. For voice notes: run a whisper-server and set `WHISPER_URL` (see
   [Voice notes](#voice-notes-speech-to-text) below).
5. Start the hub: `tg daemon start`.

## Voice notes (speech-to-text)

Voice notes are **optional** and require an extra dependency: a running
[whisper-server](https://github.com/paolino/whisper-server) reachable at
`WHISPER_URL`. When configured, the hub downloads each voice (or audio)
message, posts it to the server's `/transcribe` endpoint, and routes the
transcription exactly like a typed message (prefixed with 🎤).

Without `WHISPER_URL`, voice notes are **silently dropped** (with a log
line) — text messaging is unaffected.

### Run the server

=== "Docker"

    ```bash
    docker run -d --name whisper-server --restart unless-stopped \
      -p 9003:9003 \
      -e WHISPER_MODEL=small \
      -e WHISPER_HTTP_PORT=9003 \
      -e WHISPER_DEVICE=auto \
      -e WHISPER_COMPUTE_TYPE=auto \
      ghcr.io/paolino/whisper-server:latest
    ```

=== "Nix"

    ```bash
    nix run github:paolino/whisper-server
    ```

Then point sideband at it:

```
WHISPER_URL=http://localhost:9003/transcribe
```

The `/transcribe` endpoint accepts an `audio` multipart field (Telegram
voice notes arrive as `.oga`) and returns `{"text": "..."}`. The model
(`WHISPER_MODEL`) trades accuracy for latency — `small` is a good
default; `base` is faster, `medium` more accurate.

!!! note
    whisper-server exposes a WebSocket on `9002` and the HTTP
    `/transcribe` endpoint on `9003`. sideband uses only the HTTP
    endpoint, so publishing `9003` is sufficient.
