## Minimal Unicode helpers for a fixed-width terminal.
##
## Only what the UI actually needs: how many columns a string occupies, where
## the neighbouring rune boundaries are, and how to hard-break an over-long
## token so nothing ever overflows the viewport.

import std/unicode

proc runeWidth*(r: Rune): int =
  ## Approximate terminal column count for a single rune.
  ##
  ## Covers the common wide ranges (CJK, Hangul, fullwidth forms and emoji) plus
  ## zero-width control characters. Deliberately a short range table rather than
  ## a full Unicode table - for a terminal UI that is plenty.
  let v = uint32(ord(r))
  if v >= 0x1100'u32 and (
      (v <= 0x115F'u32) or
      (v >= 0x2E80'u32 and v <= 0xA4CF'u32 and v != 0x303F'u32) or
      (v >= 0xAC00'u32 and v <= 0xD7A3'u32) or
      (v >= 0xF900'u32 and v <= 0xFAFF'u32) or
      (v >= 0xFE30'u32 and v <= 0xFE6F'u32) or
      (v >= 0xFF00'u32 and v <= 0xFF60'u32) or
      (v >= 0xFFE0'u32 and v <= 0xFFE6'u32) or
      (v >= 0x1F300'u32 and v <= 0x1F9FF'u32)):
    2
  elif v < 0x20'u32 or (v >= 0x7F'u32 and v < 0xA0'u32):
    0
  else:
    1

proc displayWidth*(s: string): int =
  ## Total terminal columns occupied by `s`.
  var i = 0
  while i < s.len:
    let r = s.runeAt(i)
    inc result, runeWidth(r)
    i += r.size

proc offsetLeft*(s: string, col: int): int =
  ## Byte offset of the rune before `col`, clamped to the start of `s`.
  if col <= 0:
    return 0
  var i = min(col, s.len) - 1
  while i > 0 and (ord(s[i]) and 0xC0) == 0x80:
    dec i
  i

proc offsetRight*(s: string, col: int): int =
  ## Byte offset just past the rune starting at `col`, clamped to the end.
  if col >= s.len:
    return s.len
  var i = min(col, s.len) + 1
  while i < s.len and (ord(s[i]) and 0xC0) == 0x80:
    inc i
  i

proc takeFitting*(s: string, avail: int): tuple[head, rest: string] =
  ## Split `s` at the last rune boundary that fits within `avail` columns.
  var
    w = 0
    i = 0
  while i < s.len:
    let r = s.runeAt(i)
    let rw = runeWidth(r)
    if w + rw > avail:
      break
    w += rw
    i += r.size
  result.head = s.substr(0, i - 1)
  result.rest = s.substr(i, s.len - 1)

proc truncateToWidth*(s: string, width: int): string =
  ## Cut `s` so it occupies at most `width` columns.
  if width <= 0:
    return ""
  if displayWidth(s) <= width:
    return s
  result = takeFitting(s, width).head

proc colToOffset*(s: string, col: int): int =
  ## Byte offset of the rune occupying display column `col`.
  ##
  ## Clamped to both ends, so a column past the last rune gives `s.len` - which
  ## is also the correct answer for "everything in the string". Column indices
  ## are for hit testing, not of the `Col`-style cursor kind, so `0` means "the
  ## rune at the very start", not "before the first rune".
  var
    i = 0
    seen = 0
  while i < s.len:
    let r = s.runeAt(i)
    if seen + runeWidth(r) > col:
      return i
    seen += runeWidth(r)
    i += r.size
  result = s.len

proc sliceColumns*(s: string, fromCol, toCol: int): string =
  ## The runes occupying display columns `[fromCol, toCol)`.
  ##
  ## Wide runes come out whole: a drag that begins or ends on the left half of
  ## a double-width glyph copies the entire character rather than a mangled
  ## fragment. Out-of-range bounds are clamped rather than raising, so a
  ## selection that reaches past the end of a line stops at the end.
  if toCol <= fromCol:
    return
  let
    start = colToOffset(s, max(fromCol, 0))
    stop = colToOffset(s, max(toCol - 1, 0))
  result = s[start ..< offsetRight(s, stop)]