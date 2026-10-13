# Vendored: 3code

Upstream: https://github.com/capocasa/3code
Pinned commit: `e04cba80d26d7e6115ad1650e1e4ccdda4d2bdde` (2026-10-11, v0.8.3)
License: MIT — see `LICENSE`.

Only `src/`, `config.nims` and `nimble.lock` are copied; tests, docs and the
built binary are left out. 1.7 MB, 45 modules.

## Why vendored

`src/threecode/library.nim` is 3code's own headless frontend — it runs the same
agent loop, tools and sandbox as the CLI, but with the terminal replaced by
return values and callbacks. Embedding it is a compile-time dependency, not a
process boundary, so the source has to be on the include path.

## How to update

```sh
cd /tmp && git clone --depth 1 https://github.com/capocasa/3code.git
cd 3code && git checkout <new-rev>
rm -rf ../../../path/to/3cx/vendor/3code/src
cp -r src ../../../path/to/3cx/vendor/3code/
cp config.nims nimble.lock ../../../path/to/3cx/vendor/3code/
```

Then rebuild and check that `AgentEvent` in `src/threecode/library.nim` still
matches what `src/threecodex/threecode_backend.nim` switches on — the event
enum is the one part of this integration that has no compile-time safety net,
because a new or renamed case falls into the `else` branch rather than failing
to build.

Finally, update the three places that name the revision:

```nim
# src/threecodex/version.nim   -> reported by ./3cx -v
threeCodeVersion* = "0.8.2"
threeCodeCommit*  = "ffa46cf"

# config.nims                  -> what 3code itself reports via :version
switch("d", "version=0.8.2")
```

and the pinned-commit line above. `./3cx -v` is what a bug report should quote,
so it has to name the revision that is actually linked in. Note that the
`config.nims` define is easy to miss: without it nothing fails to compile, and
3code quietly reports itself as `vdevel`.

3code's own dependencies (`streamhttp`, `ttty`, `tinotify`, `sandwall`,
`libsha`, `zippy`, `ws`, `unicodedb`) are declared in `../threecodex.nimble`.