#!/usr/bin/env bats
# ==============================================================================
# Bats Tests for File Integrity Checker (FIM)
# Tests one scenario per change type (Added, Removed, Modified, Clean, Error, Update)
# ==============================================================================

setup() {
    # Resolve absolute path to script under test
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    FIM_BIN="$SCRIPT_DIR/bin/fim.sh"

    # Create temporary isolated test environment
    TEST_DIR="$(mktemp -d)"
    WATCH_DIR="$TEST_DIR/watched"
    DB_DIR="$TEST_DIR/db"
    BASELINE_FILE="$DB_DIR/baseline.db"

    mkdir -p "$WATCH_DIR" "$DB_DIR"

    # Seed initial test files
    echo "alpha content" > "$WATCH_DIR/file_alpha.txt"
    echo "beta content" > "$WATCH_DIR/file_beta.txt"
    chmod 644 "$WATCH_DIR/file_alpha.txt" "$WATCH_DIR/file_beta.txt"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "Init: successfully builds baseline database with correct schema" {
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" init
    [ "$status" -eq 0 ]
    [ -f "$BASELINE_FILE" ]

    # Baseline should contain 2 lines (one per initial file)
    lines_count="$(wc -l < "$BASELINE_FILE" | tr -d ' ')"
    [ "$lines_count" -eq 2 ]
}

@test "Check: clean state exits 0 with no detected changes" {
    # Initialize baseline
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" init
    [ "$status" -eq 0 ]

    # Run check without any file changes
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" check
    [ "$status" -eq 0 ]
    [[ "$output" =~ "No changes detected" ]]
}

@test "Check: detects added file and exits 1" {
    # Initialize baseline
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" init
    [ "$status" -eq 0 ]

    # Simulate added file
    echo "gamma new file" > "$WATCH_DIR/file_gamma.txt"

    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" check
    [ "$status" -eq 1 ]
    [[ "$output" =~ "[ADDED]" ]]
    [[ "$output" =~ "file_gamma.txt" ]]
}

@test "Check: detects removed file and exits 1" {
    # Initialize baseline
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" init
    [ "$status" -eq 0 ]

    # Simulate removed file
    rm -f "$WATCH_DIR/file_beta.txt"

    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" check
    [ "$status" -eq 1 ]
    [[ "$output" =~ "[REMOVED]" ]]
    [[ "$output" =~ "file_beta.txt" ]]
}

@test "Check: detects modified file content hash and exits 1" {
    # Initialize baseline
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" init
    [ "$status" -eq 0 ]

    # Simulate modified content
    echo "tampered content payload" >> "$WATCH_DIR/file_alpha.txt"

    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" check
    [ "$status" -eq 1 ]
    [[ "$output" =~ "[MODIFIED]" ]]
    [[ "$output" =~ "content_hash" ]]
}

@test "Check: detects metadata (permission mode) change and exits 1" {
    # Initialize baseline
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" init
    [ "$status" -eq 0 ]

    # Change permissions
    chmod 777 "$WATCH_DIR/file_alpha.txt"

    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" check
    [ "$status" -eq 1 ]
    [[ "$output" =~ "[MODIFIED]" ]]
    [[ "$output" =~ "permissions" ]]
}

@test "Update: re-baselines approved changes and restores clean status" {
    # Initialize baseline
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" init
    [ "$status" -eq 0 ]

    # Modify a file and add a file
    echo "approved modification" > "$WATCH_DIR/file_alpha.txt"
    echo "approved new file" > "$WATCH_DIR/file_delta.txt"

    # Check should fail initially
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" check
    [ "$status" -eq 1 ]

    # Run update to accept approved changes
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" update
    [ "$status" -eq 0 ]

    # Subsequent check should now pass cleanly
    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" check
    [ "$status" -eq 0 ]
}

@test "Error: exits 2 when baseline database does not exist" {
    rm -f "$BASELINE_FILE"

    run "$FIM_BIN" -w "$WATCH_DIR" -b "$BASELINE_FILE" check
    [ "$status" -eq 2 ]
    [[ "$output" =~ "not found" ]]
}
