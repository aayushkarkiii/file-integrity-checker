#!/usr/bin/env bash
# ==============================================================================
# File Integrity Checker (FIM)
# Detects unexpected changes (added, removed, modified) in watched directories.
# Exit codes: 0 = Clean, 1 = Changes found, 2 = Error
# ==============================================================================

set -eo pipefail

VERSION="1.0.0"

# Default configuration values
CONFIG_FILE="${CONFIG_FILE:-}"
WATCH_DIRS="${WATCH_DIRS:-}"
BASELINE_FILE="${BASELINE_FILE:-}"
CHECK_METADATA="${CHECK_METADATA:-true}"
VERBOSE="${VERBOSE:-false}"
QUIET="${QUIET:-false}"

# ------------------------------------------------------------------------------
# Helpers & Logging
# ------------------------------------------------------------------------------
log_info() {
    if [[ "$QUIET" != "true" ]]; then
        echo -e "[INFO] $*"
    fi
}

log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

log_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
}

usage() {
    cat <<EOF
File Integrity Checker (FIM) v${VERSION}

Usage: $(basename "$0") [options] <command>

Commands:
  init      Generate a fresh SHA-256 baseline for watched paths
  check     Compare current filesystem state against baseline
  update    Re-baseline watched paths after approved changes
  version   Display version information
  help      Display this help message

Options:
  -c, --config <file>     Path to configuration file
  -b, --baseline <file>   Override baseline database path
  -w, --watch <dirs>      Override watched directory (comma/space separated)
  -v, --verbose           Enable detailed output
  -q, --quiet             Suppress informational output

Exit Codes:
  0  Clean (no unauthorized changes detected)
  1  Changes detected (added, removed, or modified files)
  2  Error (missing baseline, invalid configuration, etc.)
EOF
}

# ------------------------------------------------------------------------------
# Configuration Loader
# ------------------------------------------------------------------------------
load_config() {
    local candidates=(
        "$CONFIG_FILE"
        "${FIM_CONFIG:-}"
        "./conf/fim.conf"
        "/etc/fim/fim.conf"
    )

    local loaded=false
    local loaded_path=""
    for path in "${candidates[@]}"; do
        if [[ -n "$path" && -f "$path" ]]; then
            # shellcheck source=/dev/null
            source "$path"
            loaded=true
            loaded_path="$path"
            break
        fi
    done

    if [[ "$VERBOSE" == "true" ]]; then
        if [[ "$loaded" == "true" ]]; then
            log_info "Loaded configuration file from: $loaded_path"
        else
            log_info "No configuration file found. Using environment or built-in defaults."
        fi
    fi

    # Fallback defaults if not set in config or flags
    WATCH_DIRS="${WATCH_DIRS_OVERRIDE:-${WATCH_DIRS:-}}"
    BASELINE_FILE="${BASELINE_OVERRIDE:-${BASELINE_FILE:-/var/lib/fim/baseline.db}}"
    CHECK_METADATA="${CHECK_METADATA:-true}"

    if [[ -z "$WATCH_DIRS" ]]; then
        log_error "No watched directories specified. Set WATCH_DIRS in config or use -w."
        exit 2
    fi
}

check_dependencies() {
    local deps=("sha256sum" "stat" "awk" "find" "sort")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required dependency '$cmd' is not installed."
            exit 2
        fi
    done
}

# ------------------------------------------------------------------------------
# Manifest Generation
# ------------------------------------------------------------------------------
# Output format per line:
# PATH\tSHA256\tSIZE\tMODE\tOWNER:GROUP\tMTIME
generate_manifest() {
    local out_file="$1"
    local raw_file
    raw_file="$(mktemp)"

    # Normalize watched directories into array
    local dirs=()
    read -r -a dirs <<< "${WATCH_DIRS//,/ }"

    # Ensure baseline directory is outside watched paths or excluded
    local baseline_abs=""
    if [[ -f "$BASELINE_FILE" ]]; then
        baseline_abs="$(readlink -f "$BASELINE_FILE" 2>/dev/null || echo "$BASELINE_FILE")"
    fi

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            log_warn "Directory '$dir' does not exist or is inaccessible. Skipping."
            continue
        fi

        # Find all regular files
        find "$dir" -type f 2>/dev/null | while IFS= read -r file; do
            # Do not record baseline database itself if it lives in watch directory
            local file_abs
            file_abs="$(readlink -f "$file" 2>/dev/null || echo "$file")"
            if [[ -n "$baseline_abs" && "$file_abs" == "$baseline_abs" ]]; then
                continue
            fi

            # Compute SHA-256 hash
            local hash
            hash="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')"
            if [[ -z "$hash" ]]; then
                continue
            fi

            # Extract metadata: size, octal mode, uid:gid, mtime epoch
            local stat_info
            stat_info="$(stat -c "%s	%a	%u:%g	%Y" "$file" 2>/dev/null || true)"
            if [[ -n "$stat_info" ]]; then
                printf "%s\t%s\t%s\n" "$file" "$hash" "$stat_info" >> "$raw_file"
            fi
        done
    done

    # Deterministic sort by file path
    if [[ -s "$raw_file" ]]; then
        sort -t$'\t' -k1,1 "$raw_file" > "$out_file"
    else
        touch "$out_file"
    fi

    rm -f "$raw_file"
}

# ------------------------------------------------------------------------------
# Core Commands
# ------------------------------------------------------------------------------
cmd_init() {
    log_info "Initializing baseline database: $BASELINE_FILE"

    local base_dir
    base_dir="$(dirname "$BASELINE_FILE")"
    if [[ ! -d "$base_dir" ]]; then
        mkdir -p "$base_dir" 2>/dev/null || {
            log_error "Cannot create baseline directory: $base_dir (check permissions)"
            exit 2
        }
    fi

    generate_manifest "$BASELINE_FILE"

    local count
    count="$(wc -l < "$BASELINE_FILE" | tr -d ' ')"
    log_info "Baseline initialized successfully with $count file(s)."
    exit 0
}

cmd_check() {
    if [[ ! -f "$BASELINE_FILE" ]]; then
        log_error "Baseline file '$BASELINE_FILE' not found. Run '$(basename "$0") init' first."
        exit 2
    fi

    log_info "Verifying file integrity against: $BASELINE_FILE"

    local curr_manifest
    curr_manifest="$(mktemp)"
    generate_manifest "$curr_manifest"

    # Compare baseline and current manifest using awk
    local diff_output

    # Note: AWK exit code 1 indicates differences found, 0 indicates clean
    set +e
    diff_output="$(awk -F'\t' -v check_meta="$CHECK_METADATA" '
    BEGIN {
        added = 0; removed = 0; modified = 0;
    }
    # First file: Baseline
    NR == FNR {
        base_hash[$1]  = $2
        base_size[$1]  = $3
        base_mode[$1]  = $4
        base_owner[$1] = $5
        base_mtime[$1] = $6
        baseline_files[$1] = 1
        next
    }
    # Second file: Current manifest
    {
        current_files[$1] = 1
        if (!($1 in baseline_files)) {
            print "\033[1;32m[ADDED]\033[0m    " $1
            added++
        } else {
            reasons = ""
            if (base_hash[$1] != $2) {
                reasons = reasons "content_hash,"
            }
            if (check_meta == "true") {
                if (base_size[$1] != $3)  reasons = reasons "size,"
                if (base_mode[$1] != $4)  reasons = reasons "permissions(" base_mode[$1] "->" $4 "),"
                if (base_owner[$1] != $5) reasons = reasons "owner(" base_owner[$1] "->" $5 "),"
                if (base_mtime[$1] != $6) reasons = reasons "mtime,"
            }
            if (reasons != "") {
                # Trim trailing comma
                sub(/,$/, "", reasons)
                print "\033[1;31m[MODIFIED]\033[0m " $1 " [" reasons "]"
                modified++
            }
        }
    }
    END {
        for (f in baseline_files) {
            if (!(f in current_files)) {
                print "\033[1;33m[REMOVED]\033[0m  " f
                removed++
            }
        }
        total = added + removed + modified
        if (total > 0) {
            printf "\nIntegrity check FAILED: %d change(s) found (Added: %d, Removed: %d, Modified: %d)\n", total, added, removed, modified > "/dev/stderr"
            exit 1
        }
    }
    ' "$BASELINE_FILE" "$curr_manifest")"
    local awk_status=$?
    set -e

    rm -f "$curr_manifest"

    if [[ -n "$diff_output" ]]; then
        echo -e "$diff_output"
    fi

    if [[ $awk_status -eq 1 ]]; then
        exit 1
    elif [[ $awk_status -ne 0 ]]; then
        log_error "Manifest comparison encountered an internal error."
        exit 2
    fi

    log_info "Integrity check PASSED: No changes detected."
    exit 0
}

cmd_update() {
    log_info "Updating baseline database with approved changes: $BASELINE_FILE"
    cmd_init
}

# ------------------------------------------------------------------------------
# CLI Options Parsing
# ------------------------------------------------------------------------------
WATCH_DIRS_OVERRIDE=""
BASELINE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -b|--baseline)
            BASELINE_OVERRIDE="$2"
            shift 2
            ;;
        -w|--watch)
            WATCH_DIRS_OVERRIDE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift
            ;;
        -q|--quiet)
            QUIET="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --version)
            echo "File Integrity Checker v${VERSION}"
            exit 0
            ;;
        init|check|update|help|version)
            COMMAND="$1"
            shift
            break
            ;;
        *)
            log_error "Unknown option or argument: $1"
            usage
            exit 2
            ;;
    esac
done

COMMAND="${COMMAND:-${1:-}}"

if [[ -z "$COMMAND" || "$COMMAND" == "help" ]]; then
    usage
    exit 0
fi

if [[ "$COMMAND" == "version" ]]; then
    echo "File Integrity Checker v${VERSION}"
    exit 0
fi

check_dependencies
load_config

case "$COMMAND" in
    init)
        cmd_init
        ;;
    check)
        cmd_check
        ;;
    update)
        cmd_update
        ;;
    *)
        log_error "Unknown command '$COMMAND'. Expected: init, check, or update."
        usage
        exit 2
        ;;
esac
