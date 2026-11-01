## Conversation persistence.
##
## The transcript is written as a small JSON document under the user's config
## directory so a session survives a restart. Saving is best-effort: a read-only
## or unwritable config directory must never take the UI down with it.
##
## The document also records which 3code session the transcript continues. The
## two stores are independent - 3code writes its own `.3log` per turn - so
## without that link a restart would paint the restored scrollback over an agent
## that has never heard of it.

import std/[json, os, strutils]
import ./types

const
  sessionFileName = "session.json"

var sessionDirOverride = ""

proc setSessionDir*(dir: string) =
  ## Force the session to live in `dir`, overriding the environment.
  ##
  ## Precedence: this override, then `THREECX_SESSION_DIR`, then
  ## `$XDG_CONFIG_HOME/3cx`, then `~/.config/3cx`. Used by the tests.
  sessionDirOverride = dir

proc sessionDir*(): string =
  ## Directory that holds the session document.
  ##
  ## Deliberately *not* `os.getAppDir`: on POSIX that returns the directory of
  ## the running binary, which would drop a `session.json` next to the
  ## executable (or into whatever directory it happens to live in) instead of in
  ## the user's config directory.
  if sessionDirOverride.len > 0:
    return sessionDirOverride
  let
    override = getEnv("THREECX_SESSION_DIR")
    base = if override.len > 0:
             override
           else:
             let xdg = getEnv("XDG_CONFIG_HOME")
             if xdg.len > 0: xdg else: getEnv("HOME", "") / ".config"
  result = base / "3cx"

proc sessionPath*(): string =
  ## Full path of the session document.
  sessionDir() / sessionFileName

proc roleName(r: Role): string =
  case r
  of rUser: "user"
  of rAssistant: "assistant"
  of rTool: "tool"
  of rSystem: "system"

proc roleFromName(s: string): Role =
  case s
  of "user": rUser
  of "assistant": rAssistant
  of "tool": rTool
  else: rSystem

proc saveSession*(chat: Chat): bool =
  ## Write `chat` to disk. Returns false if the write failed.
  var messages = newJArray()
  for m in chat.messages:
    var o = newJObject()
    o["role"] = newJString(roleName(m.role))
    o["content"] = newJString(m.content)
    # Omitted when empty, which is every non-assistant message and any assistant
    # message restored from a pre-stamp session file. `loadSession` reads the
    # absence as "use the backend's current name".
    if m.model.len > 0:
      o["model"] = newJString(m.model)
    messages.add o
  var node = newJObject()
  # Omitted when there is none rather than written as "", so a document from
  # before the link existed and one that never had a backend stay identical.
  if chat.backendPath.len > 0:
    node["backend"] = newJString(chat.backendPath)
  node["messages"] = messages
  try:
    let dir = sessionPath().parentDir
    if not dirExists(dir):
      createDir(dir)
    writeFile(sessionPath(), pretty(node, indent = 2) & "\n")
    result = true
  except CatchableError:
    result = false

proc loadSession*(): Chat =
  ## Read a previously saved transcript.
  ##
  ## A missing or corrupt file simply yields an empty chat - starting fresh is
  ## much friendlier than refusing to launch.
  let path = sessionPath()
  if not fileExists(path):
    return
  try:
    var assistantTexts: seq[string]
    let node = parseFile(path)
    # A bare array is the pre-link format: messages only, no agent session
    # recorded. It still loads, and the next save upgrades it in place.
    let items = if node.kind == JObject: node{"messages"} else: node
    result.backendPath = node{"backend"}.getStr("")
    for item in items:
      if item.kind == JObject:
        let role = roleFromName(item{"role"}.getStr("system"))
        let content = item{"content"}.getStr("")
        # Drop committed transcript echoes (`● ...`) that 3code's headless hook
        # also streams as the assistant's reply: those were already rendered,
        # and storing them makes every later load resurrect the duplicate.
        # A leading bullet alone is not enough to drop - genuine tool results
        # such as "● ran a tool" can carry one too - so only treat the line
        # as an echo when it overlaps text we already have from an assistant.
        if role == rTool and content.strip().startsWith("●"):
          var skip = false
          # Strip leading decoration to reach the prose underneath.
          var plain = content
          var i = 0
          while i < plain.len and plain[i] notin {'a'..'z','A'..'Z','0'..'9'}:
            inc i
          if i < plain.len:
            plain = plain[i .. ^1]
          for a in assistantTexts:
            if a.len < 12 or plain.len < 12:
              continue
            let n = min(min(a.len, plain.len), 24)
            if n >= 12 and a[^n .. ^1] == plain[^n .. ^1]:
              skip = true
              break
            if (a in plain) or (plain in a):
              skip = true
              break
          if skip:
            continue
        if role == rAssistant and content.len >= 12:
          assistantTexts.add content
        # Absent in files written before the stamp existed - `getStr` defaults
        # it to "", which the renderer reads as "whatever the backend is now".
        let model = item{"model"}.getStr("")
        result.addMessage(role, content, model)
  except CatchableError:
    result = Chat()
