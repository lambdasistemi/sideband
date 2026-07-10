# Usage

## Commands

```bash
tg send "PR #12 opened, CI green"       # fire-and-forget notification
tg send --md "*bold*"                   # Markdown, falls back to plain
tg ask "Merge now or wait?"             # blocks; prints the reply; exit 42 on timeout
tg ask --timeout 1800 "…"               # default 600s
tg inbox                                 # print + consume routed messages for this tag
tg open / tg close                       # create-or-reopen / close this tag's forum topic
tg on / tg off                           # hook marker + topic lifecycle in one step
tg daemon run|start|stop|status          # the hub
tg status                                # one screen of channel state
tg setup                                 # one-time chat-id capture (daemon must be off)
```

Each agent is identified by a **tag** — the worktree basename by
default, override with `TG_TAG=my-label`. Every outgoing message is
prefixed `[tag]` in the private chat, or posted plainly inside the
agent's own topic.

## The reporting protocol

An agent doing unattended work follows a simple loop:

1. `tg on` — register the tag, open the agent's topic, arm the
   waiting-on-you hook.
2. On every reporting tick, `tg inbox` — anything it prints is an
   instruction from the operator; acknowledge and act on it.
3. `tg send` only events the operator would act on: milestone done, PR
   opened, CI failed, a blocker, a decision taken on their behalf.
4. `tg ask` for decisions that are theirs — short context, numbered
   options. On exit 42 (timeout) proceed on your own judgment, log the
   assumption, and `send` what you decided; the late reply still lands
   in the inbox.
5. `tg off` when the unattended phase ends — closes the topic (kept for
   reuse).

## From the operator's phone

It is a normal chat. Write in an agent's topic to reach that agent,
write in **General** to reach everyone, send voice notes freely (the
hub transcribes them). When several agents have open questions,
**reply** to the specific question you are answering. There is nothing
else to remember.
