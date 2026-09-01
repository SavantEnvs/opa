package main

// Force cgo + EXTERNAL linking so the KAT probe is a DYNAMICALLY linked ELF.
//
// This is load-bearing, not incidental: verify-repo's sabotage check neuters the
// program under test by LD_PRELOADing a shim whose constructor calls _exit(0).
// LD_PRELOAD only applies to dynamically linked executables. A pure-Go build is
// statically linked and would silently ignore the shim, which is exactly how a
// `go test`-only oracle passes the sabotage check while asserting nothing
// (SPEC §6.3). Importing "C" makes the toolchain use the external linker, so the
// probe loads ld.so, honours LD_PRELOAD, and the oracle can detect sabotage.
//
// mayhem/build.sh builds this package with CGO_ENABLED=1 and asserts the result
// is dynamically linked, so a regression here fails the build rather than
// silently weakening the oracle.

/*
#include <stdlib.h>
*/
import "C"

var _ = C.EXIT_SUCCESS
