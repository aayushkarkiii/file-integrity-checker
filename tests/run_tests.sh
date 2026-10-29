#!/usr/bin/env bash
# ==============================================================================
# Test runner for FIM (File Integrity Checker)
# Runs bats directly if available, or runs in a containerized environment.
# ==============================================================================

set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/.." && pwd)"

if command -v bats &>/dev/null; then
    echo "Running tests with host bats binary..."
    bats "$TEST_DIR/fim.bats"
elif command -v docker &>/dev/null; then
    echo "Host bats not found. Running tests via bats-core Docker container..."
    docker run --rm -v "$ROOT_DIR:/code" -w /code bats/bats:latest tests/fim.bats
else
    echo "Error: Neither 'bats' nor 'docker' is available to run test suite." >&2
    exit 2
fi
