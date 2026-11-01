## 3cx - an easy-to-use terminal UI for 3code.
##
## Entry point. Wires a backend to the UI and hands over control; everything
## interesting lives in the modules under `threecodex/`.

import std/os
import ./threecodex/[types, backend, app, session, config, theme, version,
                     threecode_backend]

type
  Options = object
    useMock: bool
    model: string
    cwd: string
    resume: bool

proc usage() =
  echo "3cx - a terminal UI for 3code"
  echo ""
  echo "usage: 3cx [options]"
  echo ""
  echo "  --mock              use the offline mock backend (UI development only)"
  echo "  -m, --model NAME    provider[.model], overrides the 3code config"
  echo "  -C, --cwd DIR       working directory for tools and the sandbox"
  echo "  -r, --resume        the newest 3code session for this directory, not the"
  echo "                      one the restored transcript came from"
  echo "  -v, --version       print version information and exit"
  echo "  -h, --help          show this help"
  echo ""
  echo "With no options 3code's own config is used; it needs a provider"
  echo "configured (see `3code provider add`)."

proc parseArgs(): Options =
  result.model = getEnv("THREECX_MODEL")
  result.cwd = getEnv("THREECX_CWD")
  result.resume = getEnv("THREECX_RESUME") == "1"

  var i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--mock":
      result.useMock = true
    of "-m", "--model":
      inc i
      if i > paramCount():
        quit("--model needs a value", QuitFailure)
      result.model = paramStr(i)
    of "-C", "--cwd":
      inc i
      if i > paramCount():
        quit("--cwd needs a value", QuitFailure)
      result.cwd = paramStr(i)
    of "-r", "--resume":
      result.resume = true
    of "-v", "--version":
      echo versionInfo()
      quit(0)
    of "-h", "--help":
      usage()
      quit(0)
    else:
      quit("unknown option: " & arg & "\n\nrun with --help", QuitFailure)
    inc i

proc main() =
  let opts = parseArgs()
  var chat = loadSession()

  # Before anything is painted: an unknown or missing name leaves the default
  # theme in place rather than failing the launch.
  applyTheme(loadConfig().theme)

  var backend: Backend
  var attached = false  ## Whether the agent has the transcript's history.
  if opts.useMock:
    backend = newMockBackend()
  else:
    # Which saved session to attach to, decided before anything is opened: the
    # transcript's own unless `--resume` asks for the newest for this directory.
    let choice = resumeChoice(chat.backendPath, opts.resume)
    attached = choice.latest or choice.id.len > 0
    # No silent fallback: a mock reply presented as the agent is worse than a
    # clear failure. A backend that cannot start ends the launch here, before
    # the terminal is taken over - so there is nothing to restore.
    try:
      let b = newThreeCodeBackend(model = opts.model, cwd = opts.cwd,
                                  resume = choice.latest, resumeId = choice.id)
      backend = b
      # Saved with the transcript, so the next launch attaches to this same
      # conversation instead of painting the scrollback over an empty agent.
      chat.backendPath = b.agentSessionPath()
    except CatchableError as e:
      stderr.writeLine "3cx: cannot start 3code: " & e.msg
      stderr.writeLine "3cx: configure a provider with `3code provider add`, " &
                       "or pass --mock to use the offline UI."
      quit(QuitFailure)

  if chat.messages.len == 0:
    var welcome = "Welcome to **3cx**. Type a message and press enter."
    if backend.name == "mock":
      welcome.add "\n\nThis session is using the mock backend, so replies are canned."
    welcome.add "\n\n`/help` lists the agent's commands; `/themes` switches between " &
      "light and dark."
    chat.addMessage(rSystem, welcome)
  elif not attached and not opts.useMock:
    # The scrollback came back but the agent has no memory of it: the session
    # file it was written against is gone. Say so, rather than letting the
    # transcript imply a context the model cannot see.
    chat.addMessage(rSystem, "**This conversation is new to the agent.** The " &
      "3code session behind the transcript above is gone, so it starts empty; " &
      "the text stays as a record of the old conversation.")

  run(chat, backend)

when isMainModule:
  main()