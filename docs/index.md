# sideband

A Telegram side channel for unattended coding agents.

One bot, one forum group, many agents. Each agent gets its own forum
topic — an ephemeral channel on the operator's phone. Agents send
tagged notifications and blocking questions; a single hub daemon owns
the inbound direction, routes the operator's replies to per-agent
inbox spools, and transcribes voice notes through a whisper-server.

```bash
tg send "PR #12 opened, CI green"
answer=$(tg ask "Merge now or wait for review?")
tg watch        # stay on the channel: tail the append-only inbox log
```

When the operator leaves, an epic owner can `go-mobile` — spawn a
liaison that keeps the phone channel alive without distracting the work.

## Why

An agent running unattended needs two things the terminal cannot give
it while the operator is away: a way to surface events worth acting on,
and a way to ask a question and get an answer. sideband is that channel
— the agent keeps working, the operator intervenes from a phone.

Unlike the approval gateways and orchestration harnesses that *control*
an agent from the outside, sideband is a **skill the agent chooses to
use** — agent-initiated, non-intercepting, and model-agnostic (Claude,
Codex, Gemini). See [Why sideband is different](philosophy.md).

## Next

- [Installation](installation.md) — install the `tg` binary and run the hub.
- [Usage](usage.md) — the command surface and the reporting protocol.
- [Architecture](architecture.md) — how routing and the hub work.
