# 3cx

A terminal UI for [3code](https://github.com/capocasa/3code), the economical
coding agent, with the agent embedded.

3code ships its own headless frontend (`threecode/library`) for exactly this
purpose: the same agent loop, tools, sandbox and session store as the CLI, with
the terminal replaced by callbacks. 3cx vendors that source and drives it
directly, so there is no subprocess, no HTTP hop and no second copy of the agent
to keep in sync.

## Build and run

```sh
nimble install illwill   # once
nimble build3cx          # produces ./3cx  (~50s the first time; 3MB of Nim)
./3cx
```

`./3cx` uses 3code's own config, so it needs a provider configured the same way
the CLI does:

```sh
3code provider add <name|url|api-key> --key KEY
```

If no provider resolves, 3cx reports the reason on stderr and exits before
opening the UI; it never substitutes a mock reply for the real agent. Pass
`--mock` to use the offline canned backend deliberately.

Other tasks:

```sh
nimble test       # run the test suite
nimble build       # produces ./3cx
./3cx --mock       # force the offline backend
./3cx -v          # version report, including the vendored 3code revision
```

`./3cx -v` prints the revision the binary was actually built against, which is
what to quote in a bug report:

```
3cx 0.1.0
3code 0.8.2 (ffa46cf) [vendored]
illwill 0.4.1
nim 2.2.12
built for linux/amd64
```

> **Why "threecodex"?** Nim module names must be valid identifiers, so neither
> `3cx.nimble`, `src/3cx/` nor `src/3cx.nim` can exist. The package and entry
> module are therefore spelled `threecodex`, and `nimble build3cx` renames the
> compiled binary to `3cx`.

### Options

| Flag | Meaning |
| --- | --- |
| `--mock` | Offline canned backend for UI development; never selected automatically |
| `-m, --model NAME` | `provider[.model]`, overrides the 3code config |
| `-C, --cwd DIR` | Working directory for tools and the sandbox |
| `-r, --resume` | Resume the latest 3code session for this directory |
| `-v, --version` | Version report, including the vendored 3code revision |
| `-h, --help` | Usage |

Everything also reads from the environment: `THREECX_MODEL`, `THREECX_CWD`,
`THREECX_RESUME=1`, `THREECX_SESSION_DIR`, `THREECX_THEME`. The mock backend
has no environment switch: `--mock` is the only way to select it.

## Slash commands

Anything starting with `/` is a command, not a prompt — the same convention as
3code's own REPL. Type it and press enter like a prompt; no key binding is
involved.

Anything 3code recognises works: `/help`, `/tokens`, `/version`, `/model list`,
`/reasoning list`, `/provider list`, `/sandbox show`, `/sessions`, `/log`,
`/retry`, `/quit`, and the `/!` shell escape.

Two boundaries are worth knowing:

- **Modal commands are refused.** `/provider add` / `/edit` need an interactive
  terminal for their wizard, so they come back as
  `command requires an interactive terminal: ...`. Use the 3code CLI for those.
  Everything non-modal works, including the mutating ones like `/model gpt-5`.
- **`/quit` ends 3cx** rather than reaching 3code, which refuses it from a
  library session.
- **`/model list` lists the config, not the endpoint.** It prints the `models`
  entries from the provider's block in `~/.config/3code/config` — nothing is
  fetched. Adding models still means the 3code CLI, because the commands that
  do it are the modal ones above. It also ignores `-m`: the list follows the
  config's `current`, while the header follows the session.

A `/model <name>` or `/provider <name>` that lands moves the header with it. The
label is read back off the session afterwards, and adopted only when it actually
changed — a read-only command like `/model list` must not quietly replace a `-m`
override with whatever the config says. Replies already in the transcript keep
the label they were written with, which is why each assistant message carries
its own rather than reading the backend's at paint time.

An unrecognised `/foo` is reported as `unknown command: /foo  (try /help)`
rather than sent to the model, so a typo like `/models` does not start a turn.
Only a line that *starts* with `/` is treated this way — prose with a slash in
it (`run ./3cx`) is still an ordinary prompt.

`/version` and `/themes` are answered by 3cx itself rather than passed on, since
neither means anything to the agent. They are matched before the backend is
consulted at all, so they work under `--mock` too, which has no commands of its
own.

## Themes

`/themes` lists the themes and marks the one in force; `/themes <name>` switches
to it and remembers the choice. Dark is the default, light is the other one.

Right now only `/theme dark` and `/theme light` are supported.

## Keybindings

| Key | Action |
| --- | --- |
| `Enter` | Send the prompt |
| `Shift+Enter` / `Ctrl+J` | Insert a newline |
| `↑` / `↓` | Previous/next prompt (when the cursor is on the first/last row) |
| `←` / `→`, `Ctrl+A` / `Ctrl+E`, `Home` / `End` | Move within the prompt |
| `Ctrl+←` / `Ctrl+→` | Move by word |
| `Ctrl+W` | Delete the previous word |
| `Ctrl+U` / `Ctrl+K` | Delete to start / end of row |
| `Ctrl+D` | Delete forward, or quit when the prompt is empty |
| `PgUp` / `PgDn`, mouse wheel | Scroll the transcript |
| `Esc` | Cancel the in-flight turn; if idle, jump to the live tail |
| `Ctrl+C` | Cancel the in-flight turn; if idle, clear the prompt |

Ctrl-C never exits: the terminal turns it into SIGINT rather than a byte, so
the signal is latched by a handler that may only set a flag, and the main loop
turns it into the same key the table above describes. Ctrl-D on an empty prompt
is the way out.

## Session storage

Two files, in one directory:

- **3code's own** `.3log` files, under its session directory, holding the real
  conversation including tool calls. `--resume` picks these up.
- **3cx's** `session.json`, under `$XDG_CONFIG_HOME/3cx` (falling back to
  `~/.config/3cx`), holding only what the UI needs to repaint the transcript:
  role, text, and the model label of each assistant reply, with tool lines
  flattened. It is written on turn start, turn end and exit, and
  `THREECX_SESSION_DIR` overrides the location.
- **3cx's** `config.json`, in the same directory, holding the saved theme.

`session.json` is not the agent's state — 3code owns that. It is a render cache.
Keeping them separate means the UI can be rewritten without migrating 3code
sessions, and a corrupt `session.json` costs you a repaint rather than a
conversation. The same is true of `config.json`: an unreadable or unwritable one
changes nothing but the theme, and never stops the UI from starting.

Both paths deliberately avoid `os.getAppDir`, which on POSIX returns the
directory of the running binary and would drop a file next to the executable.

## Tests

`nimble test` runs the regression test suite.
