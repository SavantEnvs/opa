// mayhem/kat — known-answer-test probe for mayhem/test.sh.
//
// WHY A SEPARATE BINARY (SPEC §6.3 anti-reward-hacking):
// `go test` links a STATIC binary, so the verify-repo sabotage check (which
// LD_PRELOADs a shim whose constructor calls _exit(0) for non-system executables)
// cannot neuter it — a suite that only runs `go test` is therefore immune to the
// sabotage check and does NOT prove the oracle is behavioral. This probe is built
// with cgo (see cgo_dynamic.go) so it is DYNAMICALLY linked: the shim reaches it,
// the process becomes an instant no-op, it prints nothing, and test.sh's exact
// string assertions fail. That is what makes the oracle sabotage-detecting.
//
// It is also a real KAT, not a liveness check: it parses/compiles a FIXED Rego
// module (embedded below) through github.com/open-policy-agent/opa/v1/ast and
// asserts exact VALUES read off it — the resolved package path, the rule count,
// each rule head's stringified form, the post-compile rule count, and (for a
// second, deliberately-invalid module) the exact ast.Errors code the parser
// returns. A patch that stubs the parser/compiler to "fix" a crash cannot
// reproduce these values.
//
// Ground truth for every asserted value below was captured by actually running
// ast.ParseModule/ast.CompileModules over goodRego/badRego (go1.26.7,
// github.com/open-policy-agent/opa v1/ast @ this commit) — see mayhem/test.sh
// for the expected lines.
//
// Usage: kat   (no args — the fixtures are embedded, not read from disk: SPEC
// §6.2 item 13 forbids absolute in-image paths, and a relative path would break
// under a different cwd; embedding sidesteps both.)
// Prints lines of the form KAT_<NAME>=<value>, which test.sh matches EXACTLY.
package main

import (
	"fmt"

	"github.com/open-policy-agent/opa/v1/ast"
)

const goodRego = `package example

import rego.v1

default allow := false

allow if {
	input.method == "GET"
	input.path == "/health"
}

deny contains msg if {
	input.method != "GET"
	msg := "method not allowed"
}
`

// badRego is syntactically invalid (an unterminated rule body) so ParseModule
// MUST return a parse error; asserting its exact code proves the parser is
// actually running, not just returning some generic non-nil error.
const badRego = `package example

allow if {
`

func main() {
	mod, err := ast.ParseModule("kat.rego", goodRego)
	if err != nil {
		fmt.Printf("KAT_PARSE_ERROR=%v\n", err)
		return
	}
	fmt.Printf("KAT_PACKAGE=%s\n", mod.Package.Path.String())
	fmt.Printf("KAT_NUM_RULES=%d\n", len(mod.Rules))
	for i, r := range mod.Rules {
		fmt.Printf("KAT_RULE_%d=%s\n", i, r.Head.String())
	}

	compiler, err := ast.CompileModules(map[string]string{"kat.rego": goodRego})
	if err != nil {
		fmt.Printf("KAT_COMPILE_ERROR=%v\n", err)
		return
	}
	cm := compiler.Modules["kat.rego"]
	fmt.Printf("KAT_COMPILED_NUM_RULES=%d\n", len(cm.Rules))

	_, badErr := ast.ParseModule("bad.rego", badRego)
	if badErr == nil {
		fmt.Println("KAT_BAD_ERR_CODE=<none>")
		return
	}
	if errs, ok := badErr.(ast.Errors); ok && len(errs) > 0 {
		fmt.Printf("KAT_BAD_ERR_CODE=%s\n", errs[0].Code)
	} else {
		fmt.Println("KAT_BAD_ERR_CODE=<untyped>")
	}
}
