## Mouse selection over the rendered transcript.
##
## Positions are transcript coordinates, not screen coordinates: a row index
## into the `seq[Line]` the renderer built for the current width, plus a
## display column within that row. Screen coordinates are what the terminal
## reports, but a selection anchored to them would slide across the text the
## instant the transcript scrolled - and scrolling is exactly what happens
## while dragging. `app.nim` performs that one translation at the edge, and
## everything here stays pure and testable.
##
## Like the transcript itself, a selection survives scrolling *and* re-wrapping
## on resize: rows keep their identity, and the renderer re-slices them.

import ./markdown
import ./uwidth

const
  lineEndCol* = 1 shl 30   ## A column at or past the end of any line.

type
  Cell* = object
    row*: int   ## Row within the transcript.
    col*: int   ## Display column within that row.

  Selection* = object
    anchor*: Cell   ## Where the drag began.
    head*: Cell     ## Where it currently reaches.
    active*: bool   ## False while nothing is selected.

proc newSelection*(): Selection =
  ## Nothing highlighted, nothing to copy.
  Selection()

proc selection*(a, b: Cell): Selection =
  ## A selection between two cells, whichever way the pointer was dragged.
  Selection(anchor: a, head: b, active: true)

proc start*(sel: var Selection, c: Cell) =
  ## Begin a drag at `c`, both ends together.
  ##
  ## Nothing is highlighted yet - and so nothing reaches the clipboard if the
  ## button is released right away - until the pointer actually moves.
  sel.anchor = c
  sel.head = c
  sel.active = true

proc extendTo*(sel: var Selection, c: Cell) =
  ## Move the leading end of the drag to `c`, leaving the anchor where it is.
  if sel.active:
    sel.head = c

proc clear*(sel: var Selection) =
  ## Drop the selection. A no-op when there is nothing selected, so callers do
  ## not have to guard.
  sel.active = false

proc empty*(sel: Selection): bool =
  ## True when a drag never left its anchor, so there is nothing to copy.
  not sel.active or sel.anchor == sel.head

proc ordered*(sel: Selection): tuple[top, bot: Cell] =
  ## The two ends in row order, so callers never care which way the pointer
  ## was dragged.
  if (sel.anchor.row, sel.anchor.col) <= (sel.head.row, sel.head.col):
    result = (sel.anchor, sel.head)
  else:
    result = (sel.head, sel.anchor)

proc clampRows*(sel: var Selection, rows: int) =
  ## Keep a live selection inside a transcript that has just been re-wrapped.
  ##
  ## Rows come and go as text wraps to a different width, and a highlight left
  ## pointing past the end of the transcript would paint nothing while still
  ## offering stale text up to the clipboard. With no rows at all it goes.
  if not sel.active:
    return
  if rows <= 0:
    sel.clear()
    return
  let last = rows - 1
  sel.anchor.row = clamp(sel.anchor.row, 0, last)
  sel.head.row = clamp(sel.head.row, 0, last)

proc rowRange*(sel: Selection, row: int): tuple[cs, ce: int] =
  ## The selected column range on `row`, or `(-1, -1)` when it is untouched.
  ##
  ## `ce` is the real column only for the final row of the selection;
  ## otherwise it is `lineEndCol`, so a whole-row highlight never has to know
  ## how wide that row turned out to be.
  if not sel.active:
    return (-1, -1)
  let (top, bot) = sel.ordered()
  if row < top.row or row > bot.row:
    return (-1, -1)
  result.cs = if row == top.row: top.col else: 0
  result.ce = if row == bot.row: bot.col else: lineEndCol

proc selectedText*(sel: Selection, lines: seq[Line]): string =
  ## The plain text the selection covers, with rows joined by newlines.
  ##
  ## Row boundaries become newlines, so copying a paragraph wrapped across
  ## three rows yields three lines - one per visual row, which is what was
  ## actually selected.
  if not sel.active or lines.len == 0:
    return
  let (top, bot) = sel.ordered()
  if top.row >= lines.len:
    return
  let botRow = min(bot.row, lines.len - 1)
  if top.row == botRow:
    return sliceColumns(lines[top.row].lineText, top.col, bot.col)
  for row in top.row ..< botRow:
    let text = lines[row].lineText
    result.add sliceColumns(text, if row == top.row: top.col else: 0,
                            lineEndCol)
    result.add '\n'
  result.add sliceColumns(lines[botRow].lineText, 0, bot.col)

proc splitSelected*(s: string, fromCol, toCol: int): tuple[before, sel, after: string] =
  ## Cut `s` into the part before the selection, the selected part, and the
  ## rest. Pass a negative `fromCol` for "nothing selected here".
  ##
  ## Highlighting is done per span rather than per line so that a selection can
  ## be painted in the middle of a bold run or a code span without disturbing
  ## the styling of the text either side of it.
  if fromCol < 0 or toCol <= fromCol:
    return (s, "", "")
  result.before = sliceColumns(s, 0, fromCol)
  result.sel = sliceColumns(s, fromCol, toCol)
  result.after = sliceColumns(s, toCol, lineEndCol)
