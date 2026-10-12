## Tests for the POSIX input decoder.
##
## The parser is pure - bytes in, events out - so the whole module can be
## exercised without a tty. That matters: escape-sequence handling is exactly
## the sort of code that is painful to debug through a live terminal.

import std/[sequtils, strutils, unicode, unittest]
import illwill
import ../src/threecodex/keyevent

suite "keyevent":

  proc one(data: string, flushEsc = true): InputEvent =
    ## Decode exactly one event; fails loudly if the count is not 1.
    let evs = newInputReader().parse(data, flushEsc)
    doAssert evs.len == 1, "expected 1 event, got " & $evs.len & " for " &
                           escape(data)
    evs[0]

  test "plain ascii characters come through as runes":
    let e = one("a")
    check e.kind == evRune
    check $(e.rune) == "a"

  test "utf-8 multibyte input survives":
    # The whole point of the module: illwill drops all of these.
    for s in ["ä", "ö", "ü", "日", "本", "→", "😀", "é"]:
      let e = one(s)
      check e.kind == evRune
      check $(e.rune) == s

  test "a multibyte rune split across reads is buffered":
    var r = newInputReader()
    let bytes = "日"
    check r.parse(bytes[0 ..< 1], flushEsc = false).len == 0
    check r.pending() == 1
    let evs = r.parse(bytes[1 .. ^1], flushEsc = false)
    check evs.len == 1
    check $(evs[0].rune) == "日"

  test "Enter and Ctrl+J are distinct":
    # illwill folds both onto Key.Enter, which is why it has no newline chord.
    check one("\r").key == Key.Enter
    let j = one("\n")
    check j.kind == evKey
    check j.key == Key.CtrlJ

  test "control bytes map to ctrl keys":
    check one("\x01").key == Key.CtrlA
    check one("\x03").key == Key.CtrlC
    check one("\x04").key == Key.CtrlD
    check one("\x17").key == Key.CtrlW
    check one("\t").key == Key.Tab
    check one("\x7f").key == Key.Backspace

  test "a bare escape flushes to the Escape key":
    let e = one("\x1b", flushEsc = true)
    check e.key == Key.Escape

  test "a lone escape is held back when more input may follow":
    var r = newInputReader()
    check r.parse("\x1b", flushEsc = false).len == 0
    check r.pending() == 1

  test "arrow keys parse in CSI and SS3 form":
    check one("\x1b[A").key == Key.Up
    check one("\x1b[B").key == Key.Down
    check one("\x1b[C").key == Key.Right
    check one("\x1b[D").key == Key.Left
    check one("\x1bOA").key == Key.Up
    check one("\x1bOD").key == Key.Left

  test "tilde-delimited keys parse":
    check one("\x1b[3~").key == Key.Delete
    check one("\x1b[1~").key == Key.Home
    check one("\x1b[4~").key == Key.End
    check one("\x1b[5~").key == Key.PageUp
    check one("\x1b[6~").key == Key.PageDown

  test "modifier parameters decode as a bitmask":
    # xterm sends 1 + bitmask: 1=Shift, 2=Alt, 4=Ctrl.
    let shift = one("\x1b[1;2A")
    check shift.key == Key.Up and shift.mods.shift

    let ctrl = one("\x1b[1;5A")
    check ctrl.key == Key.Up and ctrl.mods.ctrl

    let alt = one("\x1b[1;3C")
    check alt.key == Key.Right and alt.mods.alt

    let both = one("\x1b[1;6D")
    check both.key == Key.Left and both.mods.shift and both.mods.ctrl

  test "modified special keys are no longer swallowed":
    # illwill reads this as "ESC [ 1" and discards it, so Ctrl+Up does nothing.
    let e = one("\x1b[1;5A")
    check e.kind == evKey
    check e.key == Key.Up
    check e.mods.ctrl

  test "modified tilde keys carry their modifier":
    let e = one("\x1b[3;5~")
    check e.key == Key.Delete
    check e.mods.ctrl

  test "kitty CSI-u delivers Shift+Enter":
    let e = one("\x1b[13;2u")
    check e.kind == evKey
    check e.key == Key.Enter
    check e.mods.shift

  test "kitty CSI-u delivers plain printable characters":
    let e = one("\x1b[97u")
    check e.kind == evRune
    check $(e.rune) == "a"

  test "alt-prefixed characters report the alt modifier":
    let e = one("\x1bx")
    check e.kind == evRune
    check $(e.rune) == "x"
    check e.mods.alt

  test "sgr mouse press, release and wheel are decoded":
    let press = one("\x1b[<0;10;5M")
    check press.kind == evMouse
    check press.mouse.action == maPress
    check press.mouse.x == 9 and press.mouse.y == 4

    check one("\x1b[<0;10;5m").mouse.action == maRelease
    check one("\x1b[<64;3;3M").mouse.action == maScrollUp
    check one("\x1b[<65;3;3M").mouse.action == maScrollDown

  test "a mouse report does not swallow the following key":
    let evs = newInputReader().parse("\x1b[<0;1;1Mx")
    check evs.len == 2
    check evs[0].kind == evMouse
    check evs[1].kind == evRune

  test "a burst of bytes decodes in order":
    let evs = newInputReader().parse("hi\x1b[A\x7f")
    check evs.len == 4
    check $(evs[0].rune) == "h"
    check $(evs[1].rune) == "i"
    check evs[2].key == Key.Up
    check evs[3].key == Key.Backspace

  test "an escape sequence split across three reads still parses":
    var r = newInputReader()
    check r.parse("\x1b", flushEsc = false).len == 0
    check r.parse("[1", flushEsc = false).len == 0
    let evs = r.parse(";5A", flushEsc = false)
    check evs.len == 1
    check evs[0].key == Key.Up and evs[0].mods.ctrl
    check r.pending() == 0

  test "garbage bytes are dropped rather than stalling the parser":
    # A stray continuation byte or an unterminated unknown sequence must not
    # wedge the reader - the buffer has to keep draining.
    var r = newInputReader()
    let evs = r.parse("\x80\xff\x1b[999999999999Xz")
    check evs.len >= 1
    check $(evs[^1].rune) == "z"

  test "a runaway sequence is discarded instead of buffering forever":
    var r = newInputReader()
    let evs = r.parse("\x1b[" & repeat("1", 200), flushEsc = false)
    check evs.len == 0
    check r.pending() < 200

  test "pending reports buffered bytes":
    var r = newInputReader()
    check r.pending() == 0
    discard r.parse("\x1b[1;5", flushEsc = false)
    check r.pending() > 0