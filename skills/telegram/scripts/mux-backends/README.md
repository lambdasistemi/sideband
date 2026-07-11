# Writing a `mux` backend

The Telegram liaison needs exactly two terminal-multiplexer tricks: **spawn a
sibling pane** (for itself) and **inject a submitted line into another pane**
(to grab the epic owner's attention). A backend teaches `mux` how to do those
under one particular multiplexer. Ship tmux by default; add your own for
zellij, screen, wezterm, kitty, or anything that can open a pane and type into
one.

You implement **four bash functions** in a file under `mux-backends/`, then
select it with `SIDEBAND_MUX`. That's the whole job.

## Selecting a backend

`mux` resolves `SIDEBAND_MUX` (default `tmux`) as either:

- a bare name → `mux-backends/<name>` next to the `mux` script, or
- an absolute path → your own backend file kept anywhere (outside this repo is
  fine).

```bash
export SIDEBAND_MUX=zellij            # → scripts/mux-backends/zellij
export SIDEBAND_MUX=/etc/my-mux.sh    # → your own file
```

`go-mobile` propagates the choice to the liaison pane automatically, so you set
it once before launching.

## Handles

A **handle** is an opaque string your backend uses to name one pane — a tmux
pane id (`%42`), a screen `session:window`, a zellij pane name, whatever. `mux`
treats handles as opaque: `spawn`/`self` produce them, `inject`/`focus` consume
them, and nothing in between inspects them. The only requirement is that a
handle stays valid for the pane's lifetime.

## The four functions

Your file is **sourced** by `mux` (not executed), so define functions — no
shebang, no top-level side effects. `mux` parses the command line, sets the
inputs below, and calls one function.

| Function | Inputs | Must produce |
|---|---|---|
| `mux_self` | — | print this pane's handle to **stdout** |
| `mux_spawn` | `MUX_CMD`, `MUX_ENV`, `MUX_FROM` | open a sibling pane, print its handle to **stdout** |
| `mux_inject` | `$1` handle, `$2` text | type + submit `text` into that pane |
| `mux_focus` | `$1` handle | focus/select that pane |

### `mux_self`
Print a handle for the **current** pane (the one this shell runs in) to stdout,
one line. Used by `go-mobile` to capture the epic owner's pane before spawning
the liaison. If you can't be identified (not running inside the multiplexer),
exit non-zero with a message on stderr.

```bash
mux_self() { printf '%s\n' "${TMUX_PANE:?not inside tmux}"; }
```

### `mux_spawn`
Open a new pane **adjacent to** `MUX_FROM` (a handle; default: the current
pane), run the command, and print the **new pane's handle** to stdout. Inputs
arrive as globals, because they're arrays:

- `MUX_CMD` — array: the command and its arguments to run in the new pane.
- `MUX_ENV` — array of `KEY=VALUE` strings to set in the new pane's environment
  (may be empty; guard with `${#MUX_ENV[@]}`).
- `MUX_FROM` — handle to split from, or empty for "current pane".

Two ways to apply `MUX_ENV`, pick what your multiplexer supports:

- **Per-pane env flag** (tmux): map each pair to `-e KEY=VALUE`.
- **`env` prefix** (portable, for multiplexers that only inherit the parent
  env): run `env "${MUX_ENV[@]}" "${MUX_CMD[@]}"`.

If your multiplexer doesn't print a new-pane id you can capture, pre-assign a
pane **name** and echo that name as the handle (see the zellij hints in
`EXAMPLE`).

### `mux_inject`
Grab attention on `$1` and submit `$2` as a single input line. This is the one
operation with real subtlety, because the target is a live agent's TUI:

1. **Interrupt first.** Send whatever your multiplexer uses to deliver an
   `Escape` keystroke, so a busy/idle agent stops and reads the input line.
2. **Type the text literally**, then submit (`Enter`).
3. **Re-submit if it didn't take.** Injecting mid-loop is flaky — the `Enter`
   sometimes doesn't register. Wait briefly and, if the text is still sitting
   unsent, submit again. The tmux backend does this by capturing the pane and
   re-sending `Enter` when the text is still visible at the prompt; if you have
   no capture primitive, an unconditional second `Enter` after a short sleep is
   a safe fallback (a stray empty submit is harmless).
4. **Return immediately.** Never block waiting for the agent's reply — the reply
   comes back out-of-band through the `from-epic` channel file.

### `mux_focus`
Select `$1` so it's the visible/active pane. Best-effort: return 0 even if your
multiplexer can't focus by handle (`go-mobile` uses it only as a courtesy to
put the operator back on the epic pane).

## Testing your backend

Run the conformance harness **inside the multiplexer you're implementing**:

```bash
SIDEBAND_MUX=<yourmux> skills/telegram/scripts/mux-selftest
# or:  skills/telegram/scripts/mux-selftest <yourmux>
```

It drives `self`, `spawn` (with `--env`), `inject`, and `focus` through your
backend and verifies the observable results via temp files — so it needs no
multiplexer-specific capture support and works for any backend. It opens a few
short-lived panes that close themselves. All four checks must pass before the
liaison will work reliably.

You can also exercise verbs by hand:

```bash
mux self                                  # prints a handle
h=$(mux spawn --env FOO=bar -- sh -c 'echo $FOO; sleep 5')   # prints new handle
mux inject "$h" -- "hello"                # 'hello' appears in that pane
mux focus "$h"
```

## Reference implementations

- **`tmux`** — the working default; read it first, it's the shortest complete
  backend.
- **`EXAMPLE`** — an annotated skeleton to copy, with the four stubs and the
  closest known zellij/screen commands in comments.
