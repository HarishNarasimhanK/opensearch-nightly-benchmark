#!/bin/bash
# nightly-benchmark.sh — Main orchestration script for the nightly indexing benchmark pipeline.
#
# Usage:
#   bash nightly-benchmark.sh           # Adhoc mode (single run, then exit)
#   bash nightly-benchmark.sh --nightly # Nightly mode (loop with sleep interval)
#
# Workload selection is controlled by nightly-config.json "workload" field:
#   "clickbench" — ClickBench dataset (100M docs, analytics queries)
#   "http_logs"  — HTTP logs dataset (append-only, no delete)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/lock.sh"
source "$SCRIPT_DIR/lib/deploy.sh"
source "$SCRIPT_DIR/lib/benchmark.sh"
source "$SCRIPT_DIR/lib/results.sh"
source "$SCRIPT_DIR/lib/metrics.sh"
source "$SCRIPT_DIR/lib/teardown.sh"

# --- Parse CLI args ---
MODE_OVERRIDE=""
WORKLOAD_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --nightly) MODE_OVERRIDE="nightly"; shift ;;
    --workload=*) WORKLOAD_OVERRIDE="${1#--workload=}"; shift ;;
    --workload) WORKLOAD_OVERRIDE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Cleanup function (trap) ---
cleanup_on_exit() {
  local exit_code=$?
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Cleanup triggered (exit code: $exit_code)"

  if [ "$TEARDOWN_NEEDED" = true ]; then
    teardown_stack || true
  fi

  release_lock
}

# --- Main loop ---
while true; do
  # 1. Read config (re-read each iteration for hot-reload)
  load_config "$SCRIPT_DIR/nightly-config.json"

  # Override mode if --nightly was passed
  if [ -n "$MODE_OVERRIDE" ]; then
    CONFIG_MODE="$MODE_OVERRIDE"
  else
    CONFIG_MODE="adhoc"
  fi

  # 2. Acquire lock
  if ! acquire_lock; then
    echo "Another run is active. Exiting."
    exit 1
  fi

  # 3. Log start
  echo "============================================"
  echo "Starting run (mode: $CONFIG_MODE, workload: $CONFIG_WORKLOAD)"
  echo "============================================"

  # 4. Set trap for cleanup
  TEARDOWN_NEEDED=false
  trap 'cleanup_on_exit' EXIT ERR INT TERM

  # 5. Pre-check: destroy existing stack
  precheck_destroy_existing

  # 6. Git pull CDK repo
  git_pull_cdk_repo

  # 6b. Ensure workloads are cloned
  ensure_workloads_cloned

  # 6c. Clean stale BENCHMARK_COMPLETE flag
  aws s3 rm "s3://${CONFIG_S3_BUCKET}/flags/BENCHMARK_COMPLETE" 2>/dev/null || true

  # 7. Deploy CDK stack
  TEARDOWN_NEEDED=true
  START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if ! deploy_cdk_stack; then
    record_failure "${RUN_ID:-unknown}" "CDK deploy failed"
    teardown_stack || true
    TEARDOWN_NEEDED=false
    release_lock
    if [ "$CONFIG_MODE" = "adhoc" ]; then exit 1; fi
    echo "Sleeping ${CONFIG_RUN_INTERVAL_HOURS} hours before retry..."
    sleep $((CONFIG_RUN_INTERVAL_HOURS * 3600))
    continue
  fi

  # 8. Extract IPs from outputs
  if ! parse_cdk_outputs; then
    record_failure "$RUN_ID" "Failed to parse CDK outputs"
    teardown_stack || true
    TEARDOWN_NEEDED=false
    release_lock
    if [ "$CONFIG_MODE" = "adhoc" ]; then exit 1; fi
    sleep $((CONFIG_RUN_INTERVAL_HOURS * 3600))
    continue
  fi

  # 9. Wait for cluster health
  if ! wait_for_health "$PARQUET_IP" "parquet"; then
    record_failure "$RUN_ID" "Health check timeout: parquet"
    teardown_stack || true
    TEARDOWN_NEEDED=false
    release_lock
    if [ "$CONFIG_MODE" = "adhoc" ]; then exit 1; fi
    sleep $((CONFIG_RUN_INTERVAL_HOURS * 3600))
    continue
  fi

  if ! wait_for_health "$LUCENE_IP" "lucene"; then
    record_failure "$RUN_ID" "Health check timeout: lucene"
    teardown_stack || true
    TEARDOWN_NEEDED=false
    release_lock
    if [ "$CONFIG_MODE" = "adhoc" ]; then exit 1; fi
    sleep $((CONFIG_RUN_INTERVAL_HOURS * 3600))
    continue
  fi

  if ! wait_for_health "$PARQUET_LUCENE_IP" "parquetLucene"; then
    record_failure "$RUN_ID" "Health check timeout: parquetLucene"
    teardown_stack || true
    TEARDOWN_NEEDED=false
    release_lock
    if [ "$CONFIG_MODE" = "adhoc" ]; then exit 1; fi
    sleep $((CONFIG_RUN_INTERVAL_HOURS * 3600))
    continue
  fi

  # 10. Run benchmark for each workload
  # If --workload= was passed, run only that one. Otherwise run all from config.
  if [ -n "$WORKLOAD_OVERRIDE" ]; then
    WORKLOADS_TO_RUN="$WORKLOAD_OVERRIDE"
  else
    WORKLOADS_TO_RUN="$CONFIG_WORKLOAD"
  fi

  IFS=',' read -ra WORKLOAD_LIST <<< "$WORKLOADS_TO_RUN"

  for CURRENT_WORKLOAD in "${WORKLOAD_LIST[@]}"; do
    CURRENT_WORKLOAD=$(echo "$CURRENT_WORKLOAD" | xargs)  # trim whitespace
    export CONFIG_WORKLOAD="$CURRENT_WORKLOAD"

    echo ""
    echo ">>> Running ${CURRENT_WORKLOAD} benchmark on all engines..."

    PQ_FAILED=false
    PQL_FAILED=false
    LU_FAILED=false

    if ! run_benchmark "$PARQUET_IP" "parquet" "$RUN_ID"; then
      echo "WARNING: Parquet ${CURRENT_WORKLOAD} benchmark failed"
      PQ_FAILED=true
    fi

    if ! run_benchmark "$PARQUET_LUCENE_IP" "parquetLucene" "$RUN_ID"; then
      echo "WARNING: ParquetLucene ${CURRENT_WORKLOAD} benchmark failed"
      PQL_FAILED=true
    fi

    if ! run_benchmark "$LUCENE_IP" "lucene" "$RUN_ID"; then
      echo "WARNING: Lucene ${CURRENT_WORKLOAD} benchmark failed"
      LU_FAILED=true
    fi

    # Store results for this workload
    if [ "$PQ_FAILED" = true ] && [ "$PQL_FAILED" = true ] && [ "$LU_FAILED" = true ]; then
      record_failure "$RUN_ID" "All engines failed (${CURRENT_WORKLOAD})"
    else
      parse_and_store_results "$RUN_ID" "$CONFIG_MODE" "$START_TIME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi

    # Generate trend chart for this workload
    local_csv="/tmp/indexing-throughput-${CURRENT_WORKLOAD}.csv"
    if [ -f "$local_csv" ]; then
      python3 "$SCRIPT_DIR/generate-nightly-trend.py" \
        --csv "$local_csv" \
        --output "/tmp/nightly-indexing-trend-${CURRENT_WORKLOAD}.html" \
        --workload "$CURRENT_WORKLOAD" && \
      aws s3 cp "/tmp/nightly-indexing-trend-${CURRENT_WORKLOAD}.html" \
        "s3://$CONFIG_S3_BUCKET/nightly/nightly-indexing-trend-${CURRENT_WORKLOAD}.html" || \
      echo "WARNING: Trend chart generation/upload failed for ${CURRENT_WORKLOAD}"
    fi
  done

  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # 10b. Trigger data folder upload
  trigger_data_upload || echo "WARNING: Failed to trigger data upload"

  # 11. Publish CloudWatch metrics
  publish_cloudwatch_metrics "$RUN_ID"

  # 14. Do NOT teardown — next run's precheck_destroy_existing handles it
  TEARDOWN_NEEDED=false

  # 15. Release lock
  release_lock

  # 16. Exit or sleep
  if [ "$CONFIG_MODE" = "adhoc" ]; then
    echo "Adhoc run complete. Exiting."
    exit 0
  fi

  echo "Sleeping ${CONFIG_RUN_INTERVAL_HOURS} hours..."
  sleep $((CONFIG_RUN_INTERVAL_HOURS * 3600))
done
