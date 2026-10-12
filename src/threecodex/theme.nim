## Named colour themes for the 3cx UI.
##
## Every colour the renderer draws comes from a `Theme`, so retheming is a
## palette swap rather than a hunt through the drawing code. The palette is
## reached through the `col*` templates at the bottom of this module: they used
## to be `const`s, and they are still spelled the same way at every call site,
## but they now read `currentTheme` at the moment they are used. The transcript
## is rebuilt on every frame, so `/themes` takes effect on the next one without
## anything having to be re-parsed or invalidated.
##
## Two decisions worth knowing about before adding a theme:
##
## - A theme paints its own canvas (`bg`) instead of leaving the terminal's
##   background alone. A "light" theme over an unknown background is unreadable
##   one way or the other, so the theme commits. The cost is that the
##   background is no longer yours: a light 3cx is white even in a dark shell.
##   That is also why a span with no background of its own resolves to the
##   canvas in `applySpan` rather than to `bgNone`, which would punch the
##   terminal's default colour through every line of text.
## - illwill 0.4.1 offers only the eight ANSI colours, so there is no 256-colour
##   or RGB palette to tune - and real terminals do not agree on what those
##   eight mean. GNOME Terminal's "white" background (ANSI 47) is #d0cfcc and
##   its "black" (ANSI 40) #171421, so every field is chosen to hold >= 3:1
##   against the worst canvas it can land on: the light theme draws only in
##   black, blue, magenta and red (green, yellow and cyan wash out on a light
##   grey canvas), and the dark one keeps off blue, whose dark-palette shade
##   is nearly invisible on a near-black canvas.
##
## Adding a theme is a `Theme(...)` literal and a line in `themes`; nothing
## else in the codebase needs to know about it.

import std/strutils
import illwill

type
  Theme* = object
    name*: string        ## What `/themes <name>` calls it.
    description*: string ## One line, shown by a bare `/themes`.
    bg*: BackgroundColor   ## Canvas: painted behind the whole window.
    text*: ForegroundColor ## Body text.
    dim*: ForegroundColor  ## Secondary chrome text, drawn with `styleDim`.
    barDim*: bool          ## Draw the status bar hints with `styleDim`.
    heading1*: ForegroundColor ## `# heading`
    heading2*: ForegroundColor ## `## heading`
    heading3*: ForegroundColor ## `### heading` and deeper
    accent*: ForegroundColor   ## Bullets and other small markers
    code*: ForegroundColor     ## Inline and fenced code
    codeBar*: ForegroundColor  ## The `|` gutter drawn beside fenced code
    quote*: ForegroundColor    ## Block quote body
    rule*: ForegroundColor     ## Horizontal rules
    user*: ForegroundColor     ## User message role label
    assistant*: ForegroundColor ## Assistant message role label
    error*: ForegroundColor    ## Errors
    ok*: ForegroundColor       ## Success states, e.g. the clipboard flash
    prompt*: ForegroundColor   ## The `❯` prompt marker in the input box
    tool*: ForegroundColor     ## Tool call / result lines
    cursor*: ForegroundColor   ## Block cursor glyph
    cursorBg*: BackgroundColor ## Block cursor background
    select*: ForegroundColor   ## Selected transcript text
    selectBg*: BackgroundColor ## Selection background
    barBg*: BackgroundColor    ## Header and status bar
    barFg*: ForegroundColor    ## ... and their text

const
  lightTheme* = Theme(
    name: "light",
    description: "black text on a white canvas",
    bg: bgWhite,
    text: fgBlack,
    # Chrome text only ever lands on `barBg`, which is a bar and not the
    # canvas - white would vanish on the white canvas.
    dim: fgWhite,
    # Dimmed white on the black bar still reads (dim blends it toward black,
    # ~5:1). On the dark theme's blue bar the same dim blends toward blue and
    # washes out, so dark turns `barDim` off instead.
    barDim: true,
    heading1: fgBlue,
    heading2: fgMagenta,
    heading3: fgRed,
    accent: fgMagenta,
    code: fgBlue,
    codeBar: fgBlue,
    quote: fgBlue,
    rule: fgBlue,
    user: fgMagenta,
    assistant: fgBlue,
    error: fgRed,
    ok: fgGreen,
    prompt: fgBlue,
    tool: fgMagenta,
    cursor: fgWhite,
    cursorBg: bgBlue,
    select: fgWhite,
    selectBg: bgBlue,
    barBg: bgBlack,
    barFg: fgWhite)

  darkTheme* = Theme(
    name: "dark",
    description: "light text on a black canvas",
    bg: bgBlack,
    text: fgWhite,
    dim: fgWhite,
    # SGR 2 dims white toward whatever is behind it: toward black on the light
    # theme's bar (fine), toward the blue here - a wash that reads as ~3:1.
    # The hints stay quiet through being short, not through dimming.
    barDim: false,
    heading1: fgCyan,
    heading2: fgGreen,
    heading3: fgMagenta,
    accent: fgMagenta,
    code: fgYellow,
    codeBar: fgCyan,
    quote: fgGreen,
    rule: fgCyan,
    user: fgGreen,
    assistant: fgCyan,
    error: fgRed,
    ok: fgGreen,
    prompt: fgCyan,
    tool: fgYellow,
    cursor: fgBlack,
    cursorBg: bgCyan,
    select: fgBlack,
    selectBg: bgWhite,
    barBg: bgBlue,
    barFg: fgWhite)

  themes* = [lightTheme, darkTheme] ## Every theme `/themes` can pick, in order.
  defaultTheme* = lightTheme         ## Used when nothing has chosen a theme.

var currentTheme* = defaultTheme
  ## The theme in effect. Replaced by `/themes`; read through the `col*`
  ## templates below rather than directly.

template colBg*: untyped = currentTheme.bg ## Canvas behind the window.
template colText*: untyped = currentTheme.text ## Body text.
template colDim*: untyped = currentTheme.dim ## Secondary chrome text.
template colHeading1*: untyped = currentTheme.heading1 ## `# heading`
template colHeading2*: untyped = currentTheme.heading2 ## `## heading`
template colHeading3*: untyped = currentTheme.heading3 ## `### heading` and deeper
template colAccent*: untyped = currentTheme.accent ## Bullets and other markers
template colCode*: untyped = currentTheme.code ## Inline and fenced code
template colCodeBar*: untyped = currentTheme.codeBar ## The gutter beside code
template colQuote*: untyped = currentTheme.quote ## Block quote body
template colRule*: untyped = currentTheme.rule ## Horizontal rules
template colUser*: untyped = currentTheme.user ## User message role label
template colAssistant*: untyped = currentTheme.assistant ## Assistant role label
template colError*: untyped = currentTheme.error ## Errors and the quit hint
template colOk*: untyped = currentTheme.ok ## Success states
template colPrompt*: untyped = currentTheme.prompt ## The `❯` prompt marker
template colTool*: untyped = currentTheme.tool ## Tool call / result lines
template colCursor*: untyped = currentTheme.cursor ## Block cursor glyph
template colCursorBg*: untyped = currentTheme.cursorBg ## Block cursor background
template colSelect*: untyped = currentTheme.select ## Selected transcript text
template colSelectBg*: untyped = currentTheme.selectBg ## Selection background
template colBarBg*: untyped = currentTheme.barBg ## Header and status bar
template colBarFg*: untyped = currentTheme.barFg ## Text on those bars

proc themeNames*(): seq[string] =
  ## The names `/themes` accepts, in the order they are listed.
  for t in themes:
    result.add t.name

proc isThemeName*(name: string): bool =
  ## True if `name` is one of `themes`, ignoring case and surrounding space.
  let n = name.strip.toLowerAscii
  for t in themes:
    if t.name == n:
      return true
  false

proc themeByName*(name: string): Theme =
  ## The theme called `name`, falling back to `defaultTheme`.
  let n = name.strip.toLowerAscii
  for t in themes:
    if t.name == n:
      return t
  defaultTheme

proc useTheme*(name: string): bool =
  ## Switch to the theme called `name`.
  ##
  ## Returns false and leaves the current theme in place when the name is not
  ## one of `themes`, so a typo cannot leave the UI on somebody else's colours.
  if not isThemeName(name):
    return false
  currentTheme = themeByName(name)
  true

proc applyTheme*(name: string) =
  ## Adopt the theme saved in the preferences, if there is a usable one.
  ##
  ## An absent or unrecognised name is not an error - it just means the default.
  discard useTheme(name)

proc themeHelp*(): string =
  ## Text for a bare `/themes`: every theme, and which one is live.
  result = "themes:"
  var width = 0
  for t in themes:
    width = max(width, t.name.len)
  for t in themes:
    let marker = if t.name == currentTheme.name: "*" else: " "
    # Padded by hand rather than with `align`, which pads on the left.
    result.add "\n  " & marker & " " & t.name &
               repeat(" ", width - t.name.len) & "  " & t.description
  result.add "\n\ncurrent: " & currentTheme.name
  result.add "\nuse /themes <name> to switch"

# ---------------------------------------------------------------------------
# Exact canvas colours
#
# The eight ANSI colours are names, not values: GNOME Terminal maps SGR 40
# (bgBlack) to #171421 and SGR 47 (bgWhite) to #d0cfcc, so a "black" canvas
# renders near-black at best and a "white" one light grey. illwill's display
# path cannot emit anything beyond SGR 30-37/40-47, so the fix is not in the
# per-cell colours but in what those SGR codes *mean*: on startup three
# palette slots are redefined with OSC 4 - colour 0 to pure black, colour 4
# (which backs the two bars' `bgBlue`) to #1c3f7a, colour 7 to pure white -
# and the terminal's own default fg/bg (OSC 10/11) to the theme's, so the
# canvas is genuinely black in the dark theme and genuinely white in the
# light one, and white bar text holds ~10:1 on the blue in dark mode however
# the terminal defines its blue (solarized's #268bd2, for instance, gives
# white text only 3.7:1).
#
# Only these three slots are redefined because only SGR 40, 44 and 47 are
# ever used as backgrounds (`bg`, `barBg`, `cursorBg`, `selectBg` are drawn
# from those), and the foreground text colours are left to the terminal's
# palette: they were tuned against it, and overwriting colour slots the
# terminal shares with every other program is exactly the kind of theft the
# restore below exists to undo. (Slot 4 doubles as `fgBlue` in the light
# theme's headings and code; #1c3f7a lifts that text on white from 5.8:1 to
# 10.3:1, so the pin helps there too.)
#
# `resetExactPalette` undoes the whole override with the reset forms (OSC 104
# for the palette slots, OSC 110/111 for the defaults), which return the
# terminal to *its* colours whatever they were - no need to have saved them.

const
  oscSetColor0 = "\x1b]4;0;rgb:0000/0000/0000\x07"
  oscSetColor4 = "\x1b]4;4;rgb:1c3f/1c3f/7a7a\x07"
  oscSetColor7 = "\x1b]4;7;rgb:ffff/ffff/ffff\x07"
  oscResetColor0 = "\x1b]104;0\x07"
  oscResetColor4 = "\x1b]104;4\x07"
  oscResetColor7 = "\x1b]104;7\x07"

proc applyExactPalette*(t: Theme) =
  ## Pin the two background slots to true black/white and move the terminal's
  ## default fg/bg onto the theme's canvas colours.
  ##
  ## Belt and braces around the SGR-only renderer: without it the dark theme's
  ## canvas is the terminal's "black" (a dark grey at best) and the light
  ## theme's a light grey. Written straight to stdout, which is where illwill
  ## writes frames; safe between frames because each OSC is atomic.
  let (fgRgb, bgRgb) =
    if t.bg == bgWhite: ("rgb:0000/0000/0000", "rgb:ffff/ffff/ffff")
    else:               ("rgb:ffff/ffff/ffff", "rgb:0000/0000/0000")
  stdout.write(oscSetColor0, oscSetColor4, oscSetColor7)
  stdout.write("\x1b]10;" & fgRgb & "\x07")
  stdout.write("\x1b]11;" & bgRgb & "\x07")
  stdout.flushFile()

proc resetExactPalette*() =
  ## Hand the terminal its own colours back. The reset forms (104/110/111)
  ## restore the terminal's defaults without us having had to read them.
  stdout.write(oscResetColor0, oscResetColor4, oscResetColor7,
               "\x1b]110\x07", "\x1b]111\x07")
  stdout.flushFile()