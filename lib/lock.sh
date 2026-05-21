#!/bin/bash
# Lock file management — prevents concurrent runs.
#
# LOCK_FILE is intentionally NOT set here; the caller (nightly-benchmark.sh)
# computes it after CONFIG_WORKLOAD and REMOTE_STORE_ENABLED are resolved so
# the lock is keyed on (workload, mode) and a single-node + remote run for the
# same workload do not collide.

acquire_lock() {
  if [ -z "${LOCK_FILE:-}" ]; then
    echo "ERROR: LOCK_FILE not set before acquire_lock"
    return 1
  fi

  if [ -f "$LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(grep "^PID=" "$LOCK_FILE" | cut -d= -f2)

    # Check if the PID is still running
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "Run already active (PID: $lock_pid, lock: $LOCK_FILE)"
      return 1
    fi

    # Stale lock — remove it
    echo "Removing stale lock $LOCK_FILE (PID $lock_pid not running)"
    rm -f "$LOCK_FILE"
  fi

  # Write lock
  cat > "$LOCK_FILE" << EOF
PID=$$
START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_ID=${RUN_ID:-unknown}
EOF
  return 0
}

release_lock() {
  if [ -n "${LOCK_FILE:-}" ]; then
    rm -f "$LOCK_FILE"
  fi
}
