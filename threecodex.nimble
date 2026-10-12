
# Package

# nimble - and Nim itself - reject module names that begin with a digit, so the
# manifest, the package and the entry module are all spelled `threecodex`.
# `namedBin` maps the compiled artifact to its real name: `3cx`, which is what
# users type and what `nimble build` leaves in the working directory.

version       = "0.1.0"
author        = "3cx contributors"
description   = "An easy-to-use terminal UI front-end for 3code"
license       = "MIT"
srcDir        = "src"
bin           = @["threecodex"]
namedBin      = {"threecodex": "3cx"}.toTable

# 3code is vendored under vendor/threecode (see vendor/threecode/VENDOR.md) and
# is embedded as a compile-time dependency rather than driven over a process
# boundary: its own headless frontend (threecode/library) is the integration
# surface.
#
# The include path and -d:ssl live in ./config.nims rather than here, because
# `switch()` in a nimble file does not reach a `task` that shells out to
# `nim c` itself.

# Dependencies

requires "nim >= 2.0.0"
requires "illwill >= 0.4.1"

# 3code's own dependencies, mirrored from vendor/threecode/nimble.lock.
requires "streamhttp >= 0.5.0"
requires "ttty >= 0.5.0"
requires "unicodedb >= 0.13.0"
requires "tinotify >= 0.1.3"
requires "sandwall >= 0.5.8"
requires "libsha >= 1.0"
requires "zippy >= 0.10"
requires "ws >= 0.6.0"

task build3cx, "Compile the entry module into a binary named 3cx":
  exec "nim c -d:release --out:3cx src/threecodex.nim"

task test, "Run the test suite":
  exec "nim r --hints:off --path:src tests/test_threecodex.nim"
  exec "nim r --hints:off --path:src tests/test_keyevent.nim"