#!/usr/bin/env bash
#
# opa/mayhem/test.sh — RUN the project's own Go test suite (scoped to the fuzzed
# ast/v1/ast packages) plus a known-answer probe, and emit a CTRF summary.
# exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `go test ./ast/... ./v1/ast/...` — OPA's own hand-written suite: known-answer
#     parser/compiler tests (exact ASTs, exact error strings, golden type-checking
#     results) across the real `ast` (deprecated v0-compat wrapper) and `v1/ast`
#     (the package our fuzz targets exercise) packages. Genuine BEHAVIOUR
#     assertions, not "exits 0". Scoped (not `./...`) so this stays fast and
#     self-contained — OPA's full suite spans e2e/server/plugin tests that need
#     network/docker and aren't needed to validate the parser/compiler surface we
#     integrate.
#
#  2) The KAT probe /mayhem/kat — because `go test` links a STATIC binary, the
#     verify-repo sabotage check (LD_PRELOAD a shim whose constructor _exit(0)s
#     every non-system executable) CANNOT neuter it. A `go test`-only oracle
#     therefore survives sabotage while proving nothing, which is exactly the
#     reward-hackable case the spec forbids. /mayhem/kat is built with cgo =>
#     DYNAMICALLY linked, so the shim DOES neuter it; it then prints nothing and
#     the exact-match assertions below fail. The probe parses/compiles a fixed
#     Rego module and asserts the resolved package path, rule count, each rule
#     head's stringified form, the post-compile rule count, and the exact
#     ast.Errors code for a deliberately-invalid module — real parsed VALUES, not
#     a liveness check. A patch that stubs the parser to stop a crash cannot
#     reproduce them.
#
# This script only RUNS things; mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) the project's own Go suite (scoped to the fuzzed surface) ────────────────
if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 2
fi

echo "=== running: go test -json ./ast/... ./v1/ast/... ==="
mkdir -p "$SRC/mayhem-build"
JSON="$SRC/mayhem-build/gotest.json"
go test -json ./ast/... ./v1/ast/... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?
go test ./ast/... ./v1/ast/... 2>&1 | tail -30 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events only (lines carrying a non-empty "Test" field); package-level
# pass/fail lines have no "Test" field. Subtests count — they are real asserted cases.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no test events parsed — the suite did not run (go exit $rc)" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 1
fi
# A non-zero go exit with zero counted failures means a build/vet error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. Fixtures
# are embedded in the probe itself (no fixture file to guard on), so there is no
# `[ -f ... ]` gate here that could quietly degrade the oracle.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

# Expected values, captured by actually running ast.ParseModule/ast.CompileModules
# (go1.26.7, github.com/open-policy-agent/opa v1/ast @ this commit) over the exact
# fixtures embedded in mayhem/kat/main.go:
kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or parser/compiler broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "resolved package path"          'KAT_PACKAGE=data.example'
kat_expect "parsed rule count"              'KAT_NUM_RULES=3'
kat_expect "rule[0] head (default rule)"    'KAT_RULE_0=allow := false'
kat_expect "rule[1] head (if-block rule)"   'KAT_RULE_1=allow = true'
kat_expect "rule[2] head (partial-set rule)" 'KAT_RULE_2=deny contains msg'
kat_expect "post-compile rule count"        'KAT_COMPILED_NUM_RULES=3'
kat_expect "invalid-module parse error code" 'KAT_BAD_ERR_CODE=rego_parse_error'

emit_ctrf "go-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
