# File Integrity Checker (`fim`)

A lightweight, zero-dependency File Integrity Monitoring (FIM) tool built with standard Linux coreutils and Bash. It establishes a cryptographic and metadata baseline for sensitive directories (e.g., `/etc`, `/bin`, `/usr/bin`) and alerts on unauthorized file additions, deletions, or modifications.

If tools like AIDE, Tripwire, or OSSEC feel like overkill for your pipeline or minimal server fleet, this tool provides the same core auditing guarantees using standard POSIX utilities (`find`, `sha256sum`, `stat`, and `awk`).

---

## How It Works

1. **Manifest Generation**: Crawls target directories and computes a sorted, tab-delimited record for every regular file:
   ```text
   PATH    SHA256_HASH    SIZE_BYTES    OCTAL_MODE    UID:GID    MTIME_EPOCH
   ```
2. **External Baseline Storage**: The baseline file (default: `/var/lib/fim/baseline.db`) is stored strictly outside monitored directories to prevent self-referential tampering.
3. **AWK Diff Engine**: On every `check`, a temporary manifest is generated in-memory and compared against the baseline in a single pass. It isolates the exact nature of modifications:
   * Content alteration (hash mismatch)
   * Permission alterations (mode changes like `644` -> `777`)
   * Ownership changes (UID/GID shifts)
   * File additions (`[ADDED]`) and file deletions (`[REMOVED]`)
4. **Predictable Exit Codes**: Integrates cleanly into CI pipelines, monitoring agents, and systemd units.

---

## Directory Structure

```text
File-Integrity-Checker/
├── bin/
│   └── fim.sh              # Main CLI utility (init, check, update)
├── conf/
│   └── fim.conf            # Default configuration (watch paths, db location)
├── systemd/
│   ├── fim.service         # One-shot systemd service unit
│   └── fim.timer           # Daily scheduled execution timer
├── tests/
│   ├── fim.bats            # Automated bats-core test suite
│   └── run_tests.sh        # Dual-mode test runner (native bats or dockerized)
├── .github/
│   └── workflows/ci.yml    # GitHub Actions workflow (ShellCheck + Bats)
├── Dockerfile              # Container image for read-only filesystem auditing
├── .dockerignore
├── .gitignore
└── readme.md
```

---

## Quickstart

### Prerequisites
Standard Linux utilities (`bash`, `coreutils`, `findutils`, `gawk`). No external interpreters or heavy packages required.

### 1. Initialize the Baseline
Crawl your target paths and generate the cryptographic baseline database:

```bash
./bin/fim.sh -w /etc,/usr/local/bin -b /var/lib/fim/baseline.db init
```

*Sample output:*
```text
[INFO] Initializing baseline database: /var/lib/fim/baseline.db
[INFO] Baseline initialized successfully with 214 file(s).
```

### 2. Run an Integrity Audit
Verify the current filesystem state against the saved baseline:

```bash
./bin/fim.sh -w /etc,/usr/local/bin -b /var/lib/fim/baseline.db check
```

*When no changes are present:*
```text
[INFO] Verifying file integrity against: /var/lib/fim/baseline.db
[INFO] Integrity check PASSED: No changes detected.
```

*When unauthorized changes occur:*
```text
[INFO] Verifying file integrity against: /var/lib/fim/baseline.db
[ADDED]    /etc/cron.d/suspicious_job
[MODIFIED] /etc/sudoers [content_hash,mtime]
[MODIFIED] /etc/shadow [permissions(600->644),mtime]
[REMOVED]  /etc/nginx/conf.d/api.conf

Integrity check FAILED: 4 change(s) found (Added: 1, Removed: 1, Modified: 2)
```

### 3. Re-baseline (Update)
After applying planned system updates, package upgrades, or authorized config changes, refresh the baseline:

```bash
./bin/fim.sh -w /etc,/usr/local/bin -b /var/lib/fim/baseline.db update
```

---

## Exit Codes

| Code | Status | Meaning |
|:---:|:---|:---|
| `0` | **Clean** | Filesystem matches the baseline exactly. |
| `1` | **Changes Found** | At least one added, deleted, or modified file was detected. |
| `2` | **Error** | Baseline missing, invalid arguments, or missing dependencies. |

---

## Configuration (`conf/fim.conf`)

Default settings can be specified in `conf/fim.conf` (or `/etc/fim/fim.conf`):

```bash
# Space or comma-delimited list of directories to monitor
WATCH_DIRS="/etc /usr/local/bin"

# Absolute path to baseline database (must reside outside WATCH_DIRS)
BASELINE_FILE="/var/lib/fim/baseline.db"

# Track file metadata changes (permissions, ownership, size, mtime)
# Set to "false" if you only want alerts on SHA-256 content changes
CHECK_METADATA="true"

# Suppress standard informational logging (useful for quiet cron runs)
QUIET="false"
```

CLI flags (`-w`, `-b`, `-c`, `-q`, `-v`) override configuration file values.

---

## Production Deployment (systemd)

To schedule automatic daily checks that stream directly into `journald`:

1. Copy the script and configuration to standard system paths:
   ```bash
   sudo cp bin/fim.sh /usr/local/bin/fim
   sudo chmod +x /usr/local/bin/fim

   sudo mkdir -p /etc/fim /var/lib/fim
   sudo cp conf/fim.conf /etc/fim/fim.conf
   sudo chmod 600 /etc/fim/fim.conf
   ```

2. Initialize the system baseline:
   ```bash
   sudo /usr/local/bin/fim --config /etc/fim/fim.conf init
   ```

3. Install and activate the systemd timer:
   ```bash
   sudo cp systemd/fim.service systemd/fim.timer /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now fim.timer
   ```

4. Verify timer status and review audit logs:
   ```bash
   # Check when the next scan will trigger
   systemctl list-timers fim.timer

   # View recent audit output from journald
   journalctl -u fim.service --no-pager -n 50
   ```

---

## Running in Docker (Read-Only Mounts)

You can run `fim` inside a container and mount host paths with the `:ro` (read-only) flag to guarantee that the checker itself cannot alter watched files:

### Build the Image
```bash
docker build -t file-integrity-checker .
```

### Initialize Baseline
```bash
docker run --rm \
  -v /etc:/watched:ro \
  -v fim_db:/var/lib/fim \
  file-integrity-checker init
```

### Run Scheduled Audit
```bash
docker run --rm \
  -v /etc:/watched:ro \
  -v fim_db:/var/lib/fim \
  file-integrity-checker check
```

---

## Testing

The project uses [Bats](https://github.com/bats-core/bats-core) to test each integrity scenario in isolation (`tests/fim.bats`).

Run the test suite:
```bash
./tests/run_tests.sh
```

The runner automatically detects whether `bats` is installed on your host. If not, it seamlessly runs the tests inside a `bats/bats:latest` container:

```text
1..8
ok 1 Init: successfully builds baseline database with correct schema
ok 2 Check: clean state exits 0 with no detected changes
ok 3 Check: detects added file and exits 1
ok 4 Check: detects removed file and exits 1
ok 5 Check: detects modified file content hash and exits 1
ok 6 Check: detects metadata (permission mode) change and exits 1
ok 7 Update: re-baselines approved changes and restores clean status
ok 8 Error: exits 2 when baseline database does not exist
```

---

## CI / Automated Checks

A GitHub Actions workflow (`.github/workflows/ci.yml`) runs on every pull request and push to `main`:
1. **ShellCheck**: Static analysis of all bash scripts (`bin/fim.sh`, `tests/run_tests.sh`).
2. **Bats Test Suite**: Full run of all change-detection test cases.
3. **Docker Build**: Verifies the production Docker container builds cleanly.
