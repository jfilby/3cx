# 3cx

A terminal UI for [3code](https://github.com/capocasa/3code) — the economical
coding agent — with the agent **embedded rather than shelled out to**.

3code ships its own headless frontend (`threecode/library`) for exactly this
purpose: the same agent loop, tools, sandbox and session store as the CLI, with
the terminal replaced by callbacks. 3cx vendors that source and drives it
directly, so there is no subprocess, no HTTP hop and no second copy of the agent
to keep in sync.

```
 3cx  commandcode.z-ai/glm-5.3-flash
────────────────────────────────────────────────────────────────
  ▌ you
  say hi

  ▌ commandcode.z-ai/glm-5.3-flash
  Hi! 👋

  ▌ tool
  ● Hi! 👋
────────────────────────────────────────────────────────────────
❯
 enter send  ctrl+j newline  ↑/↓ history  pgup/pgdn scroll  ctrl+d quit
```

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

If no provider resolves, 3cx says so on stderr and falls back to the offline
mock rather than dying — handy for working on the UI without spending tokens.

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
| `--mock` | Offline canned backend; no provider needed |
| `-m, --model NAME` | `provider[.model]`, overrides the 3code config |
| `-C, --cwd DIR` | Working directory for tools and the sandbox |
| `-r, --resume` | Resume the latest 3code session for this directory |
| `-v, --version` | Version report, including the vendored 3code revision |
| `-h, --help` | Usage |

Everything also reads from the environment: `THREECX_BACKEND=mock`,
`THREECX_MODEL`, `THREECX_CWD`, `THREECX_RESUME=1`, `THREECX_SESSION_DIR`,
`THREECX_THEME`.

## Slash commands

Anything starting with `/` is a command, not a prompt — the same convention as
3code's own REPL. Type it and press enter like a prompt; no key binding is
involved.

```
❯ /version
  ▌ you
  /version

  ▌ tool
  3code v0.8.2

❯ /tokens
  ▌ tool
  no tokens used yet
```

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
to it and remembers the choice. Light is the default, dark is the other one.

```
❯ /themes
  ▌ tool
  themes:
    * light  black text on a white canvas
      dark   light text on a black canvas

  current: light
  use /themes <name> to switch

❯ /themes dark
  ▌ tool
  theme: dark (was light)
```

`/theme` works too. The choice is saved to `config.json` next to the session
document, so it survives a restart; `THREECX_THEME=dark` overrides the file for
one run, and a name that matches no theme — in the file or on the command line —
leaves the current one in place rather than failing.

A theme owns the **whole** palette, canvas and bars included, and the app paints
its own canvas rather than trusting the terminal's background: a light theme over
an unknown background is unreadable in one direction or the other, so it commits.
The cost is that a light 3cx is white even in a dark shell, and the margins
between messages are the theme's rather than your terminal's.

Illwill only offers the eight ANSI colours, and terminals disagree on what those
names mean — GNOME Terminal's `bgWhite` is a light grey and its `bgBlack` a
near-black. Two measures keep the canvases true and the text legible anyway:

- **The three background slots are redefined.** On startup, on a `/themes`
  switch and until exit, 3cx pins palette slot 0 to pure black, slot 7 to
  pure white and slot 4 — which backs the bars' `bgBlue` — to `#1c3f7a`
  (OSC 4), and moves the terminal's default foreground/background onto the
  theme's canvas colours (OSC 10/11) so resize gaps match the canvas. Since
  only SGR 40, 44 and 47 are ever used as backgrounds, the dark canvas is
  genuinely black, the light one genuinely white, and white bar text holds
  ~10:1 on the dark theme's blue however the terminal defines its blue. On
  exit the slots are reset (OSC 104/110/111), handing the terminal its own
  colours back. Foreground slots are left alone — the reset forms mean
  nothing is stolen permanently. (Slot 4 doubles as `fgBlue` in the light
  theme's headings and code; the pin lifts that text on white to 10.3:1.)
- **Every foreground field is chosen for the worst canvas it can land on.**
  The light theme draws canvas text only in black, blue, magenta and red
  (green, yellow and cyan wash out on a light background), and the dark one
  never uses blue, whose dark-palette shade all but vanishes on a black
  canvas. Body text is 21:1 against the pinned canvases.

Colours reach the screen through `colText`, `colCode`, `colBarBg` and friends:
the same names the render code already used, now reading `currentTheme` at the
moment they are used instead of being baked in at compile time. The transcript is
rebuilt every frame, so a switch lands on the next one with nothing to re-parse
or invalidate. Adding a theme is a `Theme(...)` literal in `theme.nim` plus a
line in its `themes` table.

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

## Layout

```
+--------------------------------------------------+
| header: app name + backend                       |  row 0
|--------------------------------------------------|  row 1
|                                                  |
| transcript (scrollable, follows the tail)        |  rows 2 .. msgBottom
|                                                  |
|--------------------------------------------------|  inputTop - 1
| > multi-line prompt                              |  inputTop .. statusY-1
|--------------------------------------------------+
| status bar / keybinding hints                    |  row height-1
+--------------------------------------------------+
```

## Module map

| Module | Responsibility |
| --- | --- |
| `types.nim` | `Chat` / `Message` / `Role`. No terminal dependency. |
| `backend.nim` | The `Backend` interface, `Chunk`, and the `MockBackend`. |
| `threecode_backend.nim` | Drives a vendored 3code `AgentSession`. |
| `version.nim` | Build identity, including the vendored 3code revision. |
| `uwidth.nim` | Unicode display width, rune-boundary walking, hard breaking. |
| `keyevent.nim` | UTF-8 + modifier aware stdin decoder (see below). |
| `markdown.nim` | Markdown subset → styled `Line`/`Span` values, word-wrapped. |
| `theme.nim` | The named themes (`light`, `dark`) and the palette in one place. |
| `inputbox.nim` | Multi-line prompt editor with history recall. |
| `session.nim` | JSON transcript persistence. |
| `config.nim` | Saved preferences — currently the theme. |
| `app.nim` | Layout, key handling, the non-blocking main loop. |

The main loop is deliberately simple and never waits on I/O:

```nim
while not app.quit:
  var tb = getBuffer()
  for ev in app.reader.poll(0):
    app.handleEvent(ev, lay.msgHeight)
  app.drainBackend()
  render(tb, app)
  tb.display()
  sleep(15)
```

## The 3code integration

`Backend` is a pull-based, non-blocking interface: `start` kicks off a turn and
`nextChunk` hands back one event at a time. 3code's library API maps onto it
almost one to one.

| 3code | here |
| --- | --- |
| `initAgentSession` | `newThreeCodeBackend` |
| `onEvent` | `push` onto a lock-protected queue |
| `promptAsync` / `prompt` | `start`, on our own worker thread |
| `interrupt` | `interrupt` (bound to `Esc`) |
| `command` / `classifyCommand` | `runCommand`, `isCommand`, `isQuitCommand` |
| `close` | `stop`, which joins the worker first |

Events arrive on the worker thread and are drained by the main loop. That
lock-protected queue is the entire concurrency story: the UI never blocks, and
`nextChunk` returns `ckNone` when the worker has nothing ready yet.

`Backend` was widened from a bare `string` to a typed `Chunk` (`ckText`,
`ckReasoning`, `ckTool`, `ckNotice`, `ckError`) because 3code distinguishes
assistant prose from tool output and harness notices, and collapsing those into
one string would lose the distinction the transcript renders.

### Threading note

3code's `promptAsync` returns `Thread[TurnJob]` where `TurnJob` is private to
`library`, so the handle cannot be named in order to join it. The backend
therefore spawns its own worker with a payload type it owns and calls the
blocking `prompt` from there — which also means `stop` can genuinely join
before tearing the session down, rather than leaving a thread reading a freed
session at exit.

### Vendoring

`vendor/threecode` holds 3code's `src/` at a pinned commit (MIT). See
`vendor/threecode/VENDOR.md` for how to bump it — including the two constants in
`version.nim` that `-v` reports. Two build settings had to be mirrored in
`config.nims`, because Nim does not read 3code's own root config for a vendored
copy:

- `-d/ssl` — without it `streamhttp` fails to compile
  (`undeclared identifier: cachedTlsContext`).
- `-d/version=0.8.2` — 3code's own config reads `threecode.nimble`, which is not
  vendored, so without a value `{.strdefine.}` falls back to `"devel"` and leaks
  into user-visible output (`/version` printing `3code vdevel`). This one is
  easy to forget because nothing fails to compile.
- a single include path root — 3code's modules import each other both bare
  (`import types`) and package-qualified (`import threecode/unicodewidth`), so
  one root is needed. A second root compiles some modules twice under different
  mangled names and fails to link with `multiple definition of terminalLock`.

These live in `config.nims` rather than in the `.nimble` file because `switch()`
does not reach a nimble `task` that shells out to `nim c` itself.

## Input decoding

illwill 0.4.1 reads stdin one byte at a time and maps each byte onto its `Key`
enum. That has three consequences, all of which `keyevent.nim` removes:

| Problem | Cause |
| --- | --- |
| Non-ASCII input silently dropped | bytes above `0x7F` map to no `Key` value |
| Modifiers lost | only `Key.ShiftA`/`Key.CtrlA` survive, and only for letters |
| **Ctrl+Arrow does nothing at all** | `ESC [ 1 ; 5 A` is read as `ESC [ 1`, fails to match, and is *discarded* |

None of that information is missing from the terminal — `ESC [ 1 ; 5 A` encodes
Ctrl+Up perfectly well. illwill simply throws it away. So `keyevent.nim` reads
stdin directly, reassembles escape sequences across reads (a single `read` can
return half a sequence), and decodes UTF-8, xterm modifier parameters, kitty
CSI-u (which is how modern terminals deliver `Shift+Enter`) and SGR mouse
reports.

It also fixes a bug illwill was hiding. illwill's `consoleInit` clears
`ICANON` and `ECHO` but leaves the input flags alone, so `ICRNL` stays enabled
and the terminal driver rewrites a carriage return (`0x0D`) into a newline
(`0x0A`) before the library reads it. illwill can get away with that because it
maps *both* onto `Key.Enter`; a decoder that keeps Enter and Ctrl+J distinct
would otherwise see every Enter as a newline. `enableRawInput` clears `ICRNL`
(and `IXON`, so Ctrl+S cannot freeze the terminal) after `illwillInit`.

`ISIG` is deliberately left on, so Ctrl-C still terminates a wedged process —
but it also means the byte never reaches the decoder. `installCtrlCHook`
catches the signal with a handler that does nothing but latch a flag (a signal
handler may not allocate, take a lock or write to the terminal), and `poll`
reports it as `Key.CtrlC`. That is what makes Ctrl-C "cancel the turn" rather
than "kill the UI", and why a second Ctrl-C during shutdown is harmless.

The parser is separated from the reader — `parse` is pure, bytes in and events
out — so it is unit tested without a tty.

## Plugging in another agent

`Backend` is the whole integration surface. A different agent needs a
constructor plus three methods — `start`, `nextChunk`, and optionally
`isDone`, `interrupt` and `stop`:

```nim
method start(b: Backend, prompt: string) {.base.}
method nextChunk(b: Backend): Chunk {.base.}   ## must never block
```

Nothing in `app.nim` or `markdown.nim` changes. Return `ckNone` from
`nextChunk` when there is nothing ready; the UI treats that as "keep waiting",
not "the turn is over". `isDone` must only report true once the queue has
drained, or the last events of a turn are lost.

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

## Known limitations

- **Mock replies do not stream tool events.** The mock only produces `ckText`,
  so the tool/notice rendering paths are exercised against real 3code only.
- **`runCommand` is wired to the UI.** A leading `/` is intercepted on submit;
  see "Slash commands" above.
- **Themes are limited to eight colours.** illwill has no indexed or RGB
  colour, so a theme is a choice out of the eight ANSI names — and terminals
  map those names to different shades, which the palettes in `theme.nim`
  already account for (see "Themes" above). A third theme is a `Theme(...)`
  literal, not a palette to tune.
- **A theme paints the canvas, so the background stops being the terminal's.**
  See "Themes" above; it is the price of a light theme that is legible in a dark
  shell.
- **The decoder is POSIX-only.** On Windows `poll` falls back to translating
  illwill's `getKey`, so the Unicode and modifier behaviour does not apply.
- **Reasoning traces are stored but not visually separated.** `ckReasoning`
  arrives as its own message, but renders like any other tool line.
- **No key is bound to commands.** By design — they are typed, not bound. The
  gap is history: a submitted `/model x` lands in prompt history like anything
  else, so `↑` recalls it but there is no completion for command names (3code's
  own `pathCompletions` is file-path completion, not command completion).
- **3code's `aevTool` is a transcript-line hook, not a tool event.** `toolCode` is
  `-1` for everything it emits, and it fires once per paint — so both the
  assistant's *partial reply* and its *reasoning* arrive as growing sequences of
  commits, each a word or two longer than the last. Treating each as a tool
  result painted a staircase of near-identical lines. `applyChunk` now compares
  against the message being streamed and skips anything that is (or extends) it,
  after stripping leading decoration. Reasoning is dropped outright: it is the
  model's internal deliberation, not conversation, and 3code still writes it to
  its own `.3log` session.
  **Known rough edge:** a genuine tool result whose text happens to be a prefix
  of the reply would also be swallowed. Unlikely, but not distinguished.
- **Modified special keys are consumed, not acted on.** Ctrl+Home,
  Ctrl+Backspace and friends decode correctly, but the UI only binds
  `Ctrl+Left`/`Ctrl+Right` (word motion).
- **No nested emphasis.** `**bold**`, `*italic*` and `` `code` `` are parsed,
  but not combinations like `**bold `code`**`.
- **The transcript is re-rendered every frame.** Fine at this scale; a long
  conversation would want dirty-tracking and a cached wrap.
- **Hanging indents are measured in codepoints**, which is exact for the ASCII
  markers used, but would be wrong for a wide glyph in a prefix.
- **3code's build warnings are not ours to fix.** The vendored source compiles
  with a handful of deprecation warnings; they are left alone rather than
  patched, so bumping the revision stays a clean copy.

### Why not a newer illwill?

Upgrading would buy nothing. `v0.4.1` is the latest tag, HEAD is 10 commits past
it, and the exported API is identical — zero additions, zero removals. HEAD's
`parseStdin` is the same byte-at-a-time function. Both limitations above are
tracked upstream ([#10](https://github.com/johnnovak/illwill/issues/10) is still
open, and the maintainer has said he is not coming back to it), so the decoder is
a local fix rather than something to wait for.

## Tests

`nimble test` runs 131 checks. Note that they do **not** import the vendored
3code, so they compile in seconds and need no provider:

- `tests/test_threecodex.nim` — Unicode width and hard-breaking, the Markdown
  renderer, the input editor, session round-tripping (including every `Role`
  surviving the role↔string mapping, and the per-message model stamp round-
  tripping as well as degrading to empty in a pre-stamp file), the transcript
  role labels, the chunk types, and the style→SGR mapping. The theme tests read
  a real `TerminalBuffer` after a real frame, since a theme is only ever visible
  as painted cells: the canvas, the two bars, and the fact that a switch
  repaints all of it.
- `tests/test_keyevent.nim` — the decoder: UTF-8 including runes split across
  reads, the Enter/Ctrl+J distinction, xterm modifier bitmasks, kitty CSI-u,
  SGR mouse, and sequences split across several reads.

The 3code backend is verified against a **real agent**, not a fake — it is
driven through a pty with a live provider, and the rendered frame plus the
session JSON are asserted.

The drawing layer is also exercised end-to-end: the binary is driven inside a
pseudo-terminal and the escape stream replayed through a small terminal
emulator; a resize sweep checks it survives 3x10 through 60x200; UTF-8 and
`Shift+Enter` are verified by typing them through a pty and asserting the text
round-trips through the session file. The drawing code is straight-line
blitting, but testing it through a real terminal is what actually catches
layout and escape-sequence mistakes — the `ICRNL` bug was found this way and is
invisible to unit tests. Both themes are checked the same way, since a theme is
only ever visible in the painted cells: `/themes dark` mid-session, and the
choice surviving a restart.