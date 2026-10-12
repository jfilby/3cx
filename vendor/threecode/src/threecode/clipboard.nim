## System clipboard access for the editor's cut/copy/paste commands.
##
## Writing goes through OSC 52 (`ESC ] 52 ; c ; <base64> ST`): the
## terminal itself forwards the payload to the OS clipboard, so no
## external tool is needed. Support is broad on modern terminals
## (xterm needs `allowWindowOps`, ghostty/kitty/WezTerm/iTerm2/
## Windows Terminal enable it by default or via one setting) and
## silently absent elsewhere, which is why every write is best-effort.
##
## Reading has no portable escape sequence, so `clipboardRead` shells
## out to the platform helper (pbpaste / wl-paste / xclip / xsel /
## PowerShell Get-Clipboard). When no helper exists it returns "" and
## the editor falls back to its own kill ring.

import std/[base64, os, osproc, strutils]

when defined(windows):
  import std/winlean

proc runeBoundaryAtOrBefore(s: string; n: int): int =
  result = min(n, s.len)
  while result > 0 and result < s.len and
      (byte(s[result]) and 0xC0'u8) == 0x80'u8:
    dec result

proc osc52Wrap*(s: string): string =
  ## The full OSC 52 sequence carrying `s` to the clipboard.
  "\x1b]52;c;" & base64.encode(s, safe = true) & "\x1b\\"

proc clipboardWriteOsc52*(s: string): string =
  ## OSC 52 bytes for `s`, chunked to stay under terminal size limits.
  ## kitty caps the whole sequence at 100KB and other terminals have
  ## similar ceilings, so large payloads are truncated rather than
  ## dropped wholesale: the first 96KB of the selection still lands.
  const MaxPayload = 96 * 1024
  var t = s
  if t.len > MaxPayload:
    t = t[0 ..< runeBoundaryAtOrBefore(t, MaxPayload)]
  osc52Wrap(t)

proc clipboardRead*(): string =
  ## Best-effort read of the system clipboard. Returns "" when no
  ## platform helper is available or the helper fails; callers fall
  ## back to their own state (the editor's kill ring).
  try:
    when defined(macosx):
      execCmdEx("pbpaste").output
    elif defined(windows):
      let r = execCmdEx("powershell -NoProfile -Command Get-Clipboard")
      r.output.replace("\r\n", "\n")
    elif defined(posix):
      if fileExists("/usr/bin/wl-paste") or findExe("wl-paste").len > 0:
        execCmdEx("wl-paste").output
      elif findExe("xclip").len > 0:
        execCmdEx("xclip -selection clipboard -o").output
      elif findExe("xsel").len > 0:
        execCmdEx("xsel --clipboard --output").output
      else:
        ""
    else:
      ""
  except CatchableError:
    ""
