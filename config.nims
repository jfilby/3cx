# Project-wide compiler settings.
#
# These live here rather than in threecodex.nimble because `switch()` in a
# nimble file does not reach a `task` that shells out to `nim c` itself, and a
# config.nims applies to every invocation in this directory - `nimble build`,
# `nimble test`, a task, and a bare `nim c`.
#
# The vendored 3code settings mirror its own config.nims, which Nim does not
# read for a vendored copy:
#
#   * `ssl`   - streamhttp's TLS path fails to compile without it
#               (`undeclared identifier: cachedTlsContext`).
#   * path    - the single root 3code itself builds with, so its modules resolve
#               each other by the same names (`import types`,
#               `import threecode/unicodewidth`). A second root would compile
#               some modules twice under different mangled names and fail to
#               link.
#
# The directory is spelled `threecode` because Nim rejects any path segment
# that is not a valid identifier, and "3code" is not one.

switch("path", "vendor/threecode/src")
switch("d", "ssl")

# 3code's own config.nims bakes its version in from threecode.nimble:
#   switch("d", "version=" & getVersionString())
# It reads `threecode.nimble`, which is not vendored, and it also shells out to
# `git describe` for the tag/branch suffix. Without a value, `{.strdefine.}`
# falls back to "devel", which leaks into user-visible output: `/version` prints
# "3code vdevel" and the banner shows the same. Keep it in step with
# threeCodeVersion in src/threecodex/version.nim and the pinned commit in
# vendor/threecode/VENDOR.md.
switch("d", "version=0.8.3")