# Usage

## Commands

```bash
tg send "PR #12 opened, CI green"       # fire-and-forget notification
tg send --md "*bold*"                   # Markdown, falls back to plain
tg ask "Merge now or wait?"             # blocks; prints the reply; exit 42 on timeout
tg ask --timeout 1800 "…"               # default 600s
tg watch                                 # tail the append-only inbox log (being on the channel)
tg next                                  # block for ONE message, print it, exit (exit 42 on timeout)
tg inbox                                 # one-shot: print + consume the spool for this tag
tg forward FILE                          # tail a file, send each new line to the topic
tg open / tg close                       # create-or-reopen / close this tag's forum topic
tg on / tg off                           # hook marker + topic lifecycle in one step
tg daemon run|start|stop|status          # the hub
tg status                                # one screen of channel state
tg setup                                 # one-time chat-id capture (daemon must be off)
```

`watch`/`next`/`inbox` are the three ways to read: `watch` tails the
non-consuming [inbox log](architecture.md#the-inbox-log-being-on-the-channel)
and is how you *stay* on the channel; `next` blocks for a single message
then exits; `inbox` is a one-shot drain of the spool. `forward` is the
upward half of [liaison mode](#going-mobile-liaison).

Each agent is identified by a **tag** — the worktree basename by
default, override with `TG_TAG=my-label`. Every outgoing message is
prefixed `[tag]` in the private chat, or posted plainly inside the
agent's own topic.

## The reporting protocol

An agent doing unattended work follows a simple loop:

1. `tg on` — register the tag, open the agent's topic, arm the
   waiting-on-you hook.
2. **Watch the inbox log for your whole lifetime** — this *is* being on
   the channel. Because the log is append-only, a message is never lost
   to a slow or restarted agent, and there is nothing to race over.
   - Claude Code: `Monitor(command: 'tg watch', persistent: true)`
   - Codex / Gemini / shell: `tg watch &` (or `tail -f …/inbox.log`)
   Acknowledge each line with a `send` and act on it; an unread message
   is a dropped ball. (`tg inbox` is a one-shot manual drain, not the
   watcher.)
3. `tg send` only events the operator would act on: milestone done, PR
   opened, CI failed, a blocker, a decision taken on their behalf.
4. `tg ask` for decisions that are theirs — short context, numbered
   options. On exit 42 (timeout) proceed on your own judgment, log the
   assumption, and `send` what you decided; the late reply still lands
   in the inbox.
5. `tg off` when the unattended phase ends — closes the topic (kept for
   reuse).

## Going mobile (liaison)

When the operator is leaving but wants to keep talking to a running epic
owner from a phone, the epic owner doesn't watch Telegram itself — it
spawns a dedicated **liaison** in a sibling pane and goes back to work:

```bash
go-mobile <window-tag> [liaison-agent-cmd]   # e.g. go-mobile keri-e21
```

The liaison owns the topic, answers status questions from the epic
owner's `STATUS.md`, and interrupts the epic owner only for real
instructions. The epic owner's one habit is to append a line to its
`from-epic` file whenever it finishes an instruction, hits a milestone,
or blocks — `tg forward` relays those up. It runs under tmux by default
and any other multiplexer via `SIDEBAND_MUX`; see
[Architecture → Going mobile](architecture.md#going-mobile-the-liaison).

## From the operator's phone

It is a normal chat. Write in an agent's topic to reach that agent,
write in **General** to reach everyone, send voice notes freely (the
hub transcribes them). When several agents have open questions,
**reply** to the specific question you are answering. There is nothing
else to remember.
