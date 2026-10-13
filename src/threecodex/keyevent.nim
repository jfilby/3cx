## A UTF-8 and modifier-aware terminal input decoder for POSIX.
##
## illwill 0.4.1 reads stdin one byte at a time and maps each byte straight onto
## its `Key` enum. That has three consequences this module exists to remove:
##
## 1. **Non-ASCII input is dropped.** Bytes above 0x7F map to no `Key` value, so
##    typing an umlaut or an emoji silently does nothing.
## 2. **Modifiers are lost.** Only `Key.ShiftA`/`Key.CtrlA` style combinations
##    survive, and only for plain letters.
## 3. **Modified special keys vanish entirely.** illwill reads `ESC [ 1 ; 5 A`
##    (Ctrl+Up) as `ESC [ 1`, fails to match, and *discards the sequence* - the
##    key press disappears rather than degrading to a plain Up.
##
## 4. **Ctrl-C never arrives as a byte at all.** illwill leaves `ISIG` alone, so
##    the tty driver turns `0x03` into SIGINT and nothing reaches stdin. That
##    is worth keeping - Ctrl-C has to terminate a wedged process - but it does
##    mean the decoder cannot be the only input path. `installCtrlCHook` latches
##    the signal and `poll` reports it as the `Key.CtrlC` the app expects.
##
## None of that information is missing from the terminal: `ESC [ 1 ; 5 A`
## encodes Ctrl+Up perfectly well. illwill simply throws it away. This module
## reads stdin directly instead, reassembles escape sequences across reads, and
## decodes UTF-8, so the app gets real runes and real modifier state.
##
## The parser is deliberately separated from the reader: `parse` is pure and
## takes bytes, so it is unit tested without a tty. `poll` is the thin POSIX
## layer that drains stdin and feeds it in.
##
## Scope: POSIX only, matching illwill's own terminal handling. On Windows
## `poll` falls back to translating illwill's `getKey`, which keeps the app
## buildable everywhere.

import std/[atomics, sequtils, strutils, unicode]
import illwill
when defined(posix):
  # posix defines its own `Key`, which would collide with illwill's.
  import std/posix except Key
  import std/termios

type
  Mods* = object
    ## Modifier state for one input event.
    shift*: bool
    ctrl*: bool
    alt*: bool

  EventKind* = enum
    evNone,   ## Nothing decoded (unused placeholder).
    evRune,   ## A printable character; see `rune`.
    evKey,    ## A non-printable special key; see `key`.
    evMouse   ## A mouse report; see `mouse`.

  MouseAction* = enum
    maNone, maPress, maRelease, maMove, maScrollUp, maScrollDown

  MouseEvent* = object
    x*, y*: int  ## Cell coordinates, zero-based.
    action*: MouseAction
    button*: int ## 0 = left, 1 = middle, 2 = right.
    mods*: Mods

  InputEvent* = object
    kind*: EventKind
    rune*: Rune      ## Valid when `kind == evRune`.
    key*: Key        ## Valid when `kind == evKey`.
    mods*: Mods      ## Valid for every kind.
    mouse*: MouseEvent

  InputReader* = ref object
    ## Buffers stdin between polls: a single `read` can return half an escape
    ## sequence, so bytes that do not yet form a complete event are kept here.
    buf: string

proc newInputReader*(): InputReader =
  InputReader(buf: "")

proc pending*(r: InputReader): int =
  ## Bytes buffered but not yet forming a complete event.
  r.buf.len

# ---------------------------------------------------------------------------
# Pure parsing
# ---------------------------------------------------------------------------

const
  maxSeqLen = 64 ## An escape sequence longer than this is treated as garbage.

type
  Step = object
    consumed: int     ## Bytes eaten; 0 when incomplete or invalid.
    needMore: bool    ## True when more bytes could complete the event.
    ev: InputEvent

proc decodeMods(n: int): Mods =
  ## xterm encodes modifiers as `1 + bitmask`; bit 1 = Shift, 2 = Alt, 4 = Ctrl.
  if n <= 1:
    return
  let m = n - 1
  result.shift = (m and 1) != 0
  result.alt = (m and 2) != 0
  result.ctrl = (m and 4) != 0

proc keyEvent(k: Key, mods = Mods()): InputEvent =
  InputEvent(kind: evKey, key: k, mods: mods)

proc runeEvent(r: Rune, mods = Mods()): InputEvent =
  InputEvent(kind: evRune, rune: r, mods: mods)

proc tildeKey(code: int): Key =
  ## Keys delivered as `ESC [ <n> ~`.
  case code
  of 1, 7: Key.Home
  of 2: Key.Insert
  of 3: Key.Delete
  of 4, 8: Key.End
  of 5: Key.PageUp
  of 6: Key.PageDown
  of 11: Key.F1
  of 12: Key.F2
  of 13: Key.F3
  of 14: Key.F4
  of 15: Key.F5
  of 17: Key.F6
  of 18: Key.F7
  of 19: Key.F8
  of 20: Key.F9
  of 21: Key.F10
  of 23: Key.F11
  of 24: Key.F12
  else: Key.None

proc letterKey(c: char): Key =
  ## Keys delivered as `ESC [ <c>` or `ESC O <c>`.
  case c
  of 'A': Key.Up
  of 'B': Key.Down
  of 'C': Key.Right
  of 'D': Key.Left
  of 'H': Key.Home
  of 'F': Key.End
  of 'P': Key.F1
  of 'Q': Key.F2
  of 'R': Key.F3
  of 'S': Key.F4
  else: Key.None

const
  ctrlKeys: array[27, Key] = [
    Key.None,  Key.CtrlA, Key.CtrlB, Key.CtrlC, Key.CtrlD, Key.CtrlE,
    Key.CtrlF, Key.CtrlG, Key.CtrlH, Key.Tab,   Key.CtrlJ, Key.CtrlK,
    Key.CtrlL, Key.Enter, Key.CtrlN, Key.CtrlO, Key.CtrlP, Key.CtrlQ,
    Key.CtrlR, Key.CtrlS, Key.CtrlT, Key.CtrlU, Key.CtrlV, Key.CtrlW,
    Key.CtrlX, Key.CtrlY, Key.CtrlZ
  ]

proc controlKey(b: char): Key =
  ## Map a C0 control byte onto a `Key`.
  ##
  ## Note that `'\r'` (Enter) and `'\n'` (Ctrl+J) are kept *distinct*. illwill
  ## folds both onto `Key.Enter`, which is why it cannot offer a newline chord.
  case b
  of '\r': Key.Enter
  of '\n': Key.CtrlJ
  of '\t': Key.Tab
  of '\x7f': Key.Backspace
  else:
    let n = int(b)
    if n >= 0 and n <= 26: ctrlKeys[n] else: Key.None

proc utf8Len(b: char): int =
  ## Byte length of the UTF-8 sequence starting at `b`; 0 if not a valid lead.
  let n = int(b)
  if n < 0x80: 1
  elif (n and 0xE0) == 0xC0: 2
  elif (n and 0xF0) == 0xE0: 3
  elif (n and 0xF8) == 0xF0: 4
  else: 0

proc csiFinal(s: string, start: int): int =
  ## Index of a CSI final byte (0x40..0x7E), or -1 if not present yet.
  var i = max(start, 0)
  while i < s.len:
    if s[i] >= '\x40' and s[i] <= '\x7e':
      return i
    inc i
  -1

proc parseParams(s: string, first, last: int): seq[int] =
  ## Parse the numeric parameters of a CSI sequence.
  if last <= first:
    return @[]
  for part in s[first ..< last].split(';'):
    var v = 0
    var ok = part.len > 0
    for ch in part:
      if ch in {'0' .. '9'}:
        v = v * 10 + (int(ch) - int('0'))
      else:
        ok = false
        break
    result.add (if ok: v else: 0)

proc parseMouse(params: seq[int], final: char): InputEvent =
  ## Decode an SGR mouse report: `ESC [ < b ; x ; y M|m`.
  var
    b = 0
    x = 0
    y = 0
  if params.len >= 3:
    b = params[0]; x = params[1]; y = params[2]
  elif params.len >= 1:
    # X10 mouse encoding packs the values into a single parameter.
    b = params[0]
    x = (b shr 8) and 0xFF
    y = b and 0xFF
    b = (b shr 16) and 0xFF

  let
    isMotion = (b and 32) != 0
    isWheel = (b and 64) != 0

  var action = maPress
  if isWheel:
    action = if (b and 1) == 0: maScrollUp else: maScrollDown
  elif final == 'm':
    action = maRelease
  elif isMotion:
    action = maMove

  result = InputEvent(
    kind: evMouse,
    mods: Mods(shift: (b and 4) != 0, alt: (b and 8) != 0,
               ctrl: (b and 16) != 0),
    mouse: MouseEvent(
      x: max(x - 1, 0), y: max(y - 1, 0),
      action: action, button: b and 3))

proc parseCsi(s: string): Step =
  ## Parse a sequence starting `ESC [`.
  let fin = csiFinal(s, 2)
  if fin < 0:
    if s.len > maxSeqLen:
      # Runaway sequence with no final byte: drop all of it. Consuming just the
      # ESC would replay the remainder as ordinary keystrokes and type junk into
      # the user's prompt.
      return Step(consumed: s.len)
    return Step(needMore: true)

  let final = s[fin]

  # SGR mouse: the parameters are prefixed with '<', which is not itself a
  # parameter, so parsing has to start after it.
  if s.len > 2 and s[2] == '<':
    return Step(consumed: fin + 1, ev: parseMouse(parseParams(s, 3, fin), final))

  let params = parseParams(s, 2, fin)

  # kitty/CSI-u: `ESC [ <code> [ ; <mods> ] u`. This is how modern terminals
  # deliver Shift+Enter, which has no legacy encoding.
  if final == 'u':
    if params.len == 0:
      return Step(consumed: fin + 1, ev: keyEvent(Key.None, Mods()))
    let
      code = params[0]
      mods = if params.len > 1: decodeMods(params[1]) else: Mods()
    # 13 is Enter; 57414 is kitty's legacy Enter codepoint.
    if code == 13 or code == 57414:
      return Step(consumed: fin + 1, ev: keyEvent(Key.Enter, mods))
    if code in 27..126:
      return Step(consumed: fin + 1,
                  ev: runeEvent(Rune(code), mods))
    return Step(consumed: fin + 1, ev: keyEvent(controlKey(char(code)), mods))

  let mods = if params.len > 1: decodeMods(params[1]) else: Mods()

  case final
  of '~':
    let k = if params.len > 0: tildeKey(params[0]) else: Key.None
    return Step(consumed: fin + 1, ev: keyEvent(k, mods))
  of 'M':
    # Legacy X10 mouse: three bytes trail the final. illwill enables SGR mode
    # (1006) so this should not occur in practice; swallow it if it does.
    if s.len < fin + 4:
      return Step(needMore: true)
    return Step(consumed: fin + 4, ev: InputEvent(kind: evNone))
  else:
    let k = letterKey(final)
    if k == Key.None:
      return Step(consumed: fin + 1)
    return Step(consumed: fin + 1, ev: keyEvent(k, mods))

proc parseSs3(s: string): Step =
  ## Parse `ESC O <final>`, optionally with modifiers: `ESC O 1 ; 5 A`.
  if s.len < 3:
    return Step(needMore: true)
  let fin = csiFinal(s, 2)
  if fin < 0:
    if s.len > maxSeqLen:
      return Step(consumed: s.len)
    return Step(needMore: true)
  let params = parseParams(s, 2, fin)
  let mods = if params.len > 1: decodeMods(params[1]) else: Mods()
  let k = letterKey(s[fin])
  if k == Key.None:
    return Step(consumed: fin + 1)
  Step(consumed: fin + 1, ev: keyEvent(k, mods))

proc step(s: string, flushEsc: bool): Step =
  ## Decode one event from the front of `s`.
  if s.len == 0:
    return Step(needMore: true)

  let b0 = s[0]

  if b0 == '\x1b':
    if s.len == 1:
      # Ambiguous: a bare Escape, or the start of a sequence whose bytes have
      # not arrived yet. `flushEsc` says no more input is waiting.
      if flushEsc:
        return Step(consumed: 1, ev: keyEvent(Key.Escape))
      return Step(needMore: true)

    case s[1]
    of '[': return parseCsi(s)
    of 'O': return parseSs3(s)
    of '\x1b':
      return Step(consumed: 1, ev: keyEvent(Key.Escape))
    else:
      # ESC followed by a byte: Alt+<key>. Decode the rune after the ESC.
      let tail = s[1 .. ^1]
      let n = utf8Len(tail[0])
      if n == 0:
        return Step(consumed: 2, ev: keyEvent(controlKey(s[1]), Mods(alt: true)))
      if tail.len < n:
        return Step(needMore: true)
      if n > 1 and anyIt(tail[1 ..< n], not (it >= '\x80' and it <= '\xbf')):
        return Step(consumed: 1 + n, ev: keyEvent(controlKey(s[1]), Mods(alt: true)))
      let r = tail[0 ..< n].runeAt(0)
      return Step(consumed: 1 + n, ev: runeEvent(r, Mods(alt: true)))

  if b0 < '\x20' or b0 == '\x7f':
    let k = controlKey(b0)
    if k == Key.None:
      return Step(consumed: 1)
    return Step(consumed: 1, ev: keyEvent(k))

  # Ordinary UTF-8.
  let n = utf8Len(b0)
  if n == 0:
    return Step(consumed: 1)          # stray continuation byte
  if s.len < n:
    return Step(needMore: true)
  # Validate only the trailing bytes: the lead byte is not a continuation byte.
  if n > 1 and anyIt(s[1 ..< n], not (it >= '\x80' and it <= '\xbf')):
    return Step(consumed: 1)          # malformed: drop the lead byte
  let r = s[0 ..< n].runeAt(0)
  Step(consumed: n, ev: runeEvent(r))

proc parse*(r: InputReader, data: string, flushEsc = true): seq[InputEvent] =
  ## Feed `data` into the reader and return whatever complete events it yields.
  ##
  ## Pure, and therefore the unit under test. `flushEsc` decides whether a
  ## lone trailing `ESC` is reported as the Escape key (true when the caller
  ## knows no more input is pending) or held back in case it is the start of a
  ## sequence.
  r.buf.add data

  var pos = 0
  while pos < r.buf.len:
    # Pass the whole remaining buffer. `flushEsc` only applies when the lone
    # trailing ESC is genuinely the last byte, so an ESC that turns out to
    # begin a sequence is never reported as the Escape key.
    let st = step(r.buf[pos .. ^1], flushEsc and pos == r.buf.len - 1)
    if st.needMore:
      break
    if st.consumed == 0:
      break
    if st.ev.kind != evNone:
      result.add st.ev
    pos += st.consumed

  if pos > 0:
    r.buf = if pos < r.buf.len: r.buf[pos ..< ^1] else: ""

# ---------------------------------------------------------------------------
# Ctrl-C: the terminal reports it as a signal, not as a byte
# ---------------------------------------------------------------------------

var sigintPending: Atomic[bool]
  ## Latched by the SIGINT hook, taken by `poll`.
  ##
  ## A signal handler may only run async-signal-safe code, and nothing Ctrl-C
  ## has to do qualifies: interrupting a turn takes locks and allocates, and
  ## tearing the terminal down writes to stdout. So the handler does the one
  ## legal thing - latch a flag - and the main loop, which is allowed to do
  ## all of it, does the work. The old hook ran the whole teardown in signal
  ## context and then called `quit(0)`; a second Ctrl-C landing mid-teardown
  ## found illwill already de-initialised, `checkInit` raised, and unwinding
  ## out of a signal handler segfaulted.

proc sigintHook() {.noconv.} =
  ## The SIGINT handler. Runs on whichever thread the kernel picks and between
  ## any two instructions of the program, hence the single atomic store.
  sigintPending.store(true, moRelease)

proc installCtrlCHook*() =
  ## Route SIGINT to `sigintHook` rather than the runtime's default.
  ##
  ## Call once, before the event loop starts. Without it SIGINT kills the
  ## process outright - the byte never reaches the decoder, so the app sees no
  ## Ctrl-C at all.
  setControlCHook(sigintHook)

proc takeCtrlCEvent(): bool =
  ## Take the latched Ctrl-C, if the hook left one.
  sigintPending.exchange(false, moAcquire)

# ---------------------------------------------------------------------------
# Reading from stdin (POSIX)
# ---------------------------------------------------------------------------

when defined(posix):
  var
    gSavedTermios: Termios
    gHaveSaved = false

  proc enableRawInput*(): bool =
    ## Stop the terminal driver from rewriting the bytes we care about.
    ##
    ## illwill's `consoleInit` clears `ICANON` and `ECHO` but leaves the input
    ## flags alone, so `ICRNL` stays on and the driver rewrites a carriage
    ## return (0x0D) into a newline (0x0A) before we ever read it. illwill can
    ## get away with that because it maps *both* onto `Key.Enter`; a decoder that
    ## keeps Enter and Ctrl+J distinct - as this one does - would otherwise see
    ## every Enter as a newline.
    ##
    ## `IXON` is cleared at the same time so Ctrl+S/Ctrl+Q cannot freeze the
    ## terminal. `ISIG` is deliberately left alone, so Ctrl+C still works.
    var tty: Termios
    if tcGetAttr(STDIN_FILENO, tty.addr) != 0:
      return false
    gSavedTermios = tty
    gHaveSaved = true
    tty.c_iflag = tty.c_iflag and not Cflag(ICRNL or IXON)
    discard tcSetAttr(STDIN_FILENO, TCSANOW, tty.addr)
    true

  proc restoreInput*() =
    ## Put the terminal's input flags back the way we found them.
    if gHaveSaved:
      discard tcSetAttr(STDIN_FILENO, TCSANOW, gSavedTermios.addr)
      gHaveSaved = false

  proc stopMouseTracking*() =
    ## Turn SGR mouse reporting off and drop any reports already queued.
    ##
    ## The shutdown path spends time (session save, backend stop) after the
    ## main loop has stopped reading input but before illwillDeinit disables
    ## mouse tracking. A click in that window queues an SGR mouse report -
    ## bytes like `51;108;19M` - and after `restoreInput` re-enables echo the
    ## shell prints them on the restored command line. Writing the disable
    ## sequence immediately stops new reports, and `tcflush(TCIFLUSH)` drops
    ## whatever arrived between the last read and now. illwill's own disable
    ## in `illwillDeinit` is idempotent, so an early disable costs nothing.
    stdout.write("\x1b[?1002l\x1b[?1003l\x1b[?1006l")
    stdout.flushFile()
    discard tcflush(STDIN_FILENO, TCIFLUSH)

  proc flushQueuedMouseReports*() =
    ## Last-chance discard of anything the terminal emulator delivered late.
    ##
    ## `stopMouseTracking` disables reporting and flushes the queue at the top
    ## of teardown, but the terminal needs a moment to act on `?1002l`, and a
    ## click that straddles the disable is delivered *after* the flush - which
    ## is how the reports survive to be echoed on the shell line. Echo is
    ## still off at this point (it comes back in `illwillDeinit`), so the
    ## stragglers queue silently: wait out the emulator's latency, then drop
    ## everything queued, and only then let `illwillDeinit` restore echo. Must
    ## be the last tty operation before `illwillDeinit`, on every exit path.
    ##
    ## `posix.usleep` counts *microseconds*. The POSIX `sleep` next door counts
    ## seconds, and the original `posix.sleep(50)` therefore held the whole
    ## shutdown for 50 of them - Ctrl-D put the screen back and then left the
    ## user staring at a console with no prompt for the better part of a
    ## minute, which is exactly the window in which they reached for Ctrl-C.
    discard posix.usleep(50 * 1000)
    discard tcflush(STDIN_FILENO, TCIFLUSH)

  proc stdinReady(timeoutMs: int): bool =
    ## True when stdin has at least one byte waiting.
    var
      fds: TFDSet
      tv = Timeval(tv_sec: Time(timeoutMs div 1000),
                   tv_usec: Suseconds((timeoutMs mod 1000) * 1000))
    FD_ZERO(fds)
    FD_SET(STDIN_FILENO, fds)
    select(STDIN_FILENO + 1, addr fds, nil, nil, addr tv) > 0

  proc drainStdin(): string =
    ## Read everything currently available on stdin.
    ##
    ## illwill leaves the tty with `VMIN=0`, so `read` returns 0 as soon as the
    ## buffer is empty rather than blocking.
    var chunk: array[4096, char]
    var total = 0
    while total < chunk.len:
      let n = read(STDIN_FILENO, addr chunk[total], chunk.len - total)
      if n <= 0:
        break
      total += n
    if total > 0:
      result = newString(total)
      for i in 0 ..< total:
        result[i] = chunk[i]

  proc poll*(r: InputReader, timeoutMs = 0): seq[InputEvent] =
    ## Wait up to `timeoutMs` for input and return any decoded events.
    ##
    ## Ctrl-C is checked before stdin: the signal leaves no byte behind, so the
    ## keyboard is empty at the moment the user is least expecting it to be.
    if takeCtrlCEvent():
      return @[keyEvent(Key.CtrlC)]
    if not stdinReady(timeoutMs):
      return
    let data = drainStdin()
    if data.len == 0:
      return
    r.parse(data, flushEsc = not stdinReady(0))
else:
  proc stopMouseTracking*() =
    ## Windows: illwill never enables SGR mouse encoding, so nothing to stop.
    discard

  proc flushQueuedMouseReports*() =
    ## Windows: illwill never enables SGR mouse encoding, so nothing queued.
    discard

  proc poll*(r: InputReader, timeoutMs = 0): seq[InputEvent] =
    ## Non-POSIX fallback: translate illwill's byte-oriented `getKey`.
    ##
    ## Still one byte per event, so Unicode input and modifiers remain
    ## unavailable here - see the module docs. The Ctrl-C latch works the same
    ## way it does on POSIX.
    if takeCtrlCEvent():
      return @[keyEvent(Key.CtrlC)]
    discard r
    discard timeoutMs
    let k = getKey()
    if k == Key.None:
      return
    let o = ord(k)
    if o >= 32 and o <= 126:
      return @[runeEvent(Rune(o))]
    result = @[keyEvent(k)]