#!/bin/bash
# Lock file management — prevents concurrent runs

LOCK_FILE="$HOME/nightly-benchmark.lock"

acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(grep "^PID=" "$LOCK_FILE" | cut -d= -f2)

    # Check if the PID is still running
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "Run already active (PID: $lock_pid)"
      return 1
    fi

    # Stale lock — remove it
    echo "Removing stale lock (PID $lock_pid not running)"
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
  rm -f "$LOCK_FILE"
}
