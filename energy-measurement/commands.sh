#!/usr/bin/env bash

# Literal transcription of two steps of .github/workflows/ci.yml at
# 6eb720a1b7cafca3ebe0ab5c76674272cd3044f9, both on Node 24 and ubuntu-latest:
# the build of the Lint job (step "build and check generated types", without
# its git status check) and the test step of the Tests job, matrix entry
# {node-version: 24, os: ubuntu-latest}.

# GitHub runs every `run:` block under `bash -e`.
set -euo pipefail
STAGE="${1:?stage required: build | test}"

cd /workspace

# The Actions runner defines both for every step; CI is also set on the test
# step (ci.yml, Tests job). GITHUB_ACTIONS selects the minimal reporter in
# vitest.config.js.
export CI=true
export GITHUB_ACTIONS=true

# Every stage runs all of its commands and exits with the first non-zero code,
# so one failing command never truncates the workload of the others.
STAGE_EXIT=0
run_step() {
  local label="$1"; shift
  local rc
  echo "=== ${label}: start $(date -u +%FT%TZ) ==="
  set +e
  "$@"
  rc=$?
  set -e
  echo "=== ${label}: end $(date -u +%FT%TZ) exit=${rc} ==="
  if [ "$rc" -ne 0 ] && [ "$STAGE_EXIT" -eq 0 ]; then
    STAGE_EXIT="$rc"
  fi
  return 0
}

case "$STAGE" in

  build)
    # Lint job, step "build and check generated types"
    run_step "pnpm build" \
      pnpm build
    ;;

  test)
    # Tests job, step "pnpm test"
    run_step "pnpm test" \
      pnpm test
    ;;

  *)
    echo "unknown stage: $STAGE" >&2
    exit 2
    ;;

esac

echo "=== stage ${STAGE}: aggregate exit=${STAGE_EXIT} ==="
exit "$STAGE_EXIT"
