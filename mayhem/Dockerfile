# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — GO target (go modules / go-fuzz-build). Builds ON TOP
# of the org C/C++ base (ghcr.io/savantenvs/base) — clang is needed to link the
# go-fuzz libFuzzer archive — adding a pinned Go toolchain + go-fuzz under
# /opt/toolchains/go, then runs the per-repo mayhem/build.sh.
#
# WHY a Go-specific template (SPEC §6.2 items 8/9, §6.5):
#   Go's GOPATH/GOMODCACHE default to $HOME/go. The commit build and the PATCH RL
#   re-run use DIFFERENT $HOMEs, so a cache left at the default would vanish under
#   the re-run identity. We pin GOROOT/GOPATH/GOMODCACHE at FIXED, $HOME-independent
#   paths under /opt/toolchains so (a) the toolchain locks uniformly (§4/§5) and
#   (b) the module cache the FIRST (online) build fills is found again — by the SAME
#   absolute GOMODCACHE — when build.sh re-runs OFFLINE at the PATCH tier.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ─────────────────
# Pin the Go version AND its tarball sha256 (reproducible fetch). OPA's own go.mod
# declares `go 1.26.0` as its minimum toolchain (GOTOOLCHAIN=local below refuses
# anything older), so this must be >= that — pinned to the exact go.dev release,
# not a moving `go1.26`/`latest`.
ARG GO_VERSION=1.26.7
ARG GO_SHA256=ffb5f8de10c62550dfddab66b36b57030721e0a44a3218e9e1181d7b59f121ca
# go-118-fuzz-build builds the NATIVE `func FuzzX(f *testing.F)` harness style this repo
# uses. Pinned by COMMIT, not @latest, so the module cache this build populates is
# deterministic. (The repo's release TAG is a stale 2022 snapshot predating the
# .../testing shim and still shelling out to a `gotip` binary that is not on PATH.)
ARG GO118_FUZZ_BUILD_VERSION=a70c2aa677fa43583571959478decabe02a96cd6

ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:${PATH}

USER root
RUN install -d /opt/toolchains/go-path \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
 && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
 && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm -f /tmp/go.tgz \
 # go-fuzz + go-fuzz-build (the libFuzzer build path). Installing them also seeds the
 # go-fuzz module (incl. go-fuzz-dep) into GOMODCACHE, which build.sh needs offline.
 && go version \
 && go install "github.com/AdamKorcz/go-118-fuzz-build@${GO118_FUZZ_BUILD_VERSION}" \
 && chmod -R a+rX /opt/toolchains/go \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
 # read the toolchain and read/refresh the module cache, so hand the GOPATH to 2000.
 && chown -R 2000:2000 /opt/toolchains/go-path

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $GOMODCACHE (online, this first build) and builds the libFuzzer target(s).
RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
