## A multi-line prompt editor with recallable history.
##
## The editor is deliberately dumb about terminal concerns: it owns a list of
## lines plus a cursor, and knows nothing about scrolling or rendering. The app
## layer decides how many rows it is allowed to occupy.

import std/[strutils, unicode]
import ./uwidth

type
  InputBox* = object
    lines*: seq[string]  ## The buffer, one entry per row.
    line*: int           ## Cursor row.
    col*: int            ## Cursor byte offset within `lines[line]`.
    history*: seq[string]
    histIdx*: int        ## Index into `history`; `history.len` means "the draft".
    draft*: string       ## Input saved when the user started recalling history.

const
  maxVisibleLines* = 6 ## Never let the input box grow taller than this.

proc newInputBox*(): InputBox =
  result.lines = @[""]
  result.line = 0
  result.col = 0
  result.histIdx = 0

proc text*(ib: InputBox): string =
  ## The buffer joined back into a single string.
  for i, l in ib.lines:
    if i > 0:
      result.add '\n'
    result.add l

proc isEmpty*(ib: InputBox): bool =
  ib.text.strip.len == 0

proc currentLine*(ib: InputBox): string =
  if ib.line >= 0 and ib.line < ib.lines.len: ib.lines[ib.line] else: ""

proc cursorColumn*(ib: InputBox): int =
  ## How many columns the cursor sits at on its row.
  displayWidth(ib.currentLine.substr(0, ib.col - 1))

# ---------------------------------------------------------------------------
# Insertion
# ---------------------------------------------------------------------------

proc insertChar*(ib: var InputBox, c: char) =
  let line = ib.currentLine
  ib.lines[ib.line] = line.substr(0, ib.col - 1) & c & line.substr(ib.col, line.len - 1)
  inc ib.col

proc insertRune*(ib: var InputBox, r: Rune) =
  ## Insert a whole rune, keeping the cursor on a rune boundary.
  let enc = $r
  let line = ib.currentLine
  ib.lines[ib.line] = line.substr(0, ib.col - 1) & enc & line.substr(ib.col, line.len - 1)
  ib.col += enc.len

proc insertNewline*(ib: var InputBox) =
  let line = ib.currentLine
  let head = line.substr(0, ib.col - 1)
  let tail = line.substr(ib.col, line.len - 1)
  ib.lines[ib.line] = head
  ib.lines.insert(tail, ib.line + 1)
  inc ib.line
  ib.col = 0

proc paste*(ib: var InputBox, s: string) =
  ## Insert a multi-line string at the cursor.
  let parts = s.replace("\r\n", "\n").split('\n')
  for i, p in parts:
    if i > 0:
      ib.insertNewline()
    for r in p.runes:
      ib.insertRune(r)

# ---------------------------------------------------------------------------
# Deletion
# ---------------------------------------------------------------------------

proc backspace*(ib: var InputBox) =
  if ib.col > 0:
    let prev = offsetLeft(ib.currentLine, ib.col)
    let line = ib.currentLine
    ib.lines[ib.line] = line.substr(0, prev - 1) & line.substr(ib.col, line.len - 1)
    ib.col = prev
  elif ib.line > 0:
    let prevLen = ib.lines[ib.line - 1].len
    ib.lines[ib.line - 1].add ib.lines[ib.line]
    ib.lines.delete(ib.line)
    dec ib.line
    ib.col = prevLen

proc delete*(ib: var InputBox) =
  ## Forward delete.
  let line = ib.currentLine
  if ib.col < line.len:
    let nxt = offsetRight(line, ib.col)
    ib.lines[ib.line] = line.substr(0, ib.col - 1) & line.substr(nxt, line.len - 1)
  elif ib.line < ib.lines.high:
    ib.lines[ib.line].add ib.lines[ib.line + 1]
    ib.lines.delete(ib.line + 1)

proc deleteWord*(ib: var InputBox) =
  ## Delete the run of non-space characters before the cursor.
  var line = ib.currentLine
  let stop = min(ib.col, line.len)
  var i = stop
  while i > 0 and line[i - 1] in {' ', '\t'}: dec i
  while i > 0 and line[i - 1] notin {' ', '\t'}: dec i
  if i < stop:
    delete(line, i .. stop - 1)
  ib.lines[ib.line] = line
  ib.col = i

proc killToEnd*(ib: var InputBox) =
  ## Delete to the end of the row, pulling the next row up if the cursor is at
  ## the end.
  let line = ib.currentLine
  if ib.col < line.len:
    ib.lines[ib.line] = line.substr(0, ib.col - 1)
  elif ib.line < ib.lines.high:
    ib.lines.delete(ib.line)

proc killToStart*(ib: var InputBox) =
  let line = ib.currentLine
  ib.lines[ib.line] = line.substr(ib.col, line.len - 1)
  ib.col = 0

proc clearBuffer*(ib: var InputBox) =
  ib.lines = @[""]
  ib.line = 0
  ib.col = 0

# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------

proc moveLeft*(ib: var InputBox) =
  if ib.col > 0:
    ib.col = offsetLeft(ib.currentLine, ib.col)
  elif ib.line > 0:
    dec ib.line
    ib.col = ib.lines[ib.line].len

proc moveRight*(ib: var InputBox) =
  let line = ib.currentLine
  if ib.col < line.len:
    ib.col = offsetRight(line, ib.col)
  elif ib.line < ib.lines.high:
    inc ib.line
    ib.col = 0

proc moveUp*(ib: var InputBox): bool =
  ## Move up one row. Returns false when already on the first row, in which case
  ## the caller should treat the key as a history recall instead.
  if ib.line > 0:
    dec ib.line
    ib.col = min(ib.col, ib.lines[ib.line].len)
    return true
  false

proc moveDown*(ib: var InputBox): bool =
  ## Move down one row. Returns false when already on the last row.
  if ib.line < ib.lines.high:
    inc ib.line
    ib.col = min(ib.col, ib.lines[ib.line].len)
    return true
  false

proc moveHome*(ib: var InputBox) =
  ib.col = 0

proc moveEnd*(ib: var InputBox) =
  ib.col = ib.currentLine.len

proc wordLeft*(ib: InputBox): int =
  ## How many `moveLeft` calls are needed to reach the previous word boundary.
  ##
  ## Counted rather than performed, so the caller decides what to do with it -
  ## the UI binds Ctrl+Left to it. Spaces are skipped first, so repeated
  ## presses walk back word by word.
  if ib.col == 0:
    return (if ib.line > 0: 1 else: 0)
  let line = ib.currentLine
  var
    col = ib.col
    steps = 0
  while col > 0 and line[col - 1] in {' ', '\t'}:
    col = offsetLeft(line, col)
    inc steps
  while col > 0 and line[col - 1] notin {' ', '\t'}:
    col = offsetLeft(line, col)
    inc steps
  steps

proc wordRight*(ib: InputBox): int =
  ## How many `moveRight` calls are needed to reach the next word boundary.
  var
    col = ib.col
    steps = 0
  let line = ib.currentLine
  while col < line.len and line[col] in {' ', '\t'}:
    col = offsetRight(line, col)
    inc steps
  while col < line.len and line[col] notin {' ', '\t'}:
    col = offsetRight(line, col)
    inc steps
  if col >= line.len and ib.line < ib.lines.high:
    inc steps                        # step onto the following row
  steps

# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------

proc setText*(ib: var InputBox, s: string) =
  ib.lines = s.replace("\r\n", "\n").split('\n')
  if ib.lines.len == 0:
    ib.lines = @[""]
  ib.line = ib.lines.high
  ib.col = ib.lines[^1].len

proc submit*(ib: var InputBox): string =
  ## Return the current buffer, push it onto the history and clear the editor.
  result = ib.text
  if result.strip.len > 0 and (ib.history.len == 0 or ib.history[^1] != result):
    ib.history.add result
  ib.clearBuffer()
  ib.histIdx = ib.history.len
  ib.draft = ""

proc recallPrev*(ib: var InputBox) =
  ## Step back through history, saving the in-progress draft on the first step.
  if ib.history.len == 0:
    return
  if ib.histIdx > 0:
    if ib.histIdx == ib.history.len:
      ib.draft = ib.text
    dec ib.histIdx
    ib.setText(ib.history[ib.histIdx])

proc recallNext*(ib: var InputBox) =
  ## Step forward through history, restoring the draft once past the newest.
  if ib.histIdx < ib.history.len:
    inc ib.histIdx
    if ib.histIdx == ib.history.len:
      ib.setText(ib.draft)
    else:
      ib.setText(ib.history[ib.histIdx])

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

proc firstVisibleLine*(ib: InputBox, rows: int): int =
  ## Index of the first row to draw so that the cursor stays on screen.
  max(0, ib.line - rows + 1)

proc visibleLineCount*(ib: InputBox, rows: int): int =
  ## How many rows the editor needs, capped at `rows`.
  min(max(ib.lines.len, 1), max(rows, 1))