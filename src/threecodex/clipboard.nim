## Clipboard writes for the 3cx UI.
##
## The only direction needed is text *out*: a mouse selection is copied when
## the button is released. That goes out as OSC 52 -
## `ESC ] 52 ; c ; <base64> ST` - where the terminal itself forwards the payload
## to the OS clipboard, so nothing external is required and the copy works even
## on a machine that has no clipboard at all (over ssh, in a container).
##
## Support is broad - kitty, ghostty, WezTerm, iTerm2, Windows Terminal and
## tmux with `set-clipboard` all honour it - but xterm ships with
## `allowWindowOps` off, and Terminal.app on macOS ignores it entirely, both
## dropping the sequence without a word. So a write is also fanned out to a
## platform helper on POSIX when one is installed. Everything here is best
## effort: putting text on the clipboard must never take the UI down, and there
## is no way to ask a terminal whether it understood.

import std/[base64, os, strutils]

const
  maxPayload = 96 * 1024
    ## kitty caps a whole OSC 52 sequence at 100KB; truncate below that rather
    ## than have a long selection rejected outright.

proc runeBoundaryAtOrBefore(s: string, n: int): int =
  ## Largest offset <= `n` that is not the middle of a UTF-8 sequence, so a
  ## truncated payload can never end with a half-encoded character.
  result = min(n, s.len)
  while result > 0 and result < s.len and
      (ord(s[result]) and 0xC0) == 0x80:
    dec result

proc osc52Sequence*(text: string): string =
  ## The full OSC 52 sequence carrying `text` to the clipboard.
  ##
  ## Standard base64, as the specification describes; the payload is closed by
  ## the string terminator `ESC \` rather than BEL, so a clipboard payload
  ## containing the BEL byte cannot end the sequence early.
  var t = if text.len > maxPayload:
            text[0 ..< runeBoundaryAtOrBefore(text, maxPayload)]
          else:
            text
  result = "\x1b]52;c;" & base64.encode(t) & "\x1b\\"

proc writeOsc52(text: string): bool =
  ## Emit the sequence straight to the terminal, outside illwill's buffer.
  ##
  ## illwill owns the screen through its own frame buffer, so this writes to
  ## the real stdout as a separate, cursor-neutral sequence: the terminal
  ## consumes it without repainting anything, and one that does not understand
  ## OSC 52 ignores it.
  try:
    stdout.write osc52Sequence(text)
    stdout.flushFile()
    true
  except IOError:
    false

# ---------------------------------------------------------------------------
# Platform helper (POSIX)
# ---------------------------------------------------------------------------
#
# `popen` rather than `osproc`: feeding a payload to a child's stdin and then
# closing that pipe is the only way to tell `pbcopy` the payload is complete,
# and `pclose` does exactly that. osproc's Process has no way to close the
# input stream of a running process, and closing the raw handle underneath it
# double-closes when the Process itself is closed.

when defined(posix):
  proc cPopen(cmd: cstring, mode: cstring): File
    {.importc: "popen", header: "<stdio.h>", nodecl.}

  proc cPclose(p: File): cint
    {.importc: "pclose", header: "<stdio.h>", nodecl.}

  proc shellQuote(s: string): string =
    ## Single-quote `s` for a shell, so a space in an installed path is not
    ## read as a word break.
    result = "'" & s.replace("'", "'\\''") & "'"

  proc pipeTo(exe: string, args: seq[string], text: string): bool =
    ## Pipe `text` into the helper `exe`, with `args`.
    ##
    ## The command is quoted because popen runs a shell, and built from the
    ## path `findExe` returned so it is a real file rather than something the
    ## shell has to go looking for.
    if not fileExists(exe):
      return false
    var cmd = shellQuote(exe)
    for a in args:
      cmd.add ' '
      cmd.add shellQuote(a)

    var p: File
    try:
      p = cPopen(cmd.cstring, "w")
    except OSError:
      return false
    if p.isNil:
      return false
    try:
      p.write text
    except IOError:
      discard
    # `pclose` flushes and closes the pipe, which is what signals EOF to a
    # helper reading stdin; without it, `pbcopy` waits forever.
    try:
      discard cPclose(p)
    except OSError:
      return false
    true

proc helperCopy(text: string): bool =
  ## Try a platform clipboard helper. POSIX only: on Windows the terminals that
  ## matter honour OSC 52 natively, and the one helper there is best avoided
  ## anyway - `clip.exe` rewrites newlines into CRLF on the way through.
  ##
  ## Candidates are probed before use, and the X11 ones only when a display is
  ## configured: a `DISPLAY` pointing at nothing is the case that would
  ## otherwise stall on a socket that is not there. There is no timeout,
  ## because popen has none to give and that is the price of using it; the
  ## helpers sought here do their work and exit.
  when defined(posix):
    when defined(macosx):
      let pbcopy = findExe("pbcopy")
      if pbcopy.len > 0:
        return pipeTo(pbcopy, @[], text)
    if getEnv("WAYLAND_DISPLAY").len > 0:
      let wl = findExe("wl-copy")
      if wl.len > 0:
        return pipeTo(wl, @[], text)
    if getEnv("DISPLAY").len > 0:
      let xclip = findExe("xclip")
      if xclip.len > 0:
        return pipeTo(xclip, @["-selection", "clipboard"], text)
      let xsel = findExe("xsel")
      if xsel.len > 0:
        return pipeTo(xsel, @["--clipboard", "--input"], text)
    false
  else:
    false

proc clipboardCopy*(text: string) =
  ## Put `text` on the clipboard. Best effort, and never raises.
  ##
  ## Both paths are used: OSC 52 costs nothing and covers the terminals that
  ## support it, the helper covers the ones that ignore it. Neither reports
  ## success in a way that can be trusted - "the bytes were emitted" is not
  ## "the clipboard holds the text" - so the caller flashes its confirmation
  ## and moves on.
  discard writeOsc52(text)
  discard helperCopy(text)
