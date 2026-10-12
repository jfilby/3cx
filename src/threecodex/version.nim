## Build identity.
##
## `threeCodeVersion` and `threeCodeCommit` describe the vendored 3code this
## binary was compiled against - the agent that actually runs, so it is the
## number that matters when reporting a bug. Both come from `vendor/threecode`
## (see `vendor/threecode/VENDOR.md`) and must be updated together with it.
##
## illwill's version is resolved at compile time from its installed directory
## name (`illwill-<version>-<commit>`). Neither `{.strdefine.}` nor
## `NimblePkgVersion` turned out to be usable here - the first is rejected by
## this compiler and the second is unset depending on how the build is invoked -
## so the directory is located with `staticExec` instead. That also keeps the
## banner honest rather than silently reading "unknown".

import std/[os, strutils]

const
  appName* = "3cx"
  appVersion* = "0.1.0"

  threeCodeVersion* = "0.8.2"
  threeCodeCommit* = "ffa46cf"

const illwillVer* =
  block:
    when defined(posix):
      # Located by plain string splitting rather than `splitFile`: Nim's
      # compile-time evaluation of `splitFile` on a path this long returns a
      # truncated name, which silently yielded "illwill-0.4".
      let
        home = getEnv("HOME", "")
        listing = staticExec("ls -d " & home & "/.nimble/pkgs2/illwill-* " &
                             home & "/.nimble/pkgs/illwill-* 2>/dev/null | head -1").strip
        segments = listing.split('/')
        base = segments[segments.len - 1]
      if base.startsWith("illwill-"):
        base["illwill-".len ..< ^1].split('-')[0]
      else:
        "unknown"
    else:
      "unknown"

proc versionInfo*(): string =
  ## Multi-line version report.
  result = appName & " " & appVersion &
    "\n3code " & threeCodeVersion & " (" & threeCodeCommit & ") [vendored]" &
    "\nillwill " & illwillVer &
    "\nnim " & NimVersion &
    "\nbuilt for " & hostOS & "/" & hostCPU