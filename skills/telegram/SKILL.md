---
name: telegram
description: Send notifications and blocking questions to the operator's Telegram so they can intervene remotely while the agent runs unattended, using the compiled `tg` binary (sideband). Load whenever the user says notify me on telegram, ask me on telegram, ping me on telegram, telegram me, keep me posted remotely, report via Telegram, or before starting long unattended work where the user said they will be away. Covers tg send/ask/inbox, per-agent forum topics (tg open/close/on/off), the hub daemon, and voice-note transcription.
---

# Telegram Channel (sideband)

One bot, one forum group, many agents. Every agent sends tagged
messages to the operator's Telegram; a single hub daemon owns the
inbound direction and routes the operator's replies (text or
transcribed voice) to per-agent inboxes. The `tg` binary does
everything; no scripts.

## Who uses this

The epic owner / orchestrator (or a solo session working directly for
the operator). Workers report up through their normal protocol; the
owner decides what is worth the operator's phone buzzing. Each agent
is identified by a tag — default is the worktree basename, override
with `TG_TAG=my-label`.

## Commands

```bash
tg send "PR #12 opened, CI green"       # fire-and-forget notification
tg send --md "*bold*"                   # Markdown, falls back to plain
tg ask "Merge now or wait?"             # blocks; prints the reply; exit 42 on timeout
tg ask --timeout 1800 "…"               # default 600s
tg inbox                                 # print + consume routed messages for this tag
tg open / tg close                       # create-or-reopen / close this tag's forum topic
tg on / tg off                           # hook marker + topic lifecycle in one step
tg daemon run|start|stop|status          # the hub (systemd runs `tg daemon run`)
tg status                                # one screen of channel state
tg setup                                 # one-time chat-id capture (daemon must be off)
```

## Protocol

1. `tg status` — if the daemon is down, `tg daemon start` (under the
   NixOS module it is already running). If chat id is missing, walk
   the operator through Setup below.
2. `tg on` at the start of unattended work: registers the tag, opens
   the agent's own forum topic (its channel on the operator's phone),
   and arms the `.tg-notify` hook marker (git-excluded automatically).
3. On every reporting tick run `tg inbox` — anything it prints is an
   instruction or question from the operator: acknowledge with a
   `send` and act on it. An unchecked inbox is a dead letterbox.
4. Send events the operator would act on, and nothing else: milestone
   done, PR opened, CI failed, blocker hit, decision taken on their
   behalf. If it would not change what they do next, do not send it.
5. For decisions that are theirs, `tg ask` — short context, numbered
   options, one line each. Match the reply loosely ("1", "yes",
   "merge"). On exit 42 proceed on your own judgment, log the
   assumption, and `send` what you decided; a late reply still lands
   in the inbox.
6. `tg off` when the unattended phase ends — it closes the topic
   (kept for reuse; `tg on` reopens it).

Never lecture the operator about tags, topics, or routing — from
their side it is a normal chat: write in an agent's topic to reach
that agent, write in General to reach everyone, send voice notes
freely (the hub transcribes them). A channel that needs a manual is a
failed channel.

## Setup (one-time, operator)

1. Create a bot with @BotFather; put the token in the env file
   (default `~/.config/sideband/env`, override `TG_AGENT_ENV`):
   `AGENT_TELEGRAM_BOT_TOKEN=<token>`
2. `tg setup` — the operator messages the bot once; the chat id is
   captured.
3. For per-agent topics: create a group, add the bot, enable Topics
   (the group becomes a supergroup — the id changes), make the bot
   admin with Manage Topics, and set `AGENT_TELEGRAM_GROUP_ID=<id>`.
4. For voice notes: run a whisper-server and set `WHISPER_URL`.
5. Start the hub: `tg daemon start`, or enable the NixOS module
   (`services.sideband`).

## Failure modes

- `ask` refuses to run without the daemon — start it; there is no
  direct-polling fallback (one getUpdates consumer per token is a
  Telegram rule, and the daemon is it).
- Timeout (exit 42) is not failure: proceed sensibly and report.
- Do not run `tg inbox` concurrently with your own pending `ask` —
  they consume the same inbox.
