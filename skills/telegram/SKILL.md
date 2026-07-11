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
tg next                                  # block for ONE message, print it, exit (liaison receive)
tg forward FILE                          # tail a channel file, send each line to the topic (liaison upward)
tg watch                                 # tail the append-only inbox log (audit stream)
tg inbox                                 # one-shot: print + consume pending messages
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
3. **Watch your append-only inbox log — this is being on the channel.**
   The hub appends every message the operator sends you, one line each,
   to a plain **append-only file**:
   ```
   ~/.local/state/sideband/tags/<tag>/inbox.log
   ```
   Because it is append-only, reading it never removes anything — a slow,
   idle, or restarted agent never loses a message, and there is nothing to
   "eat". `tg watch` is just a `tail -F` of that file; you may equally
   `tail -f` the file yourself. This is fully agent-independent.

   Set it up so new lines reach your reasoning, and leave it running for
   your whole lifetime:

   - **Claude Code**: wrap the tail in a persistent `Monitor` so each line
     becomes a notification in your loop:
     ```
     Monitor(command: 'tg watch', persistent: true)
     ```
   - **Codex / Gemini / other**: tail the file into your view, e.g. a
     background `tg watch &` (or `tail -f …/inbox.log &`), and read it at
     the start and end of every turn.

   Acknowledge each message with a `send` and act on it. An unread message
   is a dropped ball. (`tg inbox` is a one-shot manual drain of the spool;
   it is not the watcher.)
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

## Liaison mode (an epic owner "goes mobile")

When the operator, watching an epic owner, says "load telegram / I'm
leaving", the epic owner does **not** start watching Telegram itself —
that distracts it and a turn-based agent can't be woken by a file. It
**spawns a dedicated liaison agent** in a new multiplexer pane whose only
job is the channel, then returns to its work. Two directions, two
mechanisms:

- **Downward (operator → epic owner): a pane-inject, only to grab
  attention.** A file cannot wake a busy/idle agent, so the liaison
  interrupts the epic owner's pane and injects the instruction as input.
  This is the one place a terminal-multiplexer trick is needed, and it is
  wrapped in the `mux` adapter (`scripts/mux inject <handle> -- "…"`) so it
  works under any multiplexer, not just tmux (see **Pluggable multiplexer**
  below). The adapter handles the flaky-mid-loop re-submit itself.
- **Upward (epic owner → operator): a plain channel file, no
  screen-scraping.** The epic owner appends one line per reply/report to
  `~/.local/state/sideband/tags/<window>/from-epic`; `tg forward` tails it
  and sends each line to the topic.

### Epic owner, on "go mobile"

Run one command from your own pane — it spawns the liaison and returns:

```bash
~/.claude/skills/telegram/scripts/go-mobile <window-tag> [liaison-agent-cmd]
# e.g.  go-mobile keri-e21                      # Claude liaison (default)
#       go-mobile keri-e21 'codex exec'         # Codex liaison
```

`go-mobile` creates the channel file, splits a pane below you, and starts
`scripts/liaison` there (which opens the topic, runs `tg forward`, and loops
`tg next` handing each message to the agent). Then:

1. Adopt one habit: whenever you finish an instruction, hit a milestone, or
   block, append **one line** to `~/.local/state/sideband/tags/<window>/from-epic`.
   You never call `tg` yourself.
2. Go back to work. The liaison pokes your pane only for real instructions.

### Liaison brief (the spawned pane)

```
You are the Telegram liaison for window <window> (tag <window>). Epic
owner pane: <epic-pane>. Status file: <STATUS.md>. Channel: <from-epic>.

Setup once:
  export TG_TAG=<window>; tg on
  tg send "liaison online for <window>"
  tg forward <from-epic> &          # relay the epic owner's lines up

Loop forever — one Telegram message per turn:
  msg=$(tg next)
  - Status/progress question answerable from <STATUS.md>? Read it and
    `tg send` the answer. Do NOT disturb the epic owner.
  - Control message for you (stop, are-you-there)? Handle it yourself.
  - Real instruction/decision for the epic owner? Grab attention + inject
    with one command (never screen-scrape; the reply returns via
    <from-epic>). The `mux` adapter does the interrupt, type, and re-submit:
      scripts/mux inject <epic-pane> -- "[Telegram from Paolo] $msg. When
        done append ONE line to <from-epic>, then resume your work."
    Return to `tg next` immediately.
```

The epic owner is interrupted only for real instructions, the only
multiplexer trick is the attention-grab, and everything it *says* returns
through the file channel.

### Pluggable multiplexer

The liaison needs exactly two multiplexer operations — spawn a sibling
pane (`go-mobile`) and inject a submitted line into the epic owner's pane
(the liaison). Both go through `scripts/mux`, so nothing hard-wires tmux:

```bash
mux self                                   # handle for this pane
mux spawn [--from H] [--env K=V]... -- CMD # sibling pane, prints its handle
mux inject <handle> -- "text"              # attention-grab + submit, with retry
mux focus <handle>
```

The backend is chosen by `SIDEBAND_MUX` (default `tmux`) and resolved from
`scripts/mux-backends/<name>` — or an absolute path to your own file. To run
under zellij, screen, wezterm, or anything else, copy
`scripts/mux-backends/EXAMPLE` to `scripts/mux-backends/<yourmux>`, implement
the four functions (`mux_self`, `mux_spawn`, `mux_inject`, `mux_focus`), and
`export SIDEBAND_MUX=<yourmux>` before running `go-mobile`. The choice
propagates to the liaison pane automatically.

The full contract — inputs, outputs, handle semantics, and the inject
attention-grab/re-submit rules — is in **`scripts/mux-backends/README.md`**.
Verify a new backend by running the conformance harness inside that
multiplexer:

```bash
SIDEBAND_MUX=<yourmux> scripts/mux-selftest   # self / spawn+env / inject / focus
```

It checks all four verbs via temp files (no per-multiplexer capture needed);
all must pass before the liaison works reliably.

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
