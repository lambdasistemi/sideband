# Why sideband is different

sideband is **not a harness, a control plane, or an approval gateway.**
It is a communication *affordance* handed to the agent — a skill it
chooses to use — so it can reach the operator on its own initiative
while it works.

That distinction is the whole point, so it is worth being precise about
it.

## Control planes vs. side channels

Most human-in-the-loop tooling for agents today is a **control plane**:
an external layer that wraps or intercepts the agent and gates what it
is allowed to do.

- Permission proxies like [Airlock](https://airlock.bot/) sit in front
  of the agent, intercept every tool call, and hold sensitive ones for
  human approval.
- Framework primitives like Google ADK's `LongRunningFunctionTool`, or
  [n8n approval workflows](https://n8n.io/workflows/9039-create-secure-human-in-the-loop-approval-flows-with-postgres-and-telegram/),
  pause the agent's own graph until a human clicks approve/deny.
- Orchestration harnesses drive the agent from the outside — starting,
  stopping, and steering it.

All of these put the human (or a proxy) **in control of the agent's
execution.** The agent is the thing being governed.

sideband inverts that relationship. There is no proxy, no interception,
no gate. The agent runs exactly as it always would. sideband simply
gives it a **phone** — a way to *call out* to the operator when the
agent itself judges it useful: a milestone worth reporting, a decision
it would rather the human make, a blocker it is stuck on. The operator
can reply, and that reply flows back as ordinary input — but the
operator is **not driving the agent through the channel.** Control
stays where it was: with the agent's own reasoning.

The name is literal. In signal processing a *sideband* carries
information alongside the main carrier without being the carrier
itself. sideband-the-tool is a channel running alongside the agent's
normal operation, not the path that operates it.

| | Control plane / harness | sideband |
|---|---|---|
| Who initiates | The human / proxy intercepts the agent | The **agent** reaches out |
| Where control lives | Outside the agent | Inside the agent's reasoning |
| Mechanism | Proxy, interception, framework hook, orchestrator | A **skill** + a CLI the agent calls |
| Agent execution | Gated / paused / steered | Untouched |
| Failure if removed | Agent can't act | Agent just can't *talk* |

## A skill, not a framework — and model-agnostic

sideband is not tied to any one agent runtime. It is:

- a small CLI (`tg`), and
- a [SKILL.md](https://agentskills.io) any compatible agent discovers
  and loads.

So the *same* channel serves a Claude Code session, an OpenAI Codex
agent, and a Gemini agent side by side — each appears as its own topic
in the operator's group, each decides for itself when to speak. Nothing
about sideband assumes a particular model or vendor; adopting it is
loading a skill, not installing a runtime.

This is why it lives in the operator's **workflow** by default: every
agent that starts real work opens its topic and arms its inbox watcher,
regardless of which model is behind it.

## Pioneering, honestly

Agent-initiated notification is an emerging idea — the phrase "agents
should reach out only when a decision needs a human" shows up across
recent write-ups. But the implementations almost universally reach for
the control-plane shape: a gateway that intercepts, a framework tool
that pauses, a bot bolted onto one vendor's runtime.

sideband stakes out a different and, as far as we can find,
under-explored point in the design space:

- **agent-owned, not agent-gating** — the capability belongs to the
  agent, not to a proxy in front of it;
- **skill-based, not proxy-based** — no interception layer, no MCP
  gateway, no framework lock-in;
- **model-agnostic** — one channel across Claude, Codex, and Gemini;
- **multiplexed by design** — many concurrent agents, one bot, a topic
  each, replies routed back to the right one.

We are not claiming nobody has ever sent an agent's message to
Telegram. We are claiming that treating the side channel as a
*skill the agent wields* — rather than a *harness that wields the
agent* — is a distinct and largely un-trodden approach, and the one
sideband is built to explore.
