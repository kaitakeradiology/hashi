# Building hashi from scratch

From an empty Linux machine to a passing test suite.

Hashi builds with **Nimony**, the Nim 3 era compiler, not with a stock
Nim 2 compiler. The Nimony toolchain is the only prerequisite; hashi has no
dependencies beyond Nimony's standard library.

## What you need

- Nim 2.2 (`nim`) and a C compiler, only to bootstrap Nimony. CI uses
  2.2.10, which bootstraps the pinned Nimony without any flags.
- Nimony: <https://github.com/nim-lang/nimony>.
- For the benchmarks only: `wrk` and a Mummy checkout.

**Platform.** Linux is what CI runs, over epoll or io_uring. `std/ioring`
also has kqueue, WSAPoll and IOCP backends, so macOS, the BSDs and Windows
are within reach and untested; the socket FFI in `src/hashi/net.nim` is the
Linux-specific surface to port first.

## 1. The Nimony toolchain

Clone Nimony as a sibling of this checkout, so the layout is:

```
some-dir/
  hashi/
  nimony/
```

Then bootstrap from inside `nimony/`, with a Nim 2 `nim` on `PATH`:

```
nim c -r src/hastur/hastur build all
```

`hastur` is Nimony's build orchestrator; `build all` produces every tool,
including the compiler (`bin/nimony`). It is a long compile. If the host Nim promotes `ProveInit`
or `Uninit` warnings to errors in its own stdlib, add
`--warningAsError:ProveInit:off --warningAsError:Uninit:off` to that
command; those warnings come from the host stdlib, not from Nimony.

If Nimony lives elsewhere, set `NIMONY=/path/to/bin/nimony`; `tests/run`,
`doc/gen` and `bench/run.sh` all honour it.

## 2. Build and test

Each `tests/test_*.nim` is a standalone program that exits non-zero on
failure; `tests/run` compiles and runs each one and aggregates the result.

```
tests/run                    # unit tests
tests/run --fuzz             # unit tests + the parser fuzzers
tests/run test_http_request  # one test by name
```

Run from the repository root so `nimony.paths`, which puts `src` on the
module search path, is found. The examples
build the same way:

```
../nimony/bin/nimony c -r examples/hello.nim
```

## 3. Documentation

```
doc/gen
```

generates the API reference into `htmldocs/` with `nimony doc`, using
`src/hashi.nim` as the root so every public module is covered. Open
`htmldocs/theindex.html`.

## 4. Continuous integration and the from-scratch proof

`.github/workflows/test.yml` does everything above on a fresh runner: it
checks out Nimony at the commit pinned in its `NIMONY_REF`, bootstraps it
with a stable Nim 2, caches the result per pin, then runs the suite, builds
every example, bench and smoke program, and generates the docs. On a push
to `main` a second job publishes the generated reference to GitHub Pages;
the repository's Pages source must be set to "GitHub Actions" once.
`.forgejo/workflows/test.yml` runs the same suite on a Forgejo runner that
has a prebuilt Nimony, without the bootstrap. Nimony is
pre-release and changes daily, so the pin is bumped deliberately, after the
suite passes locally against the new commit.

`tests/clean_build` is the local twin of that job. In a bubblewrap sandbox
with a read-only OS, an empty home and only this checkout's git objects, it
clones Nimony at the pinned commit, bootstraps it with the Nim 2 install you
name, clones hashi's committed tree and runs the same steps:

```
tests/clean_build /path/to/nim-2.2.x
```

Use it before bumping the pin or changing this document; it proves the
instructions from nothing, which a developer checkout with a warm sibling
never does.

## 5. Benchmarks (optional)

`bench/run.sh` builds the hashi and Mummy servers and drives `wrk` at 100
and 1000 connections. It needs `wrk`, a Nim 2 `nim` for Mummy, and a Mummy
checkout (`MUMMY=`, default `$HOME/Projects/Develop/mummy`). See
`doc/benchmarks.md` and `bench/README.md`.
