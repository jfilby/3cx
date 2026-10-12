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
  echo "  --mock              use the offline mock backend (no provider needed)"
  echo "  -m, --model NAME    provider[.model], overrides the 3code config"
  echo "  -C, --cwd DIR       working directory for tools and the sandbox"
  echo "  -r, --resume        resume the latest 3code session for this directory"
  echo "  -v, --version       print version information and exit"
  echo "  -h, --help          show this help"
  echo ""
  echo "With no options 3code's own config is used; it needs a provider"
  echo "configured (see `3code provider add`)."

proc parseArgs(): Options =
  result.model = getEnv("THREECX_MODEL")
  result.cwd = getEnv("THREECX_CWD")
  result.useMock = getEnv("THREECX_BACKEND") == "mock"
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
  if opts.useMock:
    backend = newMockBackend()
  else:
    # The 3code backend raises AgentError for the same conditions the CLI
    # reports (no provider, unresolvable model, locks held). Surface them as
    # plain text before the terminal goes full-screen, then fall back to the
    # mock so the session is still usable rather than dead on arrival.
    try:
      let b = newThreeCodeBackend(model = opts.model, cwd = opts.cwd,
                                  resume = opts.resume)
      backend = b
    except CatchableError as e:
      stderr.writeLine "3cx: cannot start 3code: " & e.msg
      stderr.writeLine "3cx: falling back to the mock backend (--mock to skip this)"
      backend = newMockBackend()

  if chat.messages.len == 0:
    var welcome = "Welcome to **3cx**. Type a message and press enter."
    if backend.name == "mock":
      welcome.add "\n\nThis build is wired to the mock backend, so replies are canned."
    welcome.add "\n\n`/help` lists the agent's commands; `/themes` switches between " &
      "light and dark."
    chat.addMessage(rSystem, welcome)

  run(chat, backend)

when isMainModule:
  main()