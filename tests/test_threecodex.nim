## Test suite for the logic behind the 3cx UI.
##
## These cover the pure parts: Markdown rendering, the input editor, Unicode
## width handling, session round-tripping and the mock backend. The terminal
## drawing layer is exercised end-to-end by driving the real binary in a pty
## rather than being unit tested, since it is mostly straight-line blitting.

import std/[base64, json, os, sequtils, strutils, unicode, unittest]
import illwill
import ../src/threecodex/[uwidth, markdown, inputbox, keyevent, session, selection,
                           clipboard, types, backend, config, theme]
import ../src/threecodex/app

type
  # A backend that only counts interrupts, so the quit keys can be checked
  # against what the backend saw rather than against the screen.
  RecordingBackend = ref object of Backend
    interrupts: int

method interrupt(b: RecordingBackend) =
  inc b.interrupts

suite "app style mapping":
  # On POSIX illwill emits `ESC[<ordinal>m`, so a Style flag *is* an SGR code.
  # Getting this wrong is invisible in unit tests and obvious on screen: bold
  # mapped to `styleBlink` once, which is SGR 5, and every heading flashed.

  test "bold maps to SGR 1 (bright), never to SGR 5 (blink)":
    let s = spanStyle(Span(text: "x", fg: fgWhite, bold: true))
    check styleBright in s
    check styleBlink notin s

  test "italic maps to SGR 3 and underline to SGR 4":
    check styleItalic in spanStyle(Span(text: "x", fg: fgWhite, italic: true))
    check styleUnderscore in spanStyle(Span(text: "x", fg: fgWhite, underline: true))

  test "no style is emitted for a plain span":
    check spanStyle(Span(text: "x", fg: fgWhite)) == {}

  test "the emitted ordinals are the SGR codes we expect":
    # Guards against someone re-reading the stdlib's "blinking/bold" comment.
    check ord(styleBright) == 1
    check ord(styleItalic) == 3
    check ord(styleUnderscore) == 4
    check ord(styleBlink) == 5

suite "app chunk assignment":
  # Rules for folding backend events into the transcript. Split out from
  # drainBackend so they can be tested without a tty or a provider: every failure
  # mode here is invisible from the terminal.

  proc testApp(): App =
    var chat = Chat()
    chat.addMessage(rUser, "hi")
    chat.addMessage(rAssistant, "")
    result = App(chat: chat, backend: newMockBackend("test"), streamIdx: 0,
                 streaming: true)

  test "a tool event does not swallow the assistant's reply":
    # Regression: ckText used to append to messages[^1], which after a tool
    # event is the *tool* message - so the assistant's closing reply was glued
    # onto tool output and its own message stayed empty.
    let app = testApp()
    app.streamIdx = 1                      # message 1 is the assistant's
    applyChunk(app, Chunk(kind: ckTool, text: "tool result"))
    applyChunk(app, Chunk(kind: ckText, text: "the reply"))

    check app.chat.messages.len == 3       # no extra message was opened
    check app.chat.messages[1].role == rAssistant
    check app.chat.messages[1].content == "the reply"
    check app.chat.messages[2].role == rTool
    check app.chat.messages[2].content == "tool result"

  test "text before any turn opens a fresh assistant message":
    let app = App(chat: Chat(), backend: newMockBackend("test"), streamIdx: -1, streaming: false)
    applyChunk(app, Chunk(kind: ckText, text: "orphan"))
    check app.chat.messages.len == 1
    check app.chat.messages[0].role == rAssistant
    check app.chat.messages[0].content == "orphan"

  test "notice and error land in their own messages":
    let app = App(chat: Chat(), backend: newMockBackend("test"), streamIdx: -1, streaming: false)
    applyChunk(app, Chunk(kind: ckNotice, text: "retrying"))
    applyChunk(app, Chunk(kind: ckError, text: "boom"))
    check app.chat.messages[0].role == rTool
    check app.chat.messages[1].role == rSystem
    check app.chat.messages[1].content == "boom"

  test "paint commits of a streaming reply do not become a staircase":
    # Regression, from a real screenshot. 3code's aevTool is its
    # committed-transcript-line hook: once per paint, the assistant's *partial*
    # reply is emitted too, each a word or two longer than the last. Every one
    # was being added as a tool message, producing a staircase of
    # near-identical lines instead of one reply.
    let app = testApp()
    app.streaming = true
    app.streamIdx = 1

    # The streamed reply builds up word by word.
    app.chat.messages[1].content = "The user"
    applyChunk(app, Chunk(kind: ckTool, text: "The user"))
    app.chat.messages[1].content.add(" just said \"hi\"")
    applyChunk(app, Chunk(kind: ckTool, text: "The user just said \"hi\""))
    app.chat.messages[1].content.add(". Simple greeting.")
    applyChunk(app, Chunk(kind: ckTool,
                         text: "The user just said \"hi\". Simple greeting."))
    # The final commit arrives decorated with a bullet.
    applyChunk(app, Chunk(kind: ckTool,
                         text: "● The user just said \"hi\". Simple greeting."))

    check app.chat.messages.len == 2
    check app.chat.messages[1].role == rAssistant
    check app.chat.messages[1].content ==
      "The user just said \"hi\". Simple greeting."

  test "a genuine tool result is still rendered":
    let app = App(chat: Chat(), backend: newMockBackend("test"), streamIdx: -1, streaming: false)
    applyChunk(app, Chunk(kind: ckTool, text: "$ ls -la /tmp"))
    check app.chat.messages.len == 1
    check app.chat.messages[0].role == rTool
    check app.chat.messages[0].content == "$ ls -la /tmp"

  test "reasoning commits are dropped, not staircased":
    # Reasoning arrives through the same per-paint committed-line hook, so it
    # grows word by word just like the reply does. With no streamed reasoning
    # message to compare against, the only sane behaviour is to leave it out of
    # the transcript - it is the model's internal deliberation, not conversation.
    let app = App(chat: Chat(), backend: newMockBackend("test"), streamIdx: -1, streaming: false)
    for t in ["The", "The user just said \"hi\"",
              "The user just said \"hi\". Simple greeting"]:
      applyChunk(app, Chunk(kind: ckReasoning, text: t))
    check app.chat.messages.len == 0

  test "ckNone is dropped":
    let app = App(chat: Chat(), backend: newMockBackend("test"), streamIdx: -1, streaming: false)
    applyChunk(app, Chunk(kind: ckNone, text: "ignored"))
    check app.chat.messages.len == 0

suite "transcript role labels":
  # `/model <name>` changes which model answers, so the header and the assistant
  # role label both move. The trap is that the transcript is rebuilt from the
  # chat on every frame: if the label were read from the backend at paint time,
  # one `/model` would relabel every reply already in the conversation as if the
  # new model had produced them. Hence the per-message stamp.

  proc roleLabels(app: App): seq[string] =
    ## Just the role headers, in order. Compared whole rather than stripped of
    ## their "\u258c " gutter: that prefix is two runes but four bytes, and
    ## slicing it off by byte index splits the box-drawing character in half.
    for line in app.buildTranscript(60):
      if line.lineText.startsWith("\u258c "):
        result.add line.lineText

  proc stampedApp(): App =
    var chat = Chat()
    chat.addMessage(rUser, "hi", "ignored.user")
    chat.addMessage(rAssistant, "first reply", "zai.glm-5.3")
    chat.addMessage(rUser, "switch", "ignored.user")
    chat.addMessage(rAssistant, "second reply", "zai.glm-5.1")
    result = App(chat: chat, backend: newMockBackend("zai.glm-5.1"))

  test "each assistant message keeps the label of the model that wrote it":
    let app = stampedApp()
    check app.roleLabels() ==
      @["▌ you", "▌ zai.glm-5.3", "▌ you", "▌ zai.glm-5.1"]

  test "switching the model does not relabel earlier replies":
    # The failure this pins: a live lookup would return the backend's current
    # name for every message, so both replies would read "zai.glm-5.1".
    let app = stampedApp()
    app.backend.name = "something.else"
    check "▌ zai.glm-5.3" in app.roleLabels()
    check "▌ something.else" notin app.roleLabels()

  test "an unstamped message falls back to the backend's current name":
    # Messages restored from a session file written before the stamp existed.
    var chat = Chat()
    chat.addMessage(rAssistant, "old reply")
    let app = App(chat: chat, backend: newMockBackend("zai.glm-5.3"))
    check app.roleLabels() == @["▌ zai.glm-5.3"]

  test "a reply opened with no turn in flight is stamped too":
    let app = App(chat: Chat(), backend: newMockBackend("zai.glm-5.1"),
                  streamIdx: -1, streaming: false)
    applyChunk(app, Chunk(kind: ckText, text: "orphan"))
    check app.chat.messages[0].model == "zai.glm-5.1"

suite "cursor rendering":
  # The cursor is painted into the buffer, so it can never appear in two places
  # or blink. These pin the shape it takes.

  test "a cursor mid-line splits the line around the glyph":
    let l = cursorLine("hello world", 5)
    check l.lineText == "hello world"
    check l.spans.len == 3
    check l.spans[0].text == "hello"
    check l.spans[1].text == " "
    check l.spans[1].bg == colCursorBg
    check l.spans[1].bold
    check l.spans[2].text == "world"

  test "a cursor at end of line paints a space":
    let l = cursorLine("abc", 3)
    check l.spans[^1].text == " "
    check l.spans[^1].bg == colCursorBg

  test "a cursor past the end of the line is clamped":
    let l = cursorLine("abc", 99)
    check l.lineText == "abc "

  test "a cursor on a wide rune keeps it whole":
    # The cursor must not split a multi-byte character in half.
    let l = cursorLine("a日b", 1)
    check l.spans[1].text == "日"
    check l.spans[1].bg == colCursorBg

suite "uwidth":

  test "ascii width is one column per byte":
    check displayWidth("abc") == 3
    check displayWidth("") == 0

  test "cjk counts as two columns":
    check displayWidth("日本") == 4
    check displayWidth("a日") == 3

  test "offsetLeft and offsetRight walk rune boundaries":
    let s = "a日b"
    check offsetLeft(s, 0) == 0
    check offsetRight(s, 0) == 1
    check offsetRight(s, 1) == 4      # past the 3-byte rune
    check offsetLeft(s, 4) == 1
    check offsetRight(s, 4) == 5
    check offsetLeft(s, 99) == 4       # clamped to the end, then one rune back
    check offsetRight(s, 99) == 5

  test "takeFitting splits without breaking a rune":
    let (head, rest) = takeFitting("abc", 2)
    check head == "ab"
    check rest == "c"

  test "truncateToWidth never exceeds the budget":
    check truncateToWidth("abcdef", 3) == "abc"
    check truncateToWidth("abcdef", 0) == ""
    check truncateToWidth("abc", 10) == "abc"
    check displayWidth(truncateToWidth("日本語テキスト", 5)) <= 5

suite "markdown":

  proc texts(lines: seq[Line]): seq[string] =
    for l in lines:
      result.add l.lineText

  proc widest(lines: seq[Line]): int =
    for l in lines:
      result = max(result, l.lineWidth)

  test "heading text is stripped and bolded":
    let lines = renderMarkdown("# Title", 40)
    check "Title" in lines.texts()
    check lines[0].spans[0].bold

  test "bullet list gets a bullet marker":
    check "• a" in renderMarkdown("- a\n- b", 40).texts()

  test "ordered list keeps its numbers":
    check "1. a" in renderMarkdown("1. a\n2. b", 40).texts()

  test "horizontal rule spans the full width":
    let lines = renderMarkdown("---", 20)
    check lines.anyIt(it.lineWidth == 20)

  test "inline emphasis and code are split into spans":
    let strong = renderMarkdown("**hi** there", 40)[0]
    check strong.spans.len >= 2
    check strong.spans[0].bold
    check strong.spans[0].text == "hi"

    let code = renderMarkdown("see `x`", 40)[0]
    check code.spans.anyIt(it.underline and it.text == "x")

  test "fenced code is emitted verbatim with a gutter":
    let lines = renderMarkdown("```nim\necho 1\n```", 40).texts()
    check lines.anyIt(it.contains("│ echo 1"))

  test "unterminated fence still renders its contents":
    let lines = renderMarkdown("```\nplain", 40).texts()
    check lines.anyIt(it.contains("plain"))

  test "block quote gets the quote gutter":
    check renderMarkdown("> hi", 40).texts().anyIt(it.contains("▏ hi"))

  test "long paragraphs wrap without exceeding the width":
    let src = "the quick brown fox jumps over the lazy dog " & repeat("and then runs away ", 12)
    let lines = renderMarkdown(src, 40)
    check lines.len > 1
    check lines.widest() <= 40

  test "an over-long token is hard broken rather than overflowing":
    let lines = renderMarkdown("x" & repeat("y", 200), 30)
    check lines.widest() <= 30
    check lines.len > 1

  test "tiny widths do not hang or overflow":
    for w in 8 .. 20:
      let lines = renderMarkdown("### head\n\n- " & repeat("word ", 10), w)
      check lines.widest() <= w

  test "renderPlain does not interpret markdown":
    let lines = renderPlain("- not a bullet\n# not a heading", 40).texts()
    check lines.anyIt(it.contains("- not a bullet"))
    check lines.anyIt(it.contains("# not a heading"))

  test "plain text preserves explicit newlines":
    let lines = renderPlain("a\nb\nc", 40)
    check lines.len == 3

suite "inputbox":

  test "typing and backspace":
    var ib = newInputBox()
    for c in "hello": ib.insertChar(c)
    check ib.text == "hello"
    ib.backspace()
    check ib.text == "hell"
    check ib.col == 4

  test "backspace on an empty buffer is a no-op":
    var ib = newInputBox()
    ib.backspace()
    check ib.text == ""

  test "newline splits the current row":
    var ib = newInputBox()
    for c in "abc": ib.insertChar(c)
    ib.moveLeft(); ib.moveLeft()
    ib.insertNewline()
    check ib.text == "a\nbc"
    check ib.line == 1
    check ib.col == 0

  test "backspace at the start joins the previous row":
    var ib = newInputBox()
    for c in "ab": ib.insertChar(c)
    ib.insertNewline()
    for c in "cd": ib.insertChar(c)
    ib.moveHome()
    ib.backspace()
    check ib.text == "abcd"
    check ib.line == 0
    check ib.col == 2

  test "horizontal movement across rows":
    var ib = newInputBox()
    for c in "ab": ib.insertChar(c)
    ib.insertNewline()
    for c in "cd": ib.insertChar(c)
    ib.moveLeft()
    check ib.line == 1 and ib.col == 1
    ib.moveLeft()
    check ib.line == 1 and ib.col == 0
    ib.moveLeft()
    check ib.line == 0 and ib.col == 2
    ib.moveRight()
    check ib.line == 1 and ib.col == 0   # off the end of "ab", so onto row 2

  test "moveUp and moveDown report when they cannot move":
    var ib = newInputBox()
    for c in "ab": ib.insertChar(c)
    check ib.moveUp() == false      # already on the first row
    ib.insertNewline()
    check ib.moveUp() == true
    check ib.moveDown() == true
    check ib.moveDown() == false     # already on the last row

  test "kill and delete-word operations":
    var ib = newInputBox()
    for c in "one two three": ib.insertChar(c)
    ib.deleteWord()
    check ib.text == "one two "
    ib.moveLeft()
    ib.killToEnd()
    check ib.text == "one two"

    var ib2 = newInputBox()
    for c in "abcdef": ib2.insertChar(c)
    ib2.killToStart()
    check ib2.text == ""

  test "forward delete joins the next row":
    var ib = newInputBox()
    for c in "ab": ib.insertChar(c)
    ib.insertNewline()
    for c in "cd": ib.insertChar(c)
    discard ib.moveUp()
    check ib.line == 0 and ib.col == 2
    ib.delete()                           # at the end of row 1, so this joins
    check ib.text == "abcd"

  test "home and end":
    var ib = newInputBox()
    for c in "abc": ib.insertChar(c)
    ib.moveHome()
    check ib.col == 0
    ib.moveEnd()
    check ib.col == 3

  test "submit pushes history and clears the editor":
    var ib = newInputBox()
    for c in "first": ib.insertChar(c)
    check ib.submit() == "first"
    check ib.isEmpty
    check ib.history == @["first"]

  test "blank submissions are not recorded":
    var ib = newInputBox()
    ib.insertChar(' ')
    discard ib.submit()
    check ib.history.len == 0

  test "history recall walks back and restores the draft":
    var ib = newInputBox()
    for c in "one": ib.insertChar(c)
    discard ib.submit()
    for c in "two": ib.insertChar(c)
    discard ib.submit()

    ib.recallPrev()
    check ib.text == "two"
    ib.recallPrev()
    check ib.text == "one"
    ib.recallNext()
    check ib.text == "two"
    ib.recallNext()
    check ib.text == ""              # back to the saved draft

  test "cursor column accounts for wide runes":
    var ib = newInputBox()
    for r in "日本".runes: ib.insertRune(r)
    check ib.cursorColumn() == 4

suite "session":

  test "save and load round-trips a chat":
    let dir = getTempDir() / "threecodex_test"
    setSessionDir(dir)
    defer: removeDir(dir)

    var chat = Chat()
    chat.addMessage(rUser, "hello")
    chat.addMessage(rAssistant, "**hi**")
    chat.addMessage(rTool, "● ran a tool")

    check chat.saveSession()
    let loaded = loadSession()
    check loaded.messages.len == 3
    check loaded.messages[0].role == rUser
    check loaded.messages[0].content == "hello"
    check loaded.messages[1].role == rAssistant
    check loaded.messages[1].content == "**hi**"
    check loaded.messages[2].role == rTool
    check loaded.messages[2].content == "● ran a tool"

  test "every role survives a round-trip":
    # Guards the role<->string mapping in both directions: a role added without
    # being handled here would silently persist as "system".
    let dir = getTempDir() / "threecodex_roles"
    setSessionDir(dir)
    defer: removeDir(dir)

    var chat = Chat()
    for role in Role:
      chat.addMessage(role, "x")
    discard chat.saveSession()
    let loaded = loadSession()
    var expected = 0
    for _ in Role:
      inc expected
    check loaded.messages.len == expected
    var i = 0
    for role in Role:
      check loaded.messages[i].role == role
      inc i

  test "a missing session file yields an empty chat":
    let dir = getTempDir() / "threecodex_missing"
    setSessionDir(dir)
    defer: removeDir(dir)
    check loadSession().messages.len == 0

  test "a corrupt session file yields an empty chat":
    let dir = getTempDir() / "threecodex_corrupt"
    setSessionDir(dir)
    defer: removeDir(dir)
    createDir(sessionDir())
    writeFile(sessionPath(), "not json at all {{{")
    check loadSession().messages.len == 0

  test "the model stamp survives a round trip":
    # Without this the role label falls back to whatever the backend is running
    # when the session is reopened, so a conversation that changed model
    # mid-stream comes back with every reply attributed to the last one.
    let dir = getTempDir() / "threecodex_stamp"
    setSessionDir(dir)
    defer: removeDir(dir)
    var chat = Chat()
    chat.addMessage(rAssistant, "first", "zai.glm-5.3")
    chat.addMessage(rAssistant, "second", "zai.glm-5.1")
    discard chat.saveSession()
    let loaded = loadSession()
    check loaded.messages[0].model == "zai.glm-5.3"
    check loaded.messages[1].model == "zai.glm-5.1"

  test "a session file without stamps loads them as empty":
    # The pre-stamp format: present keys only, so old files keep working.
    let dir = getTempDir() / "threecodex_unstamped"
    setSessionDir(dir)
    defer: removeDir(dir)
    createDir(sessionDir())
    writeFile(sessionPath(), """[{"role":"assistant","content":"hi"}]""")
    let loaded = loadSession()
    check loaded.messages.len == 1
    check loaded.messages[0].content == "hi"
    check loaded.messages[0].model == ""

suite "backend":

  test "the mock streams its full reply exactly once":
    let b = newMockBackend()
    b.start("hi")
    var got = ""
    while true:
      let chunk = b.nextChunk()
      if chunk.kind == ckNone: break
      check chunk.kind == ckText
      got.add chunk.text
    check got == b.text
    check b.nextChunk().kind == ckNone
    check b.nextChunk().text.len == 0

  test "ckNone is the zero value, so a fresh chunk reads as empty":
    # The UI relies on this: a default-constructed Chunk must not look like work.
    let c = Chunk()
    check c.kind == ckNone
    check c.text.len == 0

  test "the mock echoes the prompt and covers the renderer features":
    let text = mockReply("what up")
    check text.contains("what up")
    for marker in ["##", "###", "**", "`", "```", "- ", "1. ", "> ", "---"]:
      check text.contains(marker)

  test "chunk size is respected":
    let b = newMockBackend()
    b.chunkSize = 5
    b.start("x")
    check b.nextChunk().text.len == 5
suite "uwidth columns":
  # A mouse selection is addressed by display column, which is not the same as
  # a byte offset: what the terminal reports is a column, and the text
  # underneath is UTF-8.

  test "colToOffset maps a display column onto a rune boundary":
    check colToOffset("abc", 0) == 0
    check colToOffset("abc", 1) == 1
    check colToOffset("a日b", 2) == 1      # the wide rune starts at column 2
    check colToOffset("abc", 99) == 3      # past the end means all of it
    check colToOffset("", 3) == 0

  test "sliceColumns cuts on columns, not bytes":
    check sliceColumns("hello world", 1, 4) == "ell"
    check sliceColumns("hello", 0, 0) == ""
    check sliceColumns("hello", 3, 2) == ""       # an inverted range selects nothing
    check sliceColumns("hello", 99, 100) == ""

  test "a wide rune at the edge of a selection comes out whole":
    # Slicing on the left half of a double-width glyph would put a mangled
    # fragment on the clipboard.
    check sliceColumns("a日b", 0, 2) == "a日"
    check sliceColumns("a日b", 1, 2) == "日"
    check sliceColumns("日本語", 2, 4) == "本"

  test "a selection past the end of a line stops at the end":
    check sliceColumns("abc", 1, 99) == "bc"

suite "quit keys":
  # Ctrl-C and Ctrl-D are where this app nearly took itself down: the SIGINT
  # handler used to run the whole teardown in signal context, so a second
  # Ctrl-C landing mid-teardown raised from inside the handler and segfaulted,
  # and the 50ms "wait for the terminal" sleep was really 50 *seconds*, so
  # Ctrl-D returned to a console with no prompt for a minute.
  #
  # The contract now is 3code's own: Ctrl-C cancels - the in-flight turn, or
  # the draft - and Ctrl-D on an empty prompt is the only way out.

  proc keyLayout(): Layout =
    Layout(msgTop: 2, msgHeight: 10, inputTop: 12, inputRows: 3, statusY: 15)

  proc keyEventApp(streaming: bool, text = ""): App =
    result = App(chat: Chat(), backend: RecordingBackend(), streamIdx: -1,
                 streaming: streaming)
    result.input = newInputBox()
    result.input.paste(text)

  test "ctrl-c cancels the turn instead of quitting":
    var app = keyEventApp(streaming = true, text = "half typed")
    app.handleEvent(InputEvent(kind: evKey, key: Key.CtrlC), keyLayout(), 0)
    let b = cast[RecordingBackend](app.backend)
    check b.interrupts == 1
    check not app.quit
    check app.input.text == "half typed"    # the draft is not touched

  test "ctrl-c clears the draft when nothing is streaming":
    var app = keyEventApp(streaming = false, text = "half typed")
    app.handleEvent(InputEvent(kind: evKey, key: Key.CtrlC), keyLayout(), 0)
    check cast[RecordingBackend](app.backend).interrupts == 0
    check app.input.isEmpty
    check not app.quit

  test "ctrl-c on an empty prompt is a no-op, not an exit":
    var app = keyEventApp(streaming = false)
    app.handleEvent(InputEvent(kind: evKey, key: Key.CtrlC), keyLayout(), 0)
    check not app.quit

  test "ctrl-d quits on an empty prompt":
    var app = keyEventApp(streaming = false)
    app.handleEvent(InputEvent(kind: evKey, key: Key.CtrlD), keyLayout(), 0)
    check app.quit

  test "ctrl-d deletes forward when there is a draft":
    var app = keyEventApp(streaming = false, text = "ab")
    app.input.moveHome()                 # cursor in front of the 'a'
    app.handleEvent(InputEvent(kind: evKey, key: Key.CtrlD), keyLayout(), 0)
    check not app.quit
    check app.input.text == "b"

suite "mouse selection":
  # Positions are transcript coordinates, so a selection survives scrolling and
  # a re-wrap: rows keep their identity and only the rendering re-slices them.

  proc rows(texts: varargs[string]): seq[Line] =
    for t in texts:
      result.add Line(spans: @[Span(text: t, fg: colText)])

  test "a drag highlights every row it crosses":
    let sel = selection(Cell(row: 0, col: 1), Cell(row: 2, col: 3))
    check sel.rowRange(0) == (1, lineEndCol)
    check sel.rowRange(1) == (0, lineEndCol)
    check sel.rowRange(2) == (0, 3)
    check sel.rowRange(3) == (-1, -1)
    check sel.selectedText(rows("one two three", "middle row", "last line here")) ==
      "ne two three\nmiddle row\nlas"

  test "a drag in the other direction selects the same text":
    let lines = rows("one two three", "middle row")
    let forwards = selection(Cell(row: 0, col: 2), Cell(row: 1, col: 5))
    let backwards = selection(Cell(row: 1, col: 5), Cell(row: 0, col: 2))
    check backwards.selectedText(lines) == forwards.selectedText(lines)

  test "a selection inside one row copies only that row":
    let sel = selection(Cell(row: 1, col: 2), Cell(row: 1, col: 8))
    check sel.selectedText(rows("one two three", "middle row")) == "ddle r"

  test "a press that never moved has nothing to copy":
    var sel = newSelection()
    check sel.empty
    sel.start(Cell(row: 3, col: 4))
    check sel.active
    check sel.empty                     # both ends still on the anchor
    sel.extendTo(Cell(row: 3, col: 5))
    check not sel.empty

  test "extending an inactive selection does nothing":
    # Guards against a stray motion event waking a selection that was cleared.
    var sel = newSelection()
    sel.extendTo(Cell(row: 1, col: 1))
    check not sel.active
    check sel.rowRange(1) == (-1, -1)

  test "clear drops a live selection, and is safe to repeat":
    var sel = selection(Cell(row: 0, col: 0), Cell(row: 1, col: 2))
    sel.clear()
    check not sel.active
    check sel.rowRange(0) == (-1, -1)
    check sel.selectedText(rows("a", "b")) == ""
    sel.clear()

  test "a selection is clamped into a re-wrapped transcript":
    var sel = selection(Cell(row: 6, col: 1), Cell(row: 9, col: 4))
    sel.clampRows(5)
    check sel.ordered() == (Cell(row: 4, col: 1), Cell(row: 4, col: 4))

  test "a transcript with no rows drops the selection":
    var sel = selection(Cell(row: 0, col: 0), Cell(row: 2, col: 3))
    sel.clampRows(0)
    check not sel.active

  test "clamping an inactive selection is a no-op":
    var sel = newSelection()
    sel.clampRows(3)
    check not sel.active

  test "splitting a span keeps the unselected text either side":
    check splitSelected("hello world", 2, 7) == ("he", "llo w", "orld")
    check splitSelected("hello world", 0, lineEndCol) == ("", "hello world", "")
    check splitSelected("hello world", -1, -1) == ("hello world", "", "")
    check splitSelected("hello world", 6, 2) == ("hello world", "", "")

suite "mouse coordinates":
  # The terminal reports screen cells; the transcript is addressed by row and
  # column. A mistake here is invisible until someone selects: the highlight and
  # the copied text would quietly disagree.

  proc testLayout(): Layout =
    Layout(msgTop: 2, msgHeight: 10, inputTop: 12, inputRows: 3, statusY: 15)

  proc testApp(count: int): App =
    result = App(chat: Chat(), backend: newMockBackend("test"), streamIdx: -1, streaming: false)
    for i in 0 ..< count:
      result.transcript.add Line(spans: @[Span(text: "row " & $i, fg: colText)])

  proc mouseEvent(action: MouseAction, x, y: int, button = 0): InputEvent =
    InputEvent(kind: evMouse, mouse: MouseEvent(x: x, y: y, action: action,
                                                button: button))

  test "a press anchors a selection on the cell under the pointer":
    let app = testApp(30)
    let lay = testLayout()
    check app.cellAt(lay, 20, 6, 2) == Cell(row: 20, col: 4)
    check app.cellAt(lay, 20, 2, 2) == Cell(row: 20, col: 0)     # left edge
    check app.cellAt(lay, 20, 6, 11) == Cell(row: 29, col: 4)

  test "a pointer dragged past an edge selects the edge row":
    # Clamped to the visible window rather than to the transcript, which is
    # what lets auto-scroll walk the rest of the way in.
    let app = testApp(30)
    let lay = testLayout()
    check app.cellAt(lay, 20, 6, 0) == Cell(row: 20, col: 4)
    check app.cellAt(lay, 20, 6, 99) == Cell(row: 29, col: 4)

  test "a short transcript stops the clamp at its last row":
    let app = testApp(4)
    let lay = testLayout()
    check app.cellAt(lay, 0, 6, 99) == Cell(row: 3, col: 4)
    check app.cellAt(lay, 0, 6, 0) == Cell(row: 0, col: 4)

  test "an empty transcript addresses row zero rather than raising":
    let app = testApp(0)
    check app.cellAt(testLayout(), 0, 6, 2) == Cell(row: 0, col: 4)

  test "press, drag and release build the selection over the rows":
    var app = testApp(4)
    let lay = testLayout()
    app.handleEvent(mouseEvent(maPress, 4, 2), lay, 0)
    check app.sel.anchor == Cell(row: 0, col: 2)
    check app.sel.active
    app.handleEvent(mouseEvent(maMove, 6, 4), lay, 0)
    check app.sel.head == Cell(row: 2, col: 4)
    check app.takePendingCopy() == ""          # not yet: the button is still down
    app.handleEvent(mouseEvent(maRelease, 6, 4), lay, 0)
    check app.takePendingCopy() == "w 0\nrow 1\nrow "

  test "releasing a press that never moved copies nothing":
    var app = testApp(4)
    let lay = testLayout()
    app.handleEvent(mouseEvent(maPress, 4, 2), lay, 0)
    app.handleEvent(mouseEvent(maRelease, 4, 2), lay, 0)
    check app.takePendingCopy() == ""
    check not app.sel.active

  test "a press outside the transcript clears whatever was selected":
    var app = testApp(4)
    let lay = testLayout()
    app.sel = selection(Cell(row: 0, col: 0), Cell(row: 1, col: 3))
    # The header, and the prompt below the message area.
    app.handleEvent(mouseEvent(maPress, 4, 1), lay, 0)
    check not app.sel.active
    app.handleEvent(mouseEvent(maPress, 4, 12), lay, 0)
    check not app.sel.active
    app.handleEvent(mouseEvent(maRelease, 4, 12), lay, 0)
    check app.takePendingCopy() == ""

  test "motion without a drag is ignored":
    # illwill turns on any-event tracking, so motion arrives with the button
    # up as well.
    var app = testApp(4)
    app.handleEvent(mouseEvent(maMove, 6, 4), testLayout(), 0)
    check not app.sel.active
    check app.takePendingCopy() == ""

  test "a second button does not select":
    var app = testApp(4)
    let lay = testLayout()
    app.handleEvent(mouseEvent(maPress, 4, 2, button = 2), lay, 0)
    check not app.sel.active
    check app.takePendingCopy() == ""

  test "escape ends a drag whose release never arrived":
    # A button released outside the window is not always reported.
    var app = testApp(30)
    let lay = testLayout()
    app.handleEvent(mouseEvent(maPress, 4, 2), lay, 20)
    app.handleEvent(mouseEvent(maMove, 6, 0), lay, 20)   # parked on the top edge
    app.handleEvent(InputEvent(kind: evKey, key: Key.Escape), lay, 20)
    check not app.sel.active

  test "a drag parks on an edge and auto-scrolls the transcript":
    # Terminals stop reporting motion at the window edge, so the app has to
    # walk the rest of the way; the rows it reaches must be the ones that end
    # up on the clipboard.
    var app = testApp(40)
    let lay = testLayout()          # 10 rows visible of 40, scroll starts at 30
    check app.transcript.len == 40
    app.scroll = 10                 # 10 lines back from the tail: rows 20..29
    app.handleEvent(mouseEvent(maPress, 4, 8), lay, 20)
    check app.sel.anchor == Cell(row: 26, col: 2)
    app.handleEvent(mouseEvent(maMove, 4, 99), lay, 20)
    # Past the bottom edge the head clamps to the last visible row, so the
    # drag reaches row 29 instead of stopping at row 29's predecessor.
    check app.sel.head == Cell(row: 29, col: 2)
    app.handleEvent(mouseEvent(maRelease, 4, 99), lay, 20)
    check app.takePendingCopy() == "w 26\nrow 27\nrow 28\nro"

suite "clipboard":
  # The one part of selection that escapes the process. Writing is fire and
  # forget - there is no reply to poll - so the sequence itself is all that can
  # be checked.

  const prefix = "\x1b]52;c;"
  const st = "\x1b\\"

  test "osc52 carries the payload in standard base64, closed by ST":
    let seq = osc52Sequence("hello clipboard")
    check seq.startsWith(prefix)
    check seq.endsWith(st)
    check base64.decode(seq[prefix.len ..< seq.len - st.len]) == "hello clipboard"

  test "osc52 carries utf-8 payloads byte for byte":
    let seq = osc52Sequence("日本 — über")
    check base64.decode(seq[prefix.len ..< seq.len - st.len]) == "日本 — über"

  test "an empty selection still produces a valid sequence":
    let seq = osc52Sequence("")
    check seq == prefix & st

  test "a payload past the limit is truncated on a rune boundary":
    # kitty rejects a whole sequence over 100KB, so a long selection is clipped
    # instead of dropped; clipping mid-rune would emit a broken character.
    let text = "ab" & repeat("日", 40000)
    let seq = osc52Sequence(text)
    let decoded = base64.decode(seq[prefix.len ..< seq.len - st.len])
    check decoded.len < text.len
    check decoded.len <= 96 * 1024
    check decoded.endsWith("日")
    check decoded.len mod 3 == 2

suite "themes":
  # A theme is only ever seen as painted cells, so most of these read a
  # `TerminalBuffer` after a real frame: the canvas, the two bars and the text
  # on them are precisely what a palette swap gets wrong, and none of it is
  # visible from the transcript data.

  # Switches are global, so every test that makes one puts the default back.
  template themed() =
    check useTheme("light")
    defer: discard useTheme("light")

  proc frameApp(): App =
    ## An app with one assistant message and an empty prompt, which is the
    ## smallest thing `render` will paint.
    var chat = Chat()
    chat.addMessage(rAssistant, "# Title\n\nbody")
    result = App(chat: chat, input: newInputBox(),
                 backend: newMockBackend("mock"), streamIdx: -1, streaming: false)

  proc paint(t: Theme): TerminalBuffer =
    ## One frame in theme `t`, on a buffer large enough for the layout.
    discard useTheme(t.name)
    var tb = newTerminalBuffer(40, 10)
    var app = frameApp()
    render(tb, app)     # not UFCS: the buffer comes first
    result = tb

  test "light is the default, and both themes are listed":
    check defaultTheme.name == "light"
    check themeNames() == @["light", "dark"]
    check themes.len == themeNames().len

  test "a theme name is matched without regard to case or padding":
    check isThemeName("DARK")
    check isThemeName("  dark  ")
    check not isThemeName("blue")
    check themeByName("Dark").name == "dark"
    # An unknown name resolves to the default rather than raising: a typo in a
    # config file must not stop the UI from starting.
    check themeByName("blue").name == defaultTheme.name

  test "an unknown name leaves the current theme alone":
    themed()
    check useTheme("dark")
    check not useTheme("blue")
    check currentTheme.name == "dark"

  test "a frame paints the canvas behind everything":
    # The failure this pins: a span with no background of its own resolving to
    # `bgNone`, which the terminal reads as *its* background. The transcript
    # would then be the terminal's colour with the theme's text painted on it -
    # invisible in a light theme, and a dark band across a white canvas.
    let tb = paint(lightTheme)
    check tb[2, 2].fg == lightTheme.assistant     # the role label
    check tb[2, 2].bg == lightTheme.bg
    check tb[2, 3].bg == lightTheme.bg            # body text
    check tb[39, 2].bg == lightTheme.bg           # empty margin right of it

  test "the bars take their colours from the theme":
    themed()
    for t in [lightTheme, darkTheme]:
      let tb = paint(t)
      check tb[0, 0].bg == t.barBg                # header
      check tb[0, 0].fg == t.barFg
      check tb[20, 9].bg == t.barBg               # status bar

  test "switching repaints the whole frame":
    # Same chat, same layout, opposite palette: nothing may be left holding the
    # previous theme's colour.
    themed()
    let light = paint(lightTheme)
    let dark = paint(darkTheme)
    check light[39, 2].bg == lightTheme.bg
    check dark[39, 2].bg == darkTheme.bg
    check light[2, 2].fg != dark[2, 2].fg
    check dark[2, 2].fg == darkTheme.assistant

  test "the cursor and the selection come from the theme too":
    # Both paint a background of their own, which is the case where a wrong
    # theme is loudest: the cursor on a light canvas is a blue block, and the
    # selection has to stay readable against whatever it is drawn over.
    themed()
    for t in [lightTheme, darkTheme]:
      discard useTheme(t.name)
      var tb = newTerminalBuffer(40, 10)
      var app = frameApp()
      app.sel.start(Cell(row: 0, col: 0))
      app.sel.extendTo(Cell(row: 1, col: 4))
      render(tb, app)
      # The prompt row holds the block cursor, one past the `❯` gutter; the
      # transcript row it selects over is above it.
      check tb[3, 8].bg == t.cursorBg
      check tb[3, 8].fg == t.cursor
      check tb[3, 2].bg == t.selectBg
      check tb[3, 2].fg == t.select

  test "the two themes are opposites":
    themed()
    check lightTheme.bg != darkTheme.bg
    check lightTheme.text != darkTheme.text
    # Body text has to contrast with the canvas it is painted on, or the
    # transcript is unreadable in one of the two themes.
    check lightTheme.text == fgBlack
    check darkTheme.text == fgWhite
    # Terminals do not agree on what the eight ANSI colours mean: GNOME
    # Terminal's bgWhite is #d0cfcc and its bgBlack #171421. Green, yellow and
    # cyan wash out on a light grey canvas, so the light theme draws canvas
    # text only in black, blue, magenta and red; `ok` is exempt because it
    # lands on the black status bar, not the canvas. On the dark side blue's
    # dark-palette shade (#12488b) is barely visible on a near-black canvas,
    # so the dark theme keeps it off the transcript entirely.
    for fg in [lightTheme.text, lightTheme.code, lightTheme.heading1,
               lightTheme.heading2, lightTheme.heading3, lightTheme.quote,
               lightTheme.user, lightTheme.assistant, lightTheme.tool,
               lightTheme.error, lightTheme.prompt,
               lightTheme.accent, lightTheme.rule, lightTheme.codeBar]:
      check fg notin [fgWhite, fgGreen, fgYellow, fgCyan]
    check lightTheme.ok == fgGreen      # status bar only, on bgBlack
    for fg in [darkTheme.text, darkTheme.code, darkTheme.heading1,
               darkTheme.heading2, darkTheme.heading3, darkTheme.quote,
               darkTheme.user, darkTheme.assistant, darkTheme.tool,
               darkTheme.error, darkTheme.ok, darkTheme.prompt,
               darkTheme.accent, darkTheme.rule, darkTheme.codeBar]:
      check fg != fgBlack
      check fg != fgBlue

  test "markdown picks up the theme in force":
    themed()
    discard useTheme("dark")
    let line = renderMarkdown("# hi", 40)[0]
    check line.spans[0].fg == darkTheme.heading1
    discard useTheme("light")
    check renderMarkdown("# hi", 40)[0].spans[0].fg == lightTheme.heading1

  test "/themes lists every theme and marks the current one":
    themed()
    discard useTheme("dark")
    let said = themeCommand("")
    for name in themeNames():
      check name in said
    check said.contains("* " & currentTheme.name)
    check "light" in said and said.contains("* dark")

  test "/themes <name> switches and says what it switched from":
    themed()
    let dir = getTempDir() / "threecodex_theme_cmd"
    setSessionDir(dir)
    defer: removeDir(dir)
    let said = themeCommand("dark")
    check currentTheme.name == "dark"
    check "was light" in said

  test "/themes <name> saves the choice":
    themed()
    let dir = getTempDir() / "threecodex_theme_save"
    setSessionDir(dir)
    defer: removeDir(dir)
    discard themeCommand("dark")
    check fileExists(configPath())
    let saved = parseFile(configPath())
    check saved["theme"].getStr("") == "dark"

  test "/themes <unknown> lists the names it does know":
    themed()
    let said = themeCommand("blue")
    check "blue" in said
    for name in themeNames():
      check name in said
    check currentTheme.name == "light"       # left alone

  test "switching to the theme already in force is not an error":
    themed()
    let dir = getTempDir() / "threecodex_theme_same"
    setSessionDir(dir)
    defer: removeDir(dir)
    let said = themeCommand("light")
    check currentTheme.name == "light"
    check said.contains("light")

  test "a command splits into its name and its argument":
    check splitCommand("/themes").name == "/themes"
    check splitCommand("/themes").arg == ""
    check splitCommand("/themes dark").name == "/themes"
    check splitCommand("/themes dark").arg == "dark"
    check splitCommand("/themes   dark  ").arg == "dark"
    check splitCommand("/themes\tdark").arg == "dark"
    # The slash stays on the name so `/themes` is matched whole.
    check splitCommand("/themes dark").name != "themes"

suite "preferences":
  # Best-effort in both directions: nothing here is allowed to stop the UI from
  # starting, and a theme that cannot be saved is reported rather than lost.

  proc isolatedConfig(suffix: string): string =
    ## Point the config at a temp directory and hand back the path.
    result = getTempDir() / ("threecodex_" & suffix)
    setSessionDir(result)
    removeDir(result)

  test "the theme round-trips through the config file":
    let dir = isolatedConfig("prefs_roundtrip")
    defer: removeDir(dir)
    check saveConfig(Config(theme: "dark"))
    check loadConfig().theme == "dark"

  test "the config file sits next to the session document":
    let dir = isolatedConfig("prefs_location")
    defer: removeDir(dir)
    discard saveConfig(Config())
    check configPath().parentDir == sessionDir()
    check sessionPath().parentDir == configPath().parentDir

  test "no config file means the default theme":
    let dir = isolatedConfig("prefs_absent")
    defer: removeDir(dir)
    check loadConfig().theme == ""
    # An empty setting must not be a crash: `applyTheme` simply keeps the
    # default.
    applyTheme(loadConfig().theme)
    check currentTheme.name == defaultTheme.name

  test "a corrupt config file means the default theme":
    let dir = isolatedConfig("prefs_corrupt")
    defer: removeDir(dir)
    createDir(sessionDir())
    writeFile(configPath(), "}{ not json")
    check loadConfig().theme == ""
    applyTheme(loadConfig().theme)
    check currentTheme.name == defaultTheme.name

  test "a config file naming a theme that does not exist is ignored":
    let dir = isolatedConfig("prefs_unknown")
    defer: removeDir(dir)
    createDir(sessionDir())
    writeFile(configPath(), """{"theme": "chartreuse"}""")
    applyTheme(loadConfig().theme)
    check currentTheme.name == defaultTheme.name

  test "a theme saved in the config is the one the next launch uses":
    let dir = isolatedConfig("prefs_reload")
    defer: removeDir(dir)
    discard saveConfig(Config(theme: "dark"))
    discard useTheme("light")
    applyTheme(loadConfig().theme)
    check currentTheme.name == "dark"
    discard useTheme("light")

