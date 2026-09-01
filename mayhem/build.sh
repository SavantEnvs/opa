#!/usr/bin/env bash
#
# opa/mayhem/build.sh — build the Rego parser + compiler as sanitized libFuzzer
# binaries, plus the project's KAT probe.
#
# Targets produced (one Mayhemfile each):
#   /mayhem/fuzz_parse    — ast.ParseModule            (Rego lexer/parser)
#   /mayhem/fuzz_compile  — ast.CompileModules          (parse + full compile pipeline)
#   /mayhem/kat           — dynamically-linked known-answer probe used by mayhem/test.sh
#
# Upstream is NOT an OSS-Fuzz project. It DOES ship native Go fuzz functions
# (v1/ast/fuzz_test.go: FuzzCompileModules, FuzzCompileModulesWithPrintAndAllFutureKWs)
# over the same CompileModules surface fuzz_compile targets here — but that file's
# corpus setup (cases.MustLoad("../test/cases/testdata/v1")) does relative-path
# file I/O once at process start, and both Fuzz* funcs live in a directory
# (v1/ast) that already mixes `package ast` (internal test files) and
# `package ast_test` (external test files) — a combination go-118-fuzz-build's
# package loader cannot load (see the Go section of docs/netnew-worker-prompt.md).
# So mayhem/harness_fuzz_*.go.src reach the SAME target functions (ParseModule /
# CompileModules) through their PUBLIC API from dedicated staging packages
# instead — see those files' headers for the full rationale.
#
# Go path is ASan-only for the libFuzzer link (as OSS-Fuzz's Go path is): the .a
# archive carries the Go fuzz code instrumented by go-118-fuzz-build, then clang++
# links it against the libFuzzer engine.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 with no
# downgrade knob. The C/CGO shims clang compiles (the LLVMFuzzerTestOneInput
# wrapper, the CGO bridge) default to DWARF5 under clang-19, so we force them —
# and the final link — to DWARF3 via $GO_DEBUG_FLAGS. verify-repo reads the FIRST
# CU's DWARF version, which is the C shim at DWARF3, satisfying the < 4 gate.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs this script OFFLINE.
# This first (online) build populates $GOMODCACHE under /opt/toolchains; the cache
# doubles as a file proxy, which GOPROXY prefers, so the offline re-run resolves
# from it. Re-running on an already-built tree must succeed (idempotent).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# ASan-only for the Go libFuzzer link. An explicit empty --build-arg SANITIZER_FLAGS=
# yields a no-sanitizer (natural-crash) build, so default with `=` not `:=`.
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

# DWARF3 for every clang-compiled shim + the final link (see header).
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Offline-first module resolution. $(go env GOMODCACHE) reads the pinned ENV from
# the Dockerfile, so this path is right under ANY $HOME (CI or the PATCH re-run).
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# go-118-fuzz-build rewrites the stdlib `testing` import to its own shim, which must
# be on the module graph. Order matters: tidy FIRST, then `go get` the shim — a
# trailing tidy would prune it again (nothing imports it until the builder generates
# the entrypoint). Both resolve from the module cache when offline.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# Stage each harness into its OWN single-file package under a leading-underscore
# dir (go build/go test ./... wildcards skip these automatically — see the
# harnesses' own header comments for why a dedicated package, not the real v1/ast
# dir, is required here). Idempotent (mkdir -p + cp -f).
mkdir -p "$SRC/_mayhem_harness/fuzz_parse" "$SRC/_mayhem_harness/fuzz_compile"
cp -f "$SRC/mayhem/harness_fuzz_parse.go.src"   "$SRC/_mayhem_harness/fuzz_parse/harness.go"
cp -f "$SRC/mayhem/harness_fuzz_compile.go.src" "$SRC/_mayhem_harness/fuzz_compile/harness.go"

# build_target <output-name> <fuzz-func> <staging-dir>
build_target() {
  local target="$1" func="$2" dir="$3"
  echo "=== building $target ($func, go-118-fuzz-build) ==="
  go-118-fuzz-build -o "$SRC/mayhem-build/$target.a" -func "$func" "$SRC/$dir"
  # shellcheck disable=SC2086  # word-splitting of the flag lists is intended
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
      "$SRC/mayhem-build/$target.a" -o "/mayhem/$target"
  echo "built /mayhem/$target"
}

build_target fuzz_parse   FuzzMayhemParseModule    _mayhem_harness/fuzz_parse
build_target fuzz_compile FuzzMayhemCompileModules _mayhem_harness/fuzz_compile

# ── The KAT probe used by mayhem/test.sh (NORMAL flags — it is a functional oracle,
#    not a triage artifact, so no sanitizer/fuzz instrumentation here). ───────────
# CGO_ENABLED=1 + the `import "C"` file force EXTERNAL linking so the probe is
# DYNAMICALLY linked and therefore reachable by verify-repo's LD_PRELOAD sabotage
# shim (SPEC §6.3). Assert that, so a toolchain change can't silently turn the
# probe static and weaken the oracle to a `go test`-only pass.
echo "=== building /mayhem/kat (KAT probe, cgo => dynamically linked) ==="
CGO_ENABLED=1 CGO_CFLAGS="$GO_DEBUG_FLAGS" go build -o /mayhem/kat ./mayhem/kat
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

# Go's `go test` compiles on demand, so there is no separate test-suite build step;
# mayhem/test.sh runs `go test ./ast/... ./v1/ast/...` with the project's normal flags.

echo "build.sh complete:"
ls -la /mayhem/fuzz_parse /mayhem/fuzz_compile /mayhem/kat
