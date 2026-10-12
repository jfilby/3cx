## A small Markdown subset renderer that targets an illwill terminal buffer.
##
## The pipeline is deliberately two-stage:
##
## 1. `parseBlocks` turns raw text into styled blocks (headings, list items,
##    fenced code, quotes, rules) with their left padding and hanging indent.
## 2. `renderMarkdown` word-wraps those blocks to a concrete column width,
##    producing `Line` values made of `Span`s.
##
## Keeping wrapping separate from parsing means the transcript can be re-wrapped
## on terminal resize without re-parsing the Markdown, and the `Line`/`Span`
## types stay a trivial thing for the renderer to blit.

import std/strutils
import illwill
import ./theme
import ./uwidth

type
  Span* = object
    text*: string
    fg*: ForegroundColor
    bg*: BackgroundColor
    bold*: bool
    italic*: bool
    underline*: bool

  Line* = object
    spans*: seq[Span]

  Block = object
    indent: int        ## Left padding of the first row, in columns.
    contIndent: int    ## Left padding of wrapped rows, in columns.
    prefix: string     ## Marker drawn at the start of the first row.
    prefixFg: ForegroundColor
    content: seq[Span] ## The block body.
    rule: bool         ## This block is a horizontal rule.
    blank: bool        ## This block is a vertical spacer.

# ---------------------------------------------------------------------------
# Line helpers
# ---------------------------------------------------------------------------

proc addSpan*(line: var Line, s: Span) =
  ## Append `s`, merging into the previous span when the styling matches so we
  ## emit as few write calls as possible.
  if s.text.len == 0:
    return
  if line.spans.len > 0:
    let last = line.spans.high
    if line.spans[last].fg == s.fg and line.spans[last].bg == s.bg and
       line.spans[last].bold == s.bold and
       line.spans[last].italic == s.italic and
       line.spans[last].underline == s.underline:
      line.spans[last].text.add s.text
      return
  line.spans.add s

proc lineWidth*(l: Line): int =
  ## Total width of all spans in the line.
  for s in l.spans:
    result += displayWidth(s.text)

proc lineText*(l: Line): string =
  ## The line rendered as plain text, used for hit testing and tests.
  for s in l.spans:
    result.add s.text

# ---------------------------------------------------------------------------
# Inline parsing
# ---------------------------------------------------------------------------

proc parseInline*(s: string, fg: ForegroundColor,
                  bold, italic, underline: bool): seq[Span] =
  ## Split a single run of Markdown into styled spans.
  ##
  ## Supports `**bold**`, `*italic*` and `` `code` ``. Anything unrecognised is
  ## passed through untouched. Nested emphasis is not supported - that is a
  ## known limitation of the prototype rather than an oversight.
  var
    buf = ""
    spans: seq[Span]  ## Accumulator; `flush` is a nested proc and may not
                      ## capture `result`.

  proc flush() =
    if buf.len > 0:
      spans.add Span(text: buf, fg: fg, bold: bold, italic: italic,
                      underline: underline)
      buf.setLen(0)

  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '`' and i + 1 < s.len:
      let close = s.find('`', i + 1)
      if close > i + 1:
        flush()
        spans.add Span(text: s.substr(i + 1, close - 1), fg: colCode,
                        bold: bold, underline: true)
        i = close + 1
        continue
    elif c == '*' and i + 1 < s.len and s[i + 1] == '*':
      let close = s.find("**", i + 2)
      if close > i + 2:
        flush()
        spans.add Span(text: s.substr(i + 2, close - 1), fg: fg, bold: true,
                        italic: italic, underline: underline)
        i = close + 2
        continue
    elif c == '*':
      let close = s.find('*', i + 1)
      if close > i + 1:
        flush()
        spans.add Span(text: s.substr(i + 1, close - 1), fg: fg, bold: bold,
                        italic: true, underline: underline)
        i = close + 1
        continue
    buf.add c
    inc i
  flush()

  result = spans

# ---------------------------------------------------------------------------
# Block parsing
# ---------------------------------------------------------------------------

proc isRule(line: string): bool =
  ## True for `---`, `***`, `___` and friends.
  let t = line.strip()
  if t.len < 3:
    return false
  let c = t[0]
  if c notin {'-', '*', '_'}:
    return false
  for ch in t:
    if ch != c:
      return false
  true

proc headingColor(level: int): ForegroundColor =
  case level
  of 1: colHeading1
  of 2: colHeading2
  else: colHeading3

proc parseBlocks(md: string): seq[Block] =
  ## Split Markdown into styled blocks with their indents resolved.
  var
    inCode = false
    codeLines: seq[string]
    blocks: seq[Block]  ## Accumulator; a nested proc may not capture `result`.

  proc flushCode() =
    ## Emit any buffered fenced code as a single block behind a gutter bar.
    if codeLines.len == 0:
      return
    var content: seq[Span]
    for i, l in codeLines:
      if i > 0:
        content.add Span(text: "\n", fg: colCode)
      content.add Span(text: l, fg: colCode)
    blocks.add Block(indent: 2, contIndent: 4, prefix: "\u2502 ",
                     prefixFg: colCodeBar, content: content)
    blocks.add Block(blank: true)
    codeLines.setLen(0)

  for raw in md.splitLines():
    let trimmed = raw.strip()

    if trimmed.startsWith("```"):
      if inCode:
        flushCode()
      inCode = not inCode
      continue

    if inCode:
      codeLines.add raw.strip(leading = true, trailing = false)
      continue

    if trimmed.len == 0:
      blocks.add Block(blank: true)
      continue

    if isRule(trimmed):
      blocks.add Block(rule: true)
      blocks.add Block(blank: true)
      continue

    # Heading: one to six '#' followed by a space.
    var hashes = 0
    while hashes < trimmed.len and trimmed[hashes] == '#':
      inc hashes
    if hashes >= 1 and hashes <= 6 and hashes < trimmed.len and
       trimmed[hashes] == ' ':
      let body = trimmed.substr(hashes + 1, trimmed.len - 1).strip()
      if result.len > 0:
        blocks.add Block(blank: true)
      blocks.add Block(indent: 0, contIndent: 0,
                       content: parseInline(body, headingColor(hashes),
                                            true, false, false))
      blocks.add Block(blank: true)
      continue

    # Block quote.
    if trimmed.startsWith("> "):
      let body = trimmed.substr(2, trimmed.len - 1).strip()
      blocks.add Block(indent: 2, contIndent: 4, prefix: "\u258f ",
                       prefixFg: colCodeBar,
                       content: parseInline(body, colQuote, false, true, false))
      continue

    # Bullet list.
    if trimmed.len > 1 and trimmed[0] in {'-', '*', '+'} and trimmed[1] == ' ':
      let body = trimmed.substr(2, trimmed.len - 1).strip()
      blocks.add Block(indent: 2, contIndent: 4, prefix: "\u2022 ",
                       prefixFg: colAccent,
                       content: parseInline(body, colText, false, false, false))
      continue

    # Ordered list: digits, a dot, then a space.
    var digits = 0
    while digits < trimmed.len and trimmed[digits] in {'0'..'9'}:
      inc digits
    if digits > 0 and digits + 1 < trimmed.len and
       trimmed[digits] == '.' and trimmed[digits + 1] == ' ':
      let marker = trimmed[0 .. digits] & " "
      let body = trimmed.substr(digits + 2, trimmed.len - 1).strip()
      blocks.add Block(indent: 2, contIndent: 2 + marker.len, prefix: marker,
                       prefixFg: colAccent,
                       content: parseInline(body, colText, false, false, false))
      continue

    # Plain paragraph line.
    blocks.add Block(indent: 0, contIndent: 0,
                     content: parseInline(trimmed, colText, false, false, false))

  if inCode:
    # Unterminated fence: emit what we have rather than losing the text.
    flushCode()

  result = blocks

# ---------------------------------------------------------------------------
# Wrapping
# ---------------------------------------------------------------------------

proc nextToken(s: string, i: var int): tuple[tok: string, isSpace: bool] =
  ## Pull the next run of spaces, or the next run of non-spaces, out of `s`.
  let isSpace = s[i] in {' ', '\t'}
  let start = i
  while i < s.len and (s[i] in {' ', '\t'}) == isSpace:
    inc i
  result.tok = s[start ..< i]
  result.isSpace = isSpace

proc wrapContent(content: seq[Span], prefix: string, prefixFg: ForegroundColor,
                 indent, contIndent, width: int): seq[Line] =
  ## Word-wrap styled content into lines of at most `width` columns.
  ##
  ## The first row starts at `indent` with `prefix` drawn after it; wrapped rows
  ## start at `contIndent`. A newline inside `content` forces a break, and a
  ## token too long for any single row is hard-broken so that nothing ever
  ## overflows the viewport.
  var
    cur: Line
    x = indent
    pendingSpace = false
    stalls = 0
    wrapped: seq[Line]  ## Accumulator; `flush` is a nested proc and cannot capture
                    ## `result`.

  if prefix.len > 0:
    cur.addSpan Span(text: prefix, fg: prefixFg)
    x += displayWidth(prefix)

  proc flush() =
    wrapped.add cur
    cur = Line()
    x = contIndent
    pendingSpace = false

  # Flatten the content, keeping explicit newlines as break markers so that
  # fenced code (which relies on them) survives wrapping intact.
  var segs: seq[Span]
  for sp in content:
    if '\n' notin sp.text:
      segs.add sp
    else:
      let parts = sp.text.split('\n')
      for i, p in parts:
        if p.len > 0:
          segs.add Span(text: p, fg: sp.fg, bold: sp.bold, italic: sp.italic,
                        underline: sp.underline)
        if i < parts.high:
          segs.add Span(text: "\n", fg: sp.fg)

  for sp in segs:
    if sp.text == "\n":
      flush()
      continue

    var i = 0
    while i < sp.text.len:
      let (tok, isSpace) = nextToken(sp.text, i)
      if isSpace:
        pendingSpace = true
        continue

      var rest = tok
      while rest.len > 0:
        stalls = 0
        var avail = width - x
        if avail <= 0:
          flush()
          continue

        if pendingSpace and x > contIndent:
          if displayWidth(rest) + 1 <= avail:
            cur.addSpan Span(text: " ", fg: sp.fg)
            inc x
          else:
            flush()
            continue
        pendingSpace = false

        if displayWidth(rest) <= avail:
          cur.addSpan Span(text: rest, fg: sp.fg, bold: sp.bold,
                           italic: sp.italic, underline: sp.underline)
          x += displayWidth(rest)
          break

        let (head, tail) = takeFitting(rest, avail)
        if head.len == 0:
          # Not even one rune fits on this row. Drop to a fresh one; the stall
          # counter guards the degenerate case of a terminal too narrow to hold
          # the hanging indent plus a single glyph.
          flush()
          inc stalls
          if stalls > 4:
            rest = ""
            break
          continue

        cur.addSpan Span(text: head, fg: sp.fg, bold: sp.bold, italic: sp.italic,
                         underline: sp.underline)
        rest = tail
        flush()

  if cur.spans.len > 0:
    wrapped.add cur

  result = wrapped

proc renderMarkdown*(md: string, width: int): seq[Line] =
  ## Render a Markdown document to styled lines `width` columns wide.
  let w = if width < 8: 8 else: width
  for b in parseBlocks(md):
    if b.rule:
      result.add Line(spans: @[Span(text: "\u2500".repeat(w), fg: colRule)])
    elif b.blank:
      result.add Line()
    else:
      result.add wrapContent(b.content, b.prefix, b.prefixFg,
                             b.indent, b.contIndent, w)

proc renderPlain*(text: string, width: int): seq[Line] =
  ## Wrap `text` without interpreting any Markdown.
  ##
  ## Used for the user's own messages, where a leading `- ` or `#` is far more
  ## likely to be literal intent than formatting.
  let w = if width < 8: 8 else: width
  var content: seq[Span]
  let parts = text.split('\n')
  for i, p in parts:
    if i > 0:
      content.add Span(text: "\n", fg: colText)
    content.add Span(text: p, fg: colText)
  result = wrapContent(content, "", colText, 0, 0, w)