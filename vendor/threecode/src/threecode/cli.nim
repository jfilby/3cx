## Non-interactive `3code provider` subcommand: the config half of the
## REPL's `:provider` wizard on the command line, for scripts and first
## setup without a TTY. Scope is provider management only — adding a
## provider, replacing its model list, removing it, listing what is
## configured. Switching the current model stays in the REPL (`:model`)
## and on `-m`; a CLI setter would grow a second sticky-current
## semantics for no benefit.
##
## Output is plain stdout (listings, confirmations) and stderr (errors),
## no ANSI styling: this runs in scripts and pipes. Exit codes follow
## the CLI convention (die: 1/2/3).
##
## `add` mirrors the wizard's resolution of the first field (catalog
## name, url, api key, subscription login) but takes the key and models
## from flags instead of prompts. Like the wizard's registry-trusted
## path, no verification ping runs: a bad key surfaces on the first
## turn. Subscription logins (chatgpt, claudecode, geminicli,
## supergrok) open the browser OAuth flow, which is the one
## interactive step; everything else is pipeable.

import std/[os, strformat, strutils, tables]
import types, util, config, prompts, display, ui, auth_xai,
  auth_anthropic, auth_openai, auth_google

proc providerUsage(): string =
  result.add "usage: 3code provider list\n"
  result.add "       3code provider add <name|url|api-key> [--key KEY] [--models \"a b c\"]\n"
  result.add "       3code provider models <name> <model...>\n"
  result.add "       3code provider rm <name>"

proc cliErr(msg: string) =
  stderr.writeLine "3code: " & msg

proc nameTaken(name: string): bool =
  for pr in activeProviders:
    if pr.name == name: return true
  false

proc resolveEntry(entry, keyFlag: string): ProviderRec =
  ## Name/url/key resolution from the wizard's first field, minus the
  ## prompts. `entry` is a catalog name, an http(s) url, an api key, or
  ## a subscription login name. The key comes from `--key` (or the
  ## entry itself when it is one). Raises ValueError with a
  ## user-facing message on anything it cannot resolve.
  let entryLower = entry.toLowerAscii
  if entryLower in ["supergrok", "chatgpt", "geminicli", "claudecode"]:
    if nameTaken(entryLower):
      raise newException(ValueError, "already configured: " & entryLower)
    let auth =
      if entryLower == "supergrok": xaiOauthLogin()
      elif entryLower == "chatgpt": chatgptOauthLogin()
      elif entryLower == "geminicli": geminiOauthLogin()
      else: claudeOauthLogin()
    let url =
      if entryLower == "geminicli": auth_google.CloudCodeApiUrl
      elif entryLower == "claudecode": auth_anthropic.ClaudeApiUrl
      else: catalogUrl(canonicalKnownGoodProvider(entryLower))
    return ProviderRec(name: entryLower, url: url, auth: auth)
  if entry.startsWith("http://") or entry.startsWith("https://"):
    if not experimentalEnabled:
      raise newException(ValueError, "custom urls need --experimental")
    if keyFlag == "":
      raise newException(ValueError, "--key required with a url entry")
    let url = entry.strip(chars = {'/', ' '})
    var name = defaultNameFromUrl(url)
    if name == "": name = keyFlag
    if name == "":
      raise newException(ValueError, "cannot infer a name from " & url &
        "; use a catalog name entry instead")
    if nameTaken(name):
      raise newException(ValueError, "already configured: " & name)
    return ProviderRec(name: name, url: url, key: keyFlag)
  let inferred = inferProvider(entry)
  if inferred != "":
    if not experimentalEnabled and curatedFor(inferred).len == 0:
      raise newException(ValueError, "key prefix not recognized: " & entry)
    if nameTaken(inferred):
      raise newException(ValueError, "already configured: " & inferred)
    return ProviderRec(name: inferred, url: catalogUrl(inferred), key: entry)
  # Catalog provider name; the key rides in --key (or the entry is a
  # bare unrecognized token, which the wizard would also refuse).
  let name = entryLower
  if not experimentalEnabled and curatedFor(name).len == 0:
    raise newException(ValueError, "unknown provider: " & name)
  if nameTaken(name):
    raise newException(ValueError, "already configured: " & name)
  var url = catalogUrl(name)
  if url == "": url = catalogUrl(canonicalKnownGoodProvider(name))
  if url == "":
    raise newException(ValueError, "no catalog url for " & name)
  if keyFlag == "":
    raise newException(ValueError, "api key required (--key)")
  ProviderRec(name: name, url: url, key: keyFlag)

proc resolveModels(prov: ProviderRec, modelsFlag: string): seq[string] =
  ## The provider's model list: `--models` when given, else the curated
  ## known-good set. Entered names resolve through the curated list
  ## (short or full spelling); unknown names are an error unless
  ## --experimental, where they pass through verbatim.
  let curated = curatedFor(prov.name)
  if modelsFlag == "":
    if curated.len == 0:
      raise newException(ValueError, "no known-good models for " &
        prov.name & "; pass --models")
    return curated
  let lookup = shortToFull(curated)
  for rm in splitModels(modelsFlag):
    if experimentalEnabled:
      result.add lookup.getOrDefault(rm, rm)
    elif lookup.getOrDefault(rm, rm) in curated:
      result.add lookup.getOrDefault(rm, rm)
    else:
      raise newException(ValueError, "unknown known-good model: " & rm)
  if result.len == 0:
    raise newException(ValueError, "need at least one model")

proc providerList() =
  if activeProviders.len == 0:
    echo "no providers configured"
    return
  let dot = activeCurrent.find('.')
  let curName = if dot < 0: activeCurrent else: activeCurrent[0 ..< dot]
  for pr in activeProviders:
    let mark = if pr.name == curName: "*" else: " "
    let plural = if pr.models.len == 1: "" else: "s"
    echo &"{mark} {pr.name}  {pr.models.len} model{plural}"

proc providerAdd(entry, keyFlag, modelsFlag: string) =
  if entry == "":
    cliErr "provider add: missing <name|url|api-key>"
    stderr.writeLine providerUsage()
    quit ExitUsage
  var prov: ProviderRec
  try:
    prov = resolveEntry(entry, keyFlag)
    prov.models = resolveModels(prov, modelsFlag)
  except ValueError as e:
    cliErr e.msg
    quit ExitConfig
  activeProviders.add prov
  if activeCurrent == "":
    activeCurrent = prov.name & "." & firstModel(prov)
    setCurrentModel(prov.name, firstModel(prov))
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  echo &"added {prov.name} ({prov.models.len} models) -> {configPath()}"

proc providerModels(name: string, models: seq[string]) =
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == name: idx = i; break
  if idx < 0:
    cliErr &"unknown provider: {name}"
    quit ExitConfig
  var prov = activeProviders[idx]
  try:
    prov.models = resolveModels(prov, models.join(" "))
  except ValueError as e:
    cliErr e.msg
    quit ExitConfig
  activeProviders[idx] = prov
  # The current model may no longer be in the list; fall back to the
  # first entry like the wizard's edit path does.
  let dot = activeCurrent.find('.')
  let curName = if dot < 0: "" else: activeCurrent[0 ..< dot]
  if curName == name:
    let model = rememberedModel(prov)
    activeCurrent = prov.name & "." & model
    setCurrentModel(prov.name, model)
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  echo &"{name}: {prov.models.len} models"

proc providerRm(name: string) =
  var idx = -1
  for i, pr in activeProviders:
    if pr.name == name: idx = i; break
  if idx < 0:
    cliErr &"unknown provider: {name}"
    quit ExitConfig
  activeProviders.delete(idx)
  let dot = activeCurrent.find('.')
  let curName = if dot < 0: "" else: activeCurrent[0 ..< dot]
  if curName == name:
    if activeProviders.len > 0:
      let np = activeProviders[0]
      let model = rememberedModel(np)
      activeCurrent = np.name & "." & model
      setCurrentModel(np.name, model)
    else:
      activeCurrent = ""
  writeConfigFile(configPath(), activeCurrent, activeProviders)
  echo &"removed {name}"

proc providerMain*(args: seq[string]): int =
  ## `3code provider ...` dispatch. Returns the exit code; callers
  ## `quit` with it. Config must already be loaded into
  ## `activeCurrent` / `activeProviders` (the CLI entry point does
  ## that before dispatching here).
  if args.len == 0 or args[0] in ["list", "ls"]:
    providerList()
    return 0
  case args[0]
  of "add":
    var entry = ""
    var keyFlag = ""
    var modelsFlag = ""
    var i = 1
    while i < args.len:
      case args[i]
      of "--key":
        if i + 1 >= args.len:
          cliErr "--key requires a value"
          return ExitUsage
        keyFlag = args[i + 1]; inc i
      of "--models":
        if i + 1 >= args.len:
          cliErr "--models requires a value"
          return ExitUsage
        modelsFlag = args[i + 1]; inc i
      else:
        if entry != "":
          cliErr "provider add: one entry only"
          return ExitUsage
        entry = args[i]
      inc i
    providerAdd(entry, keyFlag, modelsFlag)
  of "models":
    if args.len < 3:
      cliErr "provider models: need <name> and at least one model"
      stderr.writeLine providerUsage()
      return ExitUsage
    providerModels(args[1], args[2 .. ^1])
  of "rm", "remove":
    if args.len != 2:
      cliErr "provider rm: need exactly one name"
      stderr.writeLine providerUsage()
      return ExitUsage
    providerRm(args[1])
  else:
    cliErr "unknown subcommand: " & args[0]
    stderr.writeLine providerUsage()
    return ExitUsage
  0
