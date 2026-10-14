## The 3cx terminal UI: layout, event handling and the main loop.
##
## Layout is deliberately fixed-function, in the style of illwill's immediate
## mode examples:
##
## ```
## +--------------------------------------------------+
## | header: app name + backend                       |  row 0
## |--------------------------------------------------|  row 1
## |                                                  |
## | transcript (scrollable, follows the tail)        |  rows 2 .. msgBottom
## |                                                  |
## |--------------------------------------------------|  inputTop - 1
## | > multi-line prompt                              |  inputTop .. statusY-1
## +--------------------------------------------------+
## | status bar / keybinding hints                    |  row height-1
## +--------------------------------------------------+
## ```
##
## The loop is non-blocking: it polls for one key, advances the streaming
## backend by one chunk, redraws and sleeps. Nothing ever waits on I/O, so a
## real network backend can replace the mock without restructuring anything.

import std/[os, strutils, times, unicode]
import illwill
# illwill declares its own `ForegroundColor`, `BackgroundColor` and `Style`,
# which collide with the identically named types in `terminal`. Excluding those
# three lets us reach `setCursorPos` for the real cursor without an import
# alias - in Nim 2 `import M as alias` still leaks the module's names into
# scope, so aliasing alone would not help.
import terminal except ForegroundColor, BackgroundColor, Style
import ./theme
import ./uwidth
import ./markdown
import ./inputbox
import ./keyevent
import ./config
import ./session
import ./selection
import ./clipboard
import ./types
import ./backend
import ./version
import threecode/tabtitle

const
  sideMargin  = 2      ## Columns of breathing room on each side.
  minWidth    = 24     ## Below this the layout stops trying to be pretty.
  copyFlashSecs = 1.5  ## How long a "copied" message holds the status bar.

const
  spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    ## The terminal-tab spinner glyphs, rotating while a turn streams. The
    ## same braille frames 3code's own GUI footer uses.

type
  App* = ref object
    chat*: Chat
    input*: InputBox
    backend*: Backend
    reader: InputReader     ## UTF-8 / modifier aware stdin decoder.
    streaming*: bool
    streamIdx*: int        ## Index of the message `ckText` appends into.
    scroll*: int          ## Lines scrolled back from the tail; exported so the
                          ## edge auto-scroll can be tested with a known window.
    transcript*: seq[Line]  ## Rows as last rendered; see `visibleStart`.
    quit*: bool             ## Set by Ctrl-D on an empty prompt and `/quit`;
                            ## exported so the exit keys are testable.
    turnError: bool        ## The in-flight turn produced an error chunk; the
                            ## tab title settles to ✗ instead of ✓. Also set on
                            ## user interrupt, which surfaces as a ckError.
    sel*: Selection       ## Mouse selection, in transcript coordinates.
    selecting: bool       ## Left button held: a drag is in flight.
    pointerX: int         ## Last pointer cell, for edge auto-scroll.
    pointerY: int
    pendingCopy: string   ## Selection waiting to be handed to the clipboard.
    copyMsg: string       ## Status-bar text shown after a copy.
    copyMsgUntil: float   ## `epochTime` deadline for `copyMsg`.

# ---------------------------------------------------------------------------
# Terminal buffer management
# ---------------------------------------------------------------------------

var gBuffer: TerminalBuffer

proc getBuffer(): TerminalBuffer =
  ## The current frame buffer, reallocated only when the terminal is resized.
  ##
  ## Falls back to a tiny 1x1 buffer when the terminal reports no size. That
  ## happens when stdout is not a tty (redirected, or run under a harness):
  ## `illwillInit` restores the screen on the way out by moving to the bottom
  ## row, and that arithmetic underflows at height 0. A 1x1 buffer is below the
  ## render guard, so the loop simply draws nothing rather than crashing.
  let
    w = if terminalWidth() > 0: terminalWidth() else: 1
    h = if terminalHeight() > 0: terminalHeight() else: 1
  if gBuffer == nil or gBuffer.width != w or gBuffer.height != h:
    gBuffer = newTerminalBuffer(w, h)
  result = gBuffer

# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------

proc spanStyle*(s: Span): set[Style] =
  ## Map a span onto illwill's style flags.
  ##
  ## On POSIX these go out as `ESC[<ordinal>m`, so the flag *is* the SGR code:
  ## `styleBright` is 1 (bold), `styleItalic` is 3, `styleUnderscore` is 4.
  ##
  ## Bold is `styleBright`, **not** `styleBlink`. Despite the stdlib's
  ## "blinking/bold text" comment, `styleBlink` is 5 - actual SGR 5, a literal
  ## slow blink. Using it here made every heading and bold run flash.
  if s.bold:
    result.incl styleBright
  if s.italic:
    result.incl styleItalic
  if s.underline:
    result.incl styleUnderscore

proc applyCanvas(tb: var TerminalBuffer) =
  ## Reset the buffer to the theme's resting colours: body text on the canvas.
  ##
  ## `resetAttributes` would send the background back to `bgNone`, which means
  ## "whatever the terminal's background is" - and a theme that paints a canvas
  ## of its own would show the terminal through every margin, rule and bar
  ## edge. So the state to return to after drawing is the theme, not the
  ## terminal.
  tb.setForegroundColor(colText)
  tb.setBackgroundColor(colBg)
  tb.setStyle({})

proc applySpan(tb: var TerminalBuffer, s: Span) =
  ## Load a span's colours and style flags into the buffer's current state.
  tb.setForegroundColor(s.fg)
  # A span that names no background of its own sits on the canvas. `bgNone`
  # would be *transparent*, which the terminal resolves against its own
  # background rather than the theme's - so the canvas would show through the
  # text of a light theme.
  tb.setBackgroundColor(if s.bg == bgNone: colBg else: s.bg)
  tb.setStyle(spanStyle(s))

proc drawLine(tb: var TerminalBuffer, y: int, x0: int, line: Line,
              maxWidth: int, selFrom = -1, selTo = -1) =
  ## Blit one rendered line at `(x0, y)`, clipped to `maxWidth` columns.
  ##
  ## `selFrom`/`selTo` bound the selection within the line - display columns,
  ## `-1` for none - and the default is a plain blit. The selected stretch is
  ## painted with the selection colours but keeps the span's own bold and
  ## italic flags, so a selection across a heading does not flatten it.
  if y < 0 or y >= tb.height or maxWidth <= 0:
    return
  var x = x0
  for s in line.spans:
    let remaining = maxWidth - (x - x0)
    if remaining <= 0:
      break
    let text = truncateToWidth(s.text, remaining)
    if text.len == 0:
      continue
    let (a, b, c) = splitSelected(text, selFrom - (x - x0), selTo - (x - x0))
    if a.len > 0:
      tb.applySpan(s)
      tb.write(x, y, a)
      x += displayWidth(a)
    if b.len > 0:
      tb.setForegroundColor(colSelect)
      tb.setBackgroundColor(colSelectBg)
      tb.setStyle(spanStyle(s))
      tb.write(x, y, b)
      x += displayWidth(b)
    if c.len > 0:
      tb.applySpan(s)
      tb.write(x, y, c)
      x += displayWidth(c)
  applyCanvas(tb)

proc drawBar(tb: var TerminalBuffer, y: int, text: string, bg: BackgroundColor,
             fg: ForegroundColor, styles: set[Style] = {}) =
  ## A full-width bar, used for the header and the status bar.
  if y < 0 or y >= tb.height:
    return
  tb.setBackgroundColor(bg)
  tb.setForegroundColor(fg)
  tb.setStyle(styles)
  tb.fill(0, y, tb.width - 1, y, " ")
  let visible = truncateToWidth(text, tb.width)
  tb.write(0, y, visible)
  applyCanvas(tb)

proc padStatus(left, right: string, w: int): string =
  ## Left- and right-justify two chunks across a bar `w` columns wide, padding
  ## the gap with spaces. When the two would collide the left chunk wins, so
  ## the truncated bar stays readable rather than wrapping.
  ##
  ## Tabs would be simpler, but every terminal expands them to its own stops -
  ## so the right-hand chunk lands somewhere different everywhere.
  let lw = displayWidth(left)
  let rw = displayWidth(right)
  let gap = max(w - lw - rw, 1)
  result = left & " ".repeat(gap) & right

# ---------------------------------------------------------------------------
# Transcript
# ---------------------------------------------------------------------------

proc roleLabel(role: Role, backendName: string): tuple[label: string, col: ForegroundColor] =
  case role
  of rUser: ("you", colUser)
  of rAssistant: (backendName, colAssistant)
  of rTool: ("tool", colTool)
  of rSystem: ("system", colError)

proc buildTranscript*(app: App, width: int): seq[Line] =
  ## Render the whole chat to styled lines, re-wrapped to `width` columns.
  ##
  ## Exported because the role labels it stamps on each message are tested
  ## through it: a wrong label is invisible from the shell, which is the whole
  ## class of bug this module's other tests exist for.
  let bodyWidth = max(width - 2 * sideMargin, 8)
  for i, m in app.chat.messages:
    if i > 0:
      result.add Line()
    # Each message carries the label of whatever produced it, so a `/model`
    # switch relabels the header and the messages that follow, not the ones
    # already in the transcript. An unstamped message (restored from an older
    # session file) falls back to the backend's current name.
    let label0 = if m.model.len > 0: m.model else: app.backend.name
    let (label, col) = roleLabel(m.role, label0)
    var header: Line
    header.addSpan Span(text: "\u258c ", fg: col, bold: true)
    header.addSpan Span(text: label, fg: col, bold: true)
    result.add header

    let body = if m.role == rUser or m.role == rTool:
                 renderPlain(m.content, bodyWidth)
               else:
                 renderMarkdown(m.content, bodyWidth)
    result.add body

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

type
  Layout* = object
    ## Where each part of the window lands for a given size. Exported because
    ## the screen-to-transcript mapping is tested through it.
    msgTop*: int
    msgHeight*: int
    inputTop*: int
    inputRows*: int
    statusY*: int

proc computeLayout(app: App, w, h: int): Layout =
  let
    statusY = h - 1
    inputRows = app.input.visibleLineCount(maxVisibleLines)
    inputTop = statusY - inputRows
    msgTop = 2
    msgBottom = inputTop - 2
    msgHeight = max(msgBottom - msgTop + 1, 1)
  result = Layout(msgTop: msgTop, msgHeight: msgHeight, inputTop: inputTop,
                  inputRows: inputRows, statusY: statusY)

proc visibleStart(app: App, msgHeight: int): int =
  ## Transcript row to draw at the top of the message area.
  ##
  ## `scroll` counts lines back from the tail and is clamped to the transcript
  ## that exists right now - which can change between events, since a frame
  ## that has not been rendered yet still holds the previous wrap. Called by
  ## the event loop and by the renderer so both agree on what is on screen.
  let maxScroll = max(app.transcript.len - msgHeight, 0)
  app.scroll = app.scroll.clamp(0, maxScroll)
  maxScroll - app.scroll

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc cursorLine*(line: string, col: int): Line =
  ## Render `line` with a block cursor at byte offset `col`.
  ##
  ## The cursor is drawn into the buffer rather than by moving the real terminal
  ## cursor. `tb.display()` relocates the real cursor as it writes, so a real
  ## cursor ends up wherever the last diff write stopped — a second block one
  ## row up — and has to be repositioned every frame, which reads as a flash. A
  ## cursor painted into the buffer can do neither: it moves only when the user
  ## moves it, and it is never visible in two places at once.
  let cut = min(col, line.len)
  let before = line[0 ..< cut]
  # Take the whole rune under the cursor, not just its first byte: `line[cut]`
  # is a byte, and slicing a multi-byte rune in half yields a replacement char.
  let atEnd = if cut < line.len: offsetRight(line, cut) else: line.len
  let at = if cut < line.len: line[cut ..< atEnd] else: " "
  let after = if atEnd < line.len: line[atEnd .. ^1] else: ""

  if before.len > 0:
    result.addSpan Span(text: before, fg: colText)
  result.addSpan Span(text: at, fg: colCursor, bg: colCursorBg, bold: true)
  if after.len > 0:
    result.addSpan Span(text: after, fg: colText)

proc stripBullet(s: string): string =
  ## Drop leading box-drawing/bullet decoration so a decorated line can be
  ## compared against the plain text it was painted from.
  var i = 0
  while i < s.len and s[i] notin {'a'..'z', 'A'..'Z', '0'..'9', '"', '\'', '('}:
    inc i
  s[i .. ^1]

proc anyAssistantMessage(chat: Chat, plain: string): bool =
  ## True if `plain` matches the content of any committed assistant message.
  ## The vendor's headlessTranscriptHook can emit the same text as both aevDelta
  ## (streamed) and aevTool (committed), so we check all assistant messages to
  ## catch duplicates regardless of where the streamed content ended up.
  for msg in chat.messages:
    if msg.role == rAssistant and msg.content == plain:
      return true
  false

proc render*(tb: var TerminalBuffer, app: App) =
  ## Paint one frame.
  ##
  ## Exported because the theme is only visible in the painted cells: the canvas
  ## colour, the two bars and the text on them are all things a unit test can
  ## read off a buffer, and they are exactly what a theme switch gets wrong.
  let
    w = tb.width
    h = tb.height

  # Very small terminals would push the layout maths negative, and illwill's
  # drawing procs take Natural coordinates - so bail out rather than underflow.
  if w < 2 * sideMargin + 2 or h < 4:
    return

  let bodyWidth = max(w - 2 * sideMargin, 8)

  # The canvas goes down first and everything else is painted over it, so the
  # margins, the gaps between messages and the area right of a short line are
  # all the theme's background rather than the terminal's.
  applyCanvas(tb)
  tb.clear()
  app.transcript = buildTranscript(app, bodyWidth)
  # A re-wrap to a different width grows and shrinks the row count, so any
  # live selection has to be pulled back inside the new bounds.
  app.sel.clampRows(app.transcript.len)
  let lay = app.computeLayout(w, h)

  # Scrolling: `scroll` counts lines back from the tail, and is clamped against
  # the transcript that actually exists right now.
  let start = app.visibleStart(lay.msgHeight)

  # Header.
  let title = "  3cx" &
              (if app.backend.name.len > 0: "   " & app.backend.name else: "   no backend")
  drawBar(tb, 0, title, colBarBg, colBarFg)
  tb.setForegroundColor(colRule)
  tb.drawHorizLine(0, w - 1, 1)

  # Transcript.
  if w >= minWidth:
    for row in 0 ..< lay.msgHeight:
      let idx = start + row
      if idx >= app.transcript.len:
        break
      let (cs, ce) = app.sel.rowRange(idx)
      tb.drawLine(lay.msgTop + row, sideMargin, app.transcript[idx], bodyWidth,
                  cs, ce)

  # Separator above the input area.
  tb.setForegroundColor(colRule)
  tb.drawHorizLine(0, w - 1, lay.inputTop - 1)

  # Input area: its own filled surface, so the prompt reads as a box rather
  # than text floating on the canvas - the way OpenCode's prompt does. The
  # fill goes down first; the spans below then re-assert the same background,
  # because a span naming no background of its own paints the canvas colour
  # and would punch holes back through the fill.
  tb.setBackgroundColor(colBarBg)
  tb.setForegroundColor(colBarFg)
  tb.setStyle({})
  tb.fill(0, lay.inputTop, w - 1, lay.statusY - 1, " ")
  applyCanvas(tb)

  let firstVisible = app.input.firstVisibleLine(lay.inputRows)
  if w >= minWidth:
    for row in 0 ..< lay.inputRows:
      let idx = firstVisible + row
      if idx >= app.input.lines.len:
        break
      var line: Line
      if idx == app.input.line:
        line = cursorLine(app.input.lines[idx], app.input.col)
      else:
        line.addSpan Span(text: app.input.lines[idx], fg: colBarFg)
      # The input surface is the bar colour, so typed text uses the bar
      # foreground rather than the canvas one: in the light theme colText is
      # black and would disappear on the black bar.
      for s in line.spans.mitems:
        if s.fg == colText:
          s.fg = colBarFg
        if s.bg == bgNone:
          s.bg = colBarBg
      if idx == 0 and firstVisible == 0:
        tb.setForegroundColor(colPrompt)
        tb.setBackgroundColor(colBarBg)
        tb.setStyle({styleBright})
        tb.write(0, lay.inputTop + row, "❯")
      tb.drawLine(lay.inputTop + row, sideMargin, line, bodyWidth)

  # Status bar: left shows the busy indicator or the current directory; the
  # right always carries the context usage and the command hint. Laid out with
  # explicit padding rather than tabs, which every terminal expands to its own
  # stops.
  let home = getHomeDir()
  let dir = getCurrentDir().replace(home, "~")
  let ctx = app.backend.contextUsageLine()
  let copying = app.copyMsg.len > 0 and epochTime() < app.copyMsgUntil
  let spinIdx = int(epochTime() * 8) mod spinnerFrames.len
  let left = if copying:
               " " & app.copyMsg
             elif app.streaming:
               " " & spinnerFrames[spinIdx] & "  working...   esc interrupt"
             else:
               " " & dir
  let right = if ctx.len > 0: ctx & "   ctrl+p commands "
             else: "ctrl+p commands   ctrl+d quit "

  let (statusFg, statusStyle) =
    if copying: (colOk, {})
    elif app.streaming: (colText, {})
    else: (colDim, if currentTheme.barDim: {styleDim} else: {})
  drawBar(tb, lay.statusY, padStatus(left, right, w), colBarBg, statusFg,
          statusStyle)

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

proc splitCommand*(text: string): tuple[name, arg: string] =
  ## Split a slash command into its name and its argument.
  ##
  ## The name runs to the first space or tab and keeps its slash; the argument
  ## is everything after it, trimmed. The same split 3code's own
  ## `classifyCommand` makes, so `/themes dark` reads the same way here as
  ## `/model dark` does there.
  let sp = text.find({' ', '\t'})
  result.name = if sp < 0: text else: text[0 ..< sp]
  result.arg = if sp < 0: "" else: text[sp + 1 .. ^1].strip

proc themeCommand*(arg: string): string =
  ## `/themes [name]`.
  ##
  ## Bare, it lists the themes and marks the current one. With a name, it
  ## switches and saves - a theme that reverted on the next launch would be no
  ## better than not having one.
  if arg.len == 0:
    return themeHelp()

  if not isThemeName(arg):
    return "unknown theme: \"" & arg & "\"  (available: " &
           themeNames().join(", ") & ")"

  let previous = currentTheme.name
  if not useTheme(arg):
    return "could not switch theme: \"" & arg & "\""
  # The OSC 10/11 default colours follow the theme, so the terminal's own
  # background matches the canvas a switch lands on.
  applyExactPalette(currentTheme)
  # Best-effort: an unwritable config directory costs the choice on the next
  # launch, which is not worth refusing the switch over.
  let saved = saveConfig(Config(theme: currentTheme.name))
  result =
    if previous == currentTheme.name: "theme: " & currentTheme.name & " (already current)"
    else: "theme: " & currentTheme.name & " (was " & previous & ")"
  if not saved:
    result.add " - could not save, it will not survive a restart"

proc recordCommand(app: App, echo, body: string): bool =
  ## Put a command and its output in the transcript, and report the line as
  ## consumed so it is not also sent to the model.
  app.chat.addMessage(rUser, echo)
  app.chat.addMessage(rTool, body)
  app.scroll = 0
  # Like a new turn: rows moved underneath anything that was selected.
  app.sel.clear()
  discard app.chat.saveSession()
  true

proc runSlash(app: App, text: string): bool =
  ## Run `text` as a command if it is one (a leading `/`).
  ##
  ## Returns true when it was consumed as a command, so the caller knows not to
  ## also send it to the model. Slash commands are *text*, not keystrokes - the
  ## same convention 3code's own REPL uses - so they need no key binding; you
  ## type `/tokens` and press enter exactly like a prompt.
  ##
  ## A line starting with the prefix is a command even when the name is not one
  ## this build knows (`/models` for `/model`): it is reported as unknown
  ## instead of being handed to the model. Forwarding it would have the model
  ## answer a typo as though it were a prompt, and start a turn that can sit
  ## waiting on a tool call the user never asked for.
  let c = text.strip
  if c.len == 0 or c[0] != '/':
    return false

  # 3cx's own commands are matched before the backend is asked at all. They
  # belong to the UI rather than to the agent, so they have to work with a
  # backend that has no commands whatsoever - `3cx --mock` has none - and the
  # prefix is the `/` the rest of the UI documents rather than whatever the
  # backend says it is.
  let (name, arg) = splitCommand(c)
  if name == "/themes" or name == "/theme":
    return app.recordCommand(text, themeCommand(arg))
  if name == "/version":
    # Handled here so the report leads with the 3cx version and puts the
    # vendored 3code version on its own line below it.
    return app.recordCommand(text, versionInfo())

  if not app.backend.supportsCommands:
    return false
  let prefix = app.backend.commandPrefix
  if prefix == '\0' or c[0] != prefix:
    return false

  app.chat.addMessage(rUser, text)

  # `/quit` is the one command that ends the session, and `runCommand` reports
  # it rather than performing it.
  if app.backend.isQuitCommand(c):
    app.quit = true
    return true

  let body =
    if app.backend.isCommand(c): app.backend.runCommand(c)
    else: "unknown command: " & c & "  (try " & $prefix & "help)"

  app.recordCommand(text, body)

proc submitInput(app: App) =
  ## Send the current buffer to the backend and start streaming the reply.
  let text = app.input.submit()
  if text.strip.len == 0:
    return
  if app.runSlash(text):
    return
  app.chat.addMessage(rUser, text)
  # Stamped now, not looked up at paint time: `/model` can change the backend's
  # label later, and this reply belongs to the model that is answering now.
  app.chat.addMessage(rAssistant, "", app.backend.name)
  # Every row of the transcript shifts once the reply arrives, so a selection
  # made against the old wrap would latch onto the wrong text.
  app.sel.clear()
  # Remember which message owns the reply. Using `messages[^1]` here instead
  # would break as soon as a tool result arrives mid-turn: the next text delta
  # would land in the *tool* message, leaving the assistant's closing reply
  # glued onto tool output and its own message empty.
  app.streamIdx = app.chat.messages.len - 1
  app.backend.start(text)
  app.streaming = true
  app.turnError = false
  app.scroll = 0
  discard app.chat.saveSession()

proc scrollBy(app: App, delta: int) =
  app.scroll += delta
  if app.scroll < 0:
    app.scroll = 0

proc cellAt*(app: App, lay: Layout, start, x, y: int): Cell =
  ## Transcript cell under screen position `(x, y)`.
  ##
  ## The row is clamped to the visible window rather than to the transcript, so
  ## a pointer dragged past an edge selects the row at that edge instead of
  ## jumping to the far end of the conversation. `dragScroll` then walks the
  ## transcript itself, one line per frame.
  let
    rel = clamp(y - lay.msgTop, 0, max(lay.msgHeight - 1, 0))
    row = if app.transcript.len == 0: 0
          else: min(start + rel, app.transcript.len - 1)
  Cell(row: row, col: max(x - sideMargin, 0))

proc inTranscript(lay: Layout, y: int): bool =
  ## True for rows the message area occupies, and only those: a click on the
  ## header, the prompt or the status bar is not a selection.
  y >= lay.msgTop and y < lay.msgTop + lay.msgHeight

proc dragScroll(app: App, lay: Layout) =
  ## Walk the transcript while a drag parks against an edge.
  ##
  ## Terminals stop reporting motion once the pointer reaches the edge of the
  ## window, so without this a selection could never reach past the top or
  ## bottom of the visible area - it would be stuck on the last row that
  ## reported a motion event. One line per frame is close to the pace of any
  ## editor's auto-scroll.
  if not app.selecting or app.pointerY < 0:
    return
  let
    maxScroll = max(app.transcript.len - lay.msgHeight, 0)
    start = app.visibleStart(lay.msgHeight)
  if app.pointerY < lay.msgTop and app.scroll < maxScroll:
    app.scrollBy(1)
    app.sel.extendTo(Cell(row: max(start - 1, 0), col: 0))
  elif app.pointerY >= lay.msgTop + lay.msgHeight and app.scroll > 0:
    app.scrollBy(-1)
    let last = min(start + lay.msgHeight, max(app.transcript.len - 1, 0))
    app.sel.extendTo(Cell(row: last, col: lineEndCol))

proc endDrag(app: App) =
  ## Give up on a drag whose release may never have arrived.
  ##
  ## A button released outside the terminal window is not always reported, and
  ## the alternative to this is a transcript that keeps scrolling under a
  ## pointer that is no longer being held down. The selection itself is left
  ## alone - Escape drops it, which is the next key the user will press.
  app.selecting = false

proc takePendingCopy*(app: App): string =
  ## Take the text waiting to go to the clipboard, if any.
  ##
  ## Writing happens here, outside `render`, so an OSC 52 payload can never be
  ## interleaved into the middle of a frame the buffer is still diffing - and
  ## the event layer stays free of anything that writes to the terminal.
  result = app.pendingCopy
  app.pendingCopy.setLen(0)

proc copySelection(app: App) =
  ## Queue the current selection for the clipboard and flash a confirmation.
  ##
  ## The highlight stays where it is afterwards: the user needs to see what was
  ## copied, and the next drag or Escape takes it down.
  app.pendingCopy = app.sel.selectedText(app.transcript)
  app.copyMsg = "copied " & $runeLen(app.pendingCopy) & " chars \u2026 esc to clear"
  app.copyMsgUntil = epochTime() + copyFlashSecs

proc handleEvent*(app: App, ev: InputEvent, lay: Layout, start: int) =
  ## Apply one decoded input event to the application state.
  let maxScroll = max(app.transcript.len - lay.msgHeight, 0)

  case ev.kind
  of evNone:
    discard

  of evMouse:
    case ev.mouse.action
    of maScrollUp: app.scrollBy(3)
    of maScrollDown: app.scrollBy(-3)

    of maPress:
      # Remembered even when the press is nowhere near the transcript: that is
      # what auto-scroll needs to know which edge the pointer is resting on.
      app.pointerX = ev.mouse.x
      app.pointerY = ev.mouse.y
      if ev.mouse.button == 0 and inTranscript(lay, ev.mouse.y):
        app.sel.start(app.cellAt(lay, start, ev.mouse.x, ev.mouse.y))
        app.selecting = true
      else:
        # Anywhere else is a plain click, and a plain click drops whatever was
        # selected before.
        app.selecting = false
        app.sel.clear()

    of maMove:
      app.pointerX = ev.mouse.x
      app.pointerY = ev.mouse.y
      # illwill turns on any-event tracking, so motion arrives with the button
      # up too; only a live drag follows the pointer.
      if app.selecting:
        app.sel.extendTo(app.cellAt(lay, start, ev.mouse.x, ev.mouse.y))

    of maRelease:
      if app.selecting:
        app.selecting = false
        if app.sel.empty:
          # A press that never moved: nothing was selected.
          app.sel.clear()
        else:
          app.copySelection()

    else: discard

  of evRune:
    # Shift+Enter sends '\r' with the Shift modifier set; every other modifier
    # combination on a printable rune is treated as a plain character.
    if ord(ev.rune) == ord('\r'):
      if ev.mods.shift:
        app.input.insertNewline()
      else:
        app.submitInput()
    else:
      app.input.insertRune(ev.rune)
      app.scroll = 0   # typing implies wanting to see what is being written

  of evKey:
    case ev.key
    of Key.None:
      discard

    of Key.CtrlC:
      # opencode-style: Ctrl-C never exits. It cancels the in-flight turn,
      # or clears the prompt when idle; Ctrl-D on an empty prompt is the exit.
      #
      # The byte never arrives: `ISIG` is on, so the driver turns it into
      # SIGINT and `poll` reassembles the key from the latched signal. This
      # branch is therefore the *whole* Ctrl-C implementation, not a fallback.
      if app.streaming:
        app.backend.interrupt()
      elif not app.input.isEmpty:
        app.input.clearBuffer()

    of Key.CtrlD:
      # Delete forward when there is text, quit when the buffer is empty.
      if app.input.isEmpty:
        app.quit = true
      else:
        app.input.delete()

    of Key.Enter:
      if ev.mods.shift:
        app.input.insertNewline()
      else:
        app.submitInput()

    of Key.CtrlJ:
      # illwill cannot see Shift+Enter, so Ctrl+J remains a newline chord. With
      # the decoder in place a real Shift+Enter (CSI-u) works too.
      app.input.insertNewline()

    of Key.Backspace, Key.CtrlH:
      app.input.backspace()

    of Key.Delete:
      app.input.delete()

    of Key.Left:
      if ev.mods.ctrl:
        for _ in 0 ..< wordLeft(app.input):
          app.input.moveLeft()
      else:
        app.input.moveLeft()

    of Key.Right:
      if ev.mods.ctrl:
        for _ in 0 ..< wordRight(app.input):
          app.input.moveRight()
      else:
        app.input.moveRight()

    of Key.Up:
      if not app.input.moveUp():
        app.input.recallPrev()

    of Key.Down:
      if not app.input.moveDown():
        app.input.recallNext()

    of Key.Home, Key.CtrlA:
      app.input.moveHome()

    of Key.End, Key.CtrlE:
      app.input.moveEnd()

    of Key.CtrlK:
      app.input.killToEnd()

    of Key.CtrlU:
      app.input.killToStart()

    of Key.CtrlW:
      app.input.deleteWord()

    of Key.PageUp:
      app.scrollBy(lay.msgHeight div 2)

    of Key.PageDown:
      app.scrollBy(-(lay.msgHeight div 2))

    of Key.Escape:
      app.endDrag()
      if app.sel.active:
        # A selection is on screen, so Esc drops it first - one more press
        # then reaches the streaming/tail behaviour below.
        app.sel.clear()
      elif app.streaming:
        app.backend.interrupt()     # first Esc cancels the turn
      else:
        app.scroll = 0               # otherwise jump to the live tail

    of Key.Tab:
      discard

    else:
      discard

  if app.scroll > maxScroll:
    app.scroll = maxScroll

proc overlapsAssistant(app: App, plain, streamed: string): bool =
  ## True when `plain` is a committed echo of the in-flight or a past assistant
  ## reply (possibly reworded or carrying a bullet). Such commits come through
  ## 3code's headless transcript hook as `ckTool` lines and are not extra
  ## information, so they must not become their own tool messages.
  if plain.len < 12:
    return false
  var tailLen = min(24, plain.len)
  var candidates: seq[string]
  if streamed.len >= 12:
    candidates.add streamed
  for m in app.chat.messages:
    if m.role == rAssistant and m.content.len >= 12:
      candidates.add m.content
  for c in candidates:
    let n = min(tailLen, c.len)
    if n >= 12 and c[^n .. ^1] == plain[^n .. ^1]:
      return true
    if plain in c or c in plain:
      return true
  false

proc applyChunk*(app: App, chunk: Chunk) =
  ## Fold one backend event into the chat.
  ##
  ## Split out from `drainBackend` so the message-assignment rules are testable
  ## without a tty or a provider: the rules here are the ones that break in
  ## ways that are invisible from the terminal.
  case chunk.kind
  of ckText:
    # Append to the message this turn opened, not to whatever happens to be
    # last: tool and notice events interleave with the reply, and a tool
    # message sitting at the end would otherwise swallow the assistant's text.
    if app.streamIdx >= 0 and app.streamIdx < app.chat.messages.len:
      app.chat.messages[app.streamIdx].content.add chunk.text
    else:
      # No turn in flight (should not happen); start a fresh message rather
      # than dropping the text on the floor.
      app.chat.addMessage(rAssistant, chunk.text, app.backend.name)
      app.streamIdx = app.chat.messages.len - 1

  of ckReasoning:
    # 3code emits reasoning through the same committed-transcript-line hook, once
    # per paint - so a reply's reasoning arrives as a growing sequence of partial
    # commits, exactly like the reply itself. Unlike the reply there is no
    # streamed reasoning message to compare against, and these are the model's
    # internal deliberation rather than conversation. Dropping them keeps the
    # transcript readable; they are not lost to 3code, which still writes them to
    # its own .3log session.
    discard

  of ckTool, ckNotice:
    let streamed = if app.streamIdx >= 0 and app.streamIdx < app.chat.messages.len:
                     app.chat.messages[app.streamIdx].content
                   else: ""
    let plain = stripBullet(chunk.text)
    if streamed.len > 0 and (plain == streamed or plain.startsWith(streamed) or
                          streamed.startsWith(plain)):
      discard
    elif anyAssistantMessage(app.chat, plain):
      # The vendor's headlessTranscriptHook emits both aevDelta (streamed) and
      # aevTool (committed) for the same content. After streaming ends, the
      # streaming check above no longer catches the duplicate, so also compare
      # against any committed assistant message.
      discard
    elif overlapsAssistant(app, plain, streamed):
      # Committed transcript echo of a reply we already have, possibly with
      # slightly different wording: keep it out of the transcript.
      discard
    elif plain == "interrupted by user":
      # The vendor's `onTurnInterrupted` fires for spurious interrupts (e.g. rate-
      # limited turns that surface as interrupts). We don't want to show this
      # to the user since they didn't actually interrupt.
      discard
    elif chunk.text.strip().startsWith("○") or chunk.text.strip().startsWith("◔") or
         chunk.text.strip().startsWith("◑") or chunk.text.strip().startsWith("◕") or
         chunk.text.strip().startsWith("●"):
      # The vendor's `contextLabel` generates a context-usage indicator like
      # "○ 0%" that ends up in the input bar. We don't want to show this either.
      discard
    else:
      app.chat.addMessage(rTool, chunk.text)

  of ckError:
    app.turnError = true
    app.chat.addMessage(rSystem, chunk.text)

  of ckNone:
    discard

  # A chunk means the transcript is about to be re-wrapped, and every row below
  # the growing message moves with it. A selection would copy text that is no
  # longer where it pointed, so it goes instead.
  app.sel.clear()

proc drainBackend(app: App): bool =
  ## Move everything the backend has produced into the chat.
  ##
  ## Called once per frame, so it drains the whole queue rather than a single
  ## item: a worker thread can queue many events between two frames, and
  ## rendering them one frame at a time would make fast replies crawl.
  ##
  ## Returns true on the frame a turn ends, so the caller can settle the
  ## terminal tab title once the frame is on screen.
  if not app.streaming:
    return false

  while true:
    let chunk = app.backend.nextChunk()
    if chunk.kind == ckNone:
      break
    applyChunk(app, chunk)

  if app.backend.isDone():
    app.streaming = false
    discard app.chat.saveSession()
    return true
  false

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

proc run*(chat: Chat, backend: Backend) =
  ## Run the UI until the user quits, saving the transcript on the way out.
  # First, before the terminal is touched: from here on Ctrl-C must be handled
  # rather than fatal, because the default SIGINT disposition would kill the
  # process with the screen still in full-screen mode and nothing to put it
  # back. Ctrl-C never reaches the decoder as a byte anyway - `enableRawInput`
  # leaves `ISIG` on, so the driver turns 0x03 into a signal - and the hook
  # latches it for `InputReader.poll` to hand back as `Key.CtrlC`.
  installCtrlCHook()
  illwillInit(fullScreen = true, mouse = true)
  applyExactPalette(currentTheme)
  discard enableRawInput()   # stop ICRNL rewriting Enter into Ctrl+J

  var app = App(chat: chat, input: newInputBox(), backend: backend,
                reader: newInputReader(), pointerX: -1, pointerY: -1)

  # The cursor is painted into the buffer, so the real one stays hidden for the
  # whole run - see `cursorLine` for why moving it per frame flickers.
  hideCursor()
  var
    lastW = -1
    lastH = -1
    spinIdx = 0
  try:
    # The terminal tab title: brand + project label while idle. Set before
    # the loop starts so the tab is correct from the first frame.
    tabtitle.setTabTitleLabel(getCurrentDir().extractFilename)
    tabtitle.paintTabTitleIdle()
    while not app.quit:
      var tb = getBuffer()
      let lay = app.computeLayout(tb.width, tb.height)

      if tb.width != lastW or tb.height != lastH:
        lastW = tb.width
        lastH = tb.height
        # Text re-wraps to a new width, so the same row index no longer means
        # the same words. Better to drop the selection than to let it sit on
        # text the user never chose.
        app.sel.clear()

      let start = app.visibleStart(lay.msgHeight)
      for ev in app.reader.poll(0):
        app.handleEvent(ev, lay, start)
      app.dragScroll(lay)
      let turnEnded = app.drainBackend()
      render(tb, app)

      tb.display()

      # Tab title writes go after the frame, like the OSC 52 below: a sequence
      # emitted mid-diff could tear against illwill's output. While a turn
      # streams the spinner glyph rotates; on the frame it ends the spinner is
      # replaced by the outcome mark.
      if app.streaming:
        tabtitle.paintTabTitleWorking(spinnerFrames[spinIdx])
        spinIdx = (spinIdx + 1) mod spinnerFrames.len
      elif turnEnded:
        tabtitle.settleTabTitle(not app.turnError)

      # After the frame, so the sequence shares no bytes with the diff illwill
      # is writing. A terminal that honours OSC 52 needs no repaint either.
      let toCopy = app.takePendingCopy()
      if toCopy.len > 0:
        clipboardCopy(toCopy)
      sleep(15)
  finally:
    # Before anything that can take time: see `stopMouseTracking`. The main
    # loop has stopped reading input, so a click from here on would otherwise
    # queue a mouse report that reaches the shell as literal text.
    stopMouseTracking()
    if app.streaming:
      app.backend.interrupt()
    discard app.chat.saveSession()
    app.backend.stop()
    restoreInput()
    resetExactPalette()
    illwillDeinit()
    # After illwillDeinit restored echo: the last tty operation before exit, so
    # reports the terminal delivered after the early flush are dropped here.
    flushQueuedMouseReports()
    showCursor()