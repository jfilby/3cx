## The 3code backend.
##
## 3code ships its own headless frontend (`threecode/library`) precisely for
## this: the same agent loop, tools, sandbox and session store as the CLI, with
## the terminal replaced by return values and callbacks. So this is not an
## integration over a process boundary or an HTTP API - it is a compile-time
## dependency, and the pieces map almost one to one:
##
## | 3code                     | here                                  |
## |---------------------------|---------------------------------------|
## | `initAgentSession`        | `newThreeCodeBackend`                 |
## | `onEvent`                 | `push` onto a locked queue           |
## | `promptAsync` / `prompt`  | `start` on our own worker thread      |
## | `interrupt`               | `stop` (bound to `Esc`)               |
## | `command`                 | `runCommand` (bound to `/` prompts)   |
##
## Threading: 3code's `prompt` is blocking, and `promptAsync` returns a
## `Thread[TurnJob]` whose payload type `TurnJob` is private to `library`, so
## there is no way to name the handle in order to join it. Rather than reflect
## around that, the backend spawns its own worker with a payload type it owns
## and calls the blocking `prompt` from there - which also means `close` can
## genuinely join before tearing the session down.
##
## Events arrive on the worker thread and are handed to the UI's main loop
## through `nextChunk`, which must not block. Hence the lock-protected queue:
## that is the entire concurrency story.

import std/[deques, locks, math, os, strutils]
import threecode/library
import threecode/compact
import threecode/config
# `classifyCommand` / `CommandKind` are how 3code itself decides whether a line is
# a command, so reuse that rather than re-deriving the rule from a leading '/'.
import threecode/ui

import ./backend

type
  TurnJob = ref object
    ## Payload for the worker thread. Thread procs cannot capture, so the
    ## session and prompt travel in one heap box.
    backend: ThreeCodeBackend
    prompt: string

  ThreeCodeBackend* = ref object of Backend
    ## Drives a 3code `AgentSession` and adapts it to the `Backend` interface.
    session: AgentSession
    queue: Deque[Chunk]  ## Events drained by `nextChunk` on the UI thread.
    lock: Lock
    finished: bool       ## The worker has returned.
    running: bool        ## A worker thread is alive.
    worker: Thread[TurnJob] ## Handle for the in-flight turn, joined on close.

# ---------------------------------------------------------------------------
# Queue plumbing. Called from both the worker thread and the UI thread.
# ---------------------------------------------------------------------------

proc push(b: ThreeCodeBackend, c: Chunk) {.gcsafe.} =
  acquire(b.lock)
  b.queue.addLast(c)
  release(b.lock)

proc markFinished(b: ThreeCodeBackend) {.gcsafe.} =
  acquire(b.lock)
  b.finished = true
  release(b.lock)

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newThreeCodeBackend*(model = "", cwd = "", resume = false,
                         experimental = false): ThreeCodeBackend =
  ## Open a 3code session and wrap it as a `Backend`.
  ##
  ## Raises `AgentError` when no provider is configured, the model does not
  ## resolve, another live 3code process holds the directory/session lock, or
  ## the config file exists but cannot be read.

  # `loadStateOrEmpty` calls the vendor's `die` when a config file exists but
  # cannot be opened, and `die` quits the process instead of raising. The CLI
  # wants that; 3cx instead reports the problem and exits rather than dying
  # inside the library with no explanation. Turn the same condition into the
  # AgentError the caller already handles.
  let cfgPath = configPath()
  if fileExists(cfgPath):
    try:
      discard readFile(cfgPath)
    except CatchableError as e:
      raise newException(AgentError, "cannot read " & cfgPath & ": " & e.msg)

  var opts = AgentOptions(experimental: experimental)
  if model.len > 0: opts.model = model
  if cwd.len > 0: opts.cwd = cwd
  opts.resume = resume

  var b = ThreeCodeBackend()
  initLock(b.lock)
  b.session = initAgentSession(opts)
  # `initAgentSession` disables engine output (headless mode), which makes
  # `syncWrite` - and with it the terminal tab title - a silent no-op. 3cx
  # owns its own terminal, so the vendor's terminal output stays disabled.

  # `name` drives the header, so prefer the model when one was requested.
  b.name = if model.len > 0: model else: b.session.profileLabel()

  b.session.onEvent = proc(ev: AgentEvent) =
    case ev.kind
    of aevDelta:
      if ev.text.len > 0: b.push(Chunk(kind: ckText, text: ev.text))
    of aevReasoning:
      if ev.text.len > 0: b.push(Chunk(kind: ckReasoning, text: ev.text))
    of aevTool:
      if ev.text.len > 0: b.push(Chunk(kind: ckTool, text: ev.text))
    of aevRetry, aevNotice:
      if ev.text.len > 0: b.push(Chunk(kind: ckNotice, text: ev.text))
    of aevDone:
      discard                      # usage is available via `usageLine`
    of aevError:
      b.push(Chunk(kind: ckError, text: ev.text))

  result = b

# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

proc turnWorker(job: TurnJob) {.thread.} =
  ## Runs one turn. Never raises: failures become a `ckError` chunk so the UI
  ## can render them like any other event.
  {.cast(gcsafe).}:
    let b = job.backend
    try:
      discard b.session.prompt(job.prompt)
    except CatchableError as e:
      b.push(Chunk(kind: ckError, text: e.msg))
    finally:
      b.markFinished()

method start*(b: ThreeCodeBackend, prompt: string) =
  ## Kick off a turn on a worker thread and return immediately.
  acquire(b.lock)
  b.queue.clear()
  b.finished = false
  release(b.lock)

  b.running = true
  createThread(b.worker, turnWorker, TurnJob(backend: b, prompt: prompt))

method nextChunk*(b: ThreeCodeBackend): Chunk =
  ## Pop one queued event, or `ckNone` if the worker has not produced one yet.
  acquire(b.lock)
  if b.queue.len > 0:
    result = b.queue.popFirst()
  release(b.lock)

method isDone*(b: ThreeCodeBackend): bool =
  ## Done when the worker has returned *and* its queue has drained, so the last
  ## events of a turn are never dropped.
  acquire(b.lock)
  result = b.finished and b.queue.len == 0
  release(b.lock)

# ---------------------------------------------------------------------------
# Control surface
# ---------------------------------------------------------------------------

method interrupt*(b: ThreeCodeBackend) =
  ## Ask the in-flight turn to stop. Bound to `Esc` in the UI.
  if not b.isDone():
    b.session.interrupt()

method supportsCommands*(b: ThreeCodeBackend): bool =
  true

method commandPrefix*(b: ThreeCodeBackend): char =
  '/'

proc toCommand*(text: string): string =
  ## 3code's command surface is introduced by `:`, but this UI documents `/`,
  ## so a slash line is translated into the colon command it means before the
  ## library sees it. Anything else is handed over untouched.
  let c = text.strip
  if c.len > 0 and c[0] == '/':
    ":" & c[1 .. ^1]
  else:
    text

proc asSlashCommands*(body: string): string =
  ## Rewrite 3code's `:command` tokens as `/command`, the prefix this UI
  ## documents, so help output can be typed back the way it is shown.
  ##
  ## The same shape `renderHelpS` highlights: a colon followed by a command
  ## word. A colon before anything else - `https://`, `note: ...` - is left
  ## alone, which is why this is a scan rather than a blanket replace.
  result = newStringOfCap(body.len)
  var i = 0
  while i < body.len:
    if body[i] == ':' and i + 1 < body.len and
       body[i + 1] in {'a' .. 'z', 'A' .. 'Z', '?', '!'}:
      result.add '/'
      inc i
      while i < body.len and body[i] in {'a' .. 'z', 'A' .. 'Z', '?', '!'}:
        result.add body[i]
        inc i
    else:
      result.add body[i]
      inc i

method isCommand*(b: ThreeCodeBackend, text: string): bool =
  ## 3code classifies a leading-`:` line itself; `/` is this UI's spelling of
  ## the same prefix.
  classifyCommand(toCommand(text)) != ckUnknown

method isQuitCommand*(b: ThreeCodeBackend, text: string): bool =
  classifyCommand(toCommand(text)) == ckQuit

method runCommand*(b: ThreeCodeBackend, cmd: string): string =
  ## Run a 3code slash command (`/tokens`, `/model ...`, `/sandbox show`, ...)
  ## and return its plain-text body.
  ##
  ## `AgentSession.command` returns a plain error string for modal commands
  ## (`/provider add`) rather than raising, and raises only for `/quit`, which
  ## the caller intercepts before getting here.
  let line = toCommand(cmd)
  let before = b.session.profileLabel()
  try:
    result = b.session.command(line)
  except CatchableError as e:
    result = e.msg
  if line == ":help" or line == ":?":
    # The help lists its commands as `:tokens`, but here they are typed with a
    # slash; spelling them 3code's way would hand the user lines this UI sends
    # to the model as prompts.
    result = asSlashCommands(result)

  # `/model <name>` and `/provider <name>` move the session's profile, and the
  # header names it, so the label has to follow or it goes stale - `b.name` was
  # set once at construction and nothing else rewrites it.
  #
  # Adopt the new label only when it actually moved. A read-only command like
  # `/model list` leaves the profile alone, and adopting unconditionally would
  # quietly replace an `-m` override with the config's profile: the header would
  # flip away from the model the user asked for just because they typed a
  # command that changed nothing. A refused switch (unknown model, or one the
  # known-good gate rejects) also leaves the profile alone, which is right.
  let after = b.session.profileLabel()
  if after.len > 0 and after != before:
    b.name = after

proc usageLine*(b: ThreeCodeBackend): string =
  ## Cumulative token usage for the session, or "" if nothing has been used.
  let u = b.session.usage()
  if u.totalTokens == 0:
    return ""
  result = $u.totalTokens & " tokens" &
           (if u.cachedTokens > 0: " (" & $u.cachedTokens & " cached)" else: "")

proc formatTokens*(n: int): string =
  ## A token count in the compact form a bar has room for: `"942"`,
  ## `"8.3K"`, `"148K"`, `"1.0M"`.
  ##
  ## A raw six-digit count would crowd the header on a laptop-width terminal,
  ## and the digit it costs buys nothing at a glance.
  if n < 1000:
    return $n
  const units = ["K", "M", "G"]
  var
    v = n.float
    u = -1
  while v >= 999.5 and u < units.high:
    v /= 1000.0
    inc u
  let shown = if v >= 100.0: $int(v.round) else: formatFloat(v, ffDecimal, 1)
  result = shown & units[u]

method contextUsageLine*(b: ThreeCodeBackend): string =
  ## Context window usage as "8.3K (8%)" for the header bar, or "" if
  ## unknown. Uses the vendor's `contextWindowFor` heuristic and the
  ## session's current `promptTokens`.
  ##
  ## A `method`, not a `proc`: `App` reads this through its `Backend` field, so
  ## a proc here would only shadow the base method and the header would render
  ## blank.
  let u = b.session.usage()
  if u.promptTokens == 0:
    return ""
  let window = compact.contextWindowFor(b.name)
  if window <= 0:
    return ""
  let pct = int(u.promptTokens.float / window.float * 100.0)
  result = formatTokens(u.promptTokens) & " (" & $pct & "%)"

proc close*(b: ThreeCodeBackend) =
  ## Interrupt, join the worker, then persist and release the session.
  ##
  ## Order matters: the worker touches `b.session`, so it must be joined before
  ## the session is torn down, or the thread would be reading a freed session
  ## while the process exits.
  if not b.isDone():
    b.session.interrupt()
  if b.running:
    joinThread(b.worker)
    b.running = false
  b.session.close()
  deinitLock(b.lock)

method stop*(b: ThreeCodeBackend) =
  close(b)