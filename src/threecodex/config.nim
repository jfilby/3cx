## Persistent UI preferences.
##
## One setting so far - the theme - in a `config.json` that sits next to the
## session document. Both directions are best-effort: a config directory that
## cannot be written costs you the choice between launches, and a corrupt file
## falls back to the default rather than stopping the UI from starting.
##
## The directory comes from `session.nim` rather than being resolved again here:
## both documents live in the same `$XDG_CONFIG_HOME/3cx`, so one implementation
## of the XDG rules covers both, and `THREECX_SESSION_DIR` moves them together -
## which is also how the tests get them into a temp directory.

import std/[json, os, strutils]
import ./session

const
  configFileName = "config.json"

type
  Config* = object
    theme*: string  ## Active theme name; empty means the default.

proc configPath*(): string =
  ## Full path of the preferences document.
  sessionDir() / configFileName

proc loadConfig*(): Config =
  ## Read the preferences, falling back to their defaults.
  ##
  ## `THREECX_THEME` wins over the file, like the other `THREECX_*` variables:
  ## an environment set for one run should not have to be undone to see a saved
  ## theme again.
  let fromEnv = getEnv("THREECX_THEME").strip
  if fromEnv.len > 0:
    result.theme = fromEnv
    return

  let path = configPath()
  if not fileExists(path):
    return
  try:
    let node = parseFile(path)
    if node.kind == JObject:
      result.theme = node["theme"].getStr("").strip
  except CatchableError:
    discard   # an unreadable file is the same as no file

proc saveConfig*(cfg: Config): bool =
  ## Write the preferences. Returns false if the write failed.
  var node = newJObject()
  if cfg.theme.len > 0:
    node["theme"] = newJString(cfg.theme)
  try:
    let dir = configPath().parentDir
    if not dirExists(dir):
      createDir(dir)
    writeFile(configPath(), pretty(node, indent = 2) & "\n")
    result = true
  except CatchableError:
    result = false