#!/bin/bash
# nightly-benchmark.sh — Main orchestration script for the nightly indexing benchmark pipeline.
#
# Usage:
#   bash nightly-benchmark.sh           # Adhoc mode (single run, then exit)
#   bash nightly-benchmark.sh --nightly # Nightly mode (loop with sleep interval)

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
while [[ $# -gt 0 ]]; do
  case $1 in
    --nightly) MODE_OVERRIDE="nightly"; shift ;;
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
  echo "Starting run (mode: $CONFIG_MODE)"
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

  # 6c. Clean stale BENCHMARK_COMPLETE flag from previous runs (otherwise upload-data-on-complete
  #     pollers on the new instances would fire immediately on stale flag)
  aws s3 rm "s3://${CONFIG_S3_BUCKET}/flags/BENCHMARK_COMPLETE" 2>/dev/null || true

  # 7. Deploy CDK stack
  TEARDOWN_NEEDED=true
  START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if ! deploy_cdk_stack "$RUN_ID"; then
    record_failure "$RUN_ID" "CDK deploy failed"
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
  if ! wait_for_health "$DATAFUSION_IP" "datafusion"; then
    record_failure "$RUN_ID" "Health check timeout: datafusion"
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

  # 10. Run OSB indexing benchmark (both engines)
  DF_FAILED=false
  LU_FAILED=false

  if ! run_indexing_benchmark "$DATAFUSION_IP" "datafusion" "$RUN_ID"; then
    echo "WARNING: DataFusion benchmark failed"
    DF_FAILED=true
  fi

  if ! run_indexing_benchmark "$LUCENE_IP" "lucene" "$RUN_ID"; then
    echo "WARNING: Lucene benchmark failed"
    LU_FAILED=true
  fi

  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # 10b. Trigger data folder upload (writes BENCHMARK_COMPLETE flag → poller on each instance uploads data)
  if [ "$DF_FAILED" = false ] || [ "$LU_FAILED" = false ]; then
    trigger_data_upload || echo "WARNING: Failed to trigger data upload"
  fi

  # 11. Parse results + store
  if [ "$DF_FAILED" = true ] && [ "$LU_FAILED" = true ]; then
    record_failure "$RUN_ID" "Both engines failed"
  else
    parse_and_store_results "$RUN_ID" "$CONFIG_MODE" "$START_TIME" "$END_TIME"
  fi

  # 12. Publish CloudWatch metrics
  publish_cloudwatch_metrics "$RUN_ID"

  # 13. Generate + upload trend chart
  local_csv="/tmp/indexing-throughput.csv"
  if [ -f "$local_csv" ]; then
    python3 "$SCRIPT_DIR/generate-nightly-trend.py" \
      --csv "$local_csv" \
      --output "/tmp/nightly-indexing-trend.html" && \
    aws s3 cp "/tmp/nightly-indexing-trend.html" \
      "s3://$CONFIG_S3_BUCKET/nightly/nightly-indexing-trend.html" || \
    echo "WARNING: Trend chart generation/upload failed"
  fi

  # 14. NOTE: We do NOT teardown here. The next run's precheck_destroy_existing (step 5) will
  #     destroy the previous run's stack. This gives the upload-data-on-complete pollers running
  #     on each instance plenty of time (until the next run) to finish uploading data folders to S3.
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
