## The agent backend interface.
##
## The UI never talks to a model directly. It drives a `Backend` by calling
## `start` once per turn and then pumping `nextChunk` from the main loop until
## that returns an empty string.
##
## Keeping the backend a pull-based, non-blocking generator means a real
## streaming implementation (3code, an HTTP SSE client, ...) can be dropped in
## later without touching the event loop or the rendering code.

import strutils

type
  ChunkKind* = enum
    ckNone = 0  ## Nothing pending; the `nextChunk` "no data" sentinel.
    ckText      ## Assistant prose, appended to the reply being streamed.
    ckReasoning ## Model reasoning trace, rendered separately.
    ckTool      ## A committed tool result line.
    ckNotice    ## Harness notice: retry, steering, compaction, usage.
    ckError     ## The turn failed.

  Chunk* = object
    kind*: ChunkKind
    text*: string

  Backend* = ref object of RootObj
    name*: string      ## Short identifier shown in the status bar.
    prompt*: string    ## Prompt for the turn currently in flight.

method start*(b: Backend, prompt: string) {.base.} =
  ## Begin a new turn. Called exactly once per user message.
  discard

method nextChunk*(b: Backend): Chunk {.base.} =
  ## Return the next slice of the reply, or `ckNone` when nothing is ready.
  ##
  ## Called from the UI's main loop, so implementations must never block. A
  ## backend with work running on its own thread buffers results and hands them
  ## back one at a time.
  Chunk(kind: ckNone)

method isDone*(b: Backend): bool {.base.} =
  ## True when there is nothing left to stream.
  true

method interrupt*(b: Backend) {.base.} =
  ## Ask an in-flight turn to stop. Called when the user presses `Esc`, and
  ## again during shutdown.
  discard

method stop*(b: Backend) {.base.} =
  ## Release backend-owned resources. Called once, on the UI thread, after the
  ## loop has ended and the transcript has been saved.
  discard

method supportsCommands*(b: Backend): bool {.base.} =
  ## True if this backend has commands at all.
  ##
  ## Paired with `commandPrefix`, which says what introduces one.
  false

method commandPrefix*(b: Backend): char {.base.} =
  ## The character a line must start with to be read as a command, or `'\0'`
  ## when the backend has none.
  ##
  ## The UI needs this to tell a mistyped command (`/models`) apart from prose
  ## that merely starts with a slash, which is why it is separate from
  ## `isCommand`.
  '\0'

method isCommand*(b: Backend, text: string): bool {.base.} =
  ## True if `text` names a command this backend would handle.
  ##
  ## False for an unrecognised name; the caller decides whether to report that
  ## as unknown or forward the line to the model.
  false

method isQuitCommand*(b: Backend, text: string): bool {.base.} =
  ## True if `text` asks to end the session.
  false

method runCommand*(b: Backend, cmd: string): string {.base.} =
  ## Execute `cmd` and return its plain-text result for the transcript.
  "commands are not supported by this backend"

method contextUsageLine*(b: Backend): string {.base.} =
  ## Context window usage as "83.6K (8%)" for the status bar, or "" if unknown.
  ""

# ---------------------------------------------------------------------------
# Mock backend
# ---------------------------------------------------------------------------

type
  MockBackend* = ref object of Backend
    text*: string    ## Full canned reply for this turn.
    pos*: int        ## How much of `text` has been emitted so far.
    chunkSize*: int  ## Characters emitted per tick.

proc newMockBackend*(name = "mock"): MockBackend =
  ## Create a backend that streams a canned, markdown-heavy reply.
  result = MockBackend(name: name)
  result.chunkSize = 2

proc mockReply*(prompt: string): string =
  ## Build a reply that echoes the prompt and exercises every renderer feature.
  ##
  ## Deliberately covers headings, emphasis, inline code, fenced code, bullet
  ## and ordered lists, block quotes and horizontal rules so the markdown
  ## renderer can be exercised without talking to a real model.
  result = "## Got it\n\n" &
    "You said:\n\n" &
    "> " & prompt.replace("\n", " ") & "\n\n" &
    "Here is how the renderer handles the usual suspects.\n\n" &
    "### Lists\n\n" &
    "- **Bold** text, `inline code`, and *italic* prose\n" &
    "- A second bullet that is long enough that the wrapper has to fold it " &
      "across more than one terminal row to prove that it works\n" &
    "- A third bullet\n\n" &
    "1. Ordered items\n" &
    "2. Are numbered\n" &
    "3. And wrap\n\n" &
    "### Code\n\n" &
    "```nim\n" &
    "proc greet(name: string): string =\n" &
    "  \"Hello, \" & name\n" &
    "\n" &
    "echo greet(\"3cx\")\n" &
    "```\n\n" &
    "---\n\n" &
    "That is the whole mock. Press **Ctrl+D** to quit, or keep typing."

method start*(b: MockBackend, prompt: string) =
  b.prompt = prompt
  b.text = mockReply(prompt)
  b.pos = 0

method nextChunk*(b: MockBackend): Chunk =
  if b.pos >= b.text.len:
    return Chunk(kind: ckNone)
  let n = min(b.chunkSize, b.text.len - b.pos)
  result = Chunk(kind: ckText, text: b.text[b.pos ..< b.pos + n])
  b.pos += n

method isDone*(b: MockBackend): bool =
  b.pos >= b.text.len