# Repository Agent Guide

## What this repo is

sideband is a Telegram side channel for unattended coding agents: a
compiled `tg` binary for tagged notifications, blocking questions,
per-agent forum topics, and a hub daemon that routes the operator's
replies (text or transcribed voice notes) to per-agent inboxes.

## How to work here

- Enter the dev shell: `nix develop`
- Build: `just build` — Test: `just unit` — Everything CI runs: `just CI`
- Style: fourmolu (see `fourmolu.yaml`), `just format`
- Haskell, GHC 9.12.3 via haskell.nix; warnings are errors

## Skills

Activatable procedures live under `skills/`:

- `skills/telegram/` — how an agent uses the `tg` channel during
  unattended work (send/ask/watch protocol, topic lifecycle, the
  go-mobile liaison, setup).

To use the skill on a machine, install the whole `skills/telegram/`
directory (its `SKILL.md` and `scripts/`) onto your agent's skills path
— e.g. `ln -s "$PWD/skills/telegram" ~/.claude/skills/telegram`. See
[docs/installation.md](docs/installation.md#the-agent-skill).

## First-run setup

Operator-specific configuration (bot token, chat id, group id,
whisper URL) lives in an env file outside the repo — default
`~/.config/sideband/env`, override with `TG_AGENT_ENV`. The
`skills/telegram/SKILL.md` Setup section describes the interview.
