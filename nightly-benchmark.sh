#!/bin/bash
# nightly-benchmark.sh — Nightly indexing benchmark pipeline.
#
# Usage:
#   bash nightly-benchmark.sh --workload=clickbench    # Single run with clickbench
#   bash nightly-benchmark.sh --workload=http_logs     # Single run with http_logs
#   bash nightly-benchmark.sh --workload=clickbench --nightly  # Loop mode
#
# Each run deploys a SEPARATE stack per workload (no resource overlap):
#   --workload=clickbench → stack: OpenSearchCodeGuruStack-nightly-clickbench
#   --workload=http_logs  → stack: OpenSearchCodeGuruStack-nightly-http_logs

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
REMOTE_STORE_FLAG=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --nightly) MODE_OVERRIDE="nightly"; shift ;;
    --remote) REMOTE_STORE_FLAG="true"; shift ;;
    --workload=*) WORKLOAD_OVERRIDE="${1#--workload=}"; shift ;;
    --workload) WORKLOAD_OVERRIDE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$WORKLOAD_OVERRIDE" ]; then
  echo "ERROR: --workload is required. Use --workload=clickbench or --workload=http_logs"
  exit 1
fi

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
  # 1. Read config
  load_config "$SCRIPT_DIR/nightly-config.json"

  # Override workload from CLI (required)
  export CONFIG_WORKLOAD="$WORKLOAD_OVERRIDE"

  # Remote store flag (CLI --remote) controls multi-node vs single-node path
  export REMOTE_STORE_ENABLED="${REMOTE_STORE_FLAG:-false}"

  # Set stack suffix to include workload name for isolation (sanitize for CloudFormation)
  # Add -remote suffix when remote store is enabled to keep stacks/runs separate
  if [ "$REMOTE_STORE_ENABLED" = "true" ]; then
    export NIGHTLY_STACK_SUFFIX="nightly-${CONFIG_WORKLOAD//_/-}-remote"
  else
    export NIGHTLY_STACK_SUFFIX="nightly-${CONFIG_WORKLOAD//_/-}"
  fi

  if [ -n "$MODE_OVERRIDE" ]; then
    CONFIG_MODE="$MODE_OVERRIDE"
  else
    CONFIG_MODE="adhoc"
  fi

  # 2. Acquire lock (workload + mode specific lock file so single-node and
  # --remote runs of the same workload don't collide)
  if [ "$REMOTE_STORE_ENABLED" = "true" ]; then
    LOCK_FILE="/tmp/nightly-benchmark-${CONFIG_WORKLOAD}-remote.lock"
  else
    LOCK_FILE="/tmp/nightly-benchmark-${CONFIG_WORKLOAD}.lock"
  fi
  if ! acquire_lock; then
    echo "Another ${CONFIG_WORKLOAD} run is active. Exiting."
    exit 1
  fi

  # 3. Log start
  echo "============================================"
  echo "  Nightly Benchmark"
  echo "  Mode:     $CONFIG_MODE"
  echo "  Workload: $CONFIG_WORKLOAD"
  echo "  Stack:    OpenSearchCodeGuruStack-${NIGHTLY_STACK_SUFFIX}"
  echo "============================================"

  # 4. Set trap
  TEARDOWN_NEEDED=false
  trap 'cleanup_on_exit' EXIT ERR INT TERM

  # 5. Pre-check: destroy existing stack for THIS workload
  precheck_destroy_existing

  # 6. Git pull CDK repo + clone workloads
  git_pull_cdk_repo
  ensure_workloads_cloned

  # 6c. Clean stale flag
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

  # 8. Extract IPs
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

  # 10. Run benchmark (single workload, all 3 engines)
  PQ_FAILED=false
  PQL_FAILED=false
  LU_FAILED=false

  if ! run_benchmark "$PARQUET_IP" "parquet" "$RUN_ID"; then
    echo "WARNING: Parquet ${CONFIG_WORKLOAD} benchmark failed"
    PQ_FAILED=true
  fi

  if ! run_benchmark "$PARQUET_LUCENE_IP" "parquetLucene" "$RUN_ID"; then
    echo "WARNING: ParquetLucene ${CONFIG_WORKLOAD} benchmark failed"
    PQL_FAILED=true
  fi

  if ! run_benchmark "$LUCENE_IP" "lucene" "$RUN_ID"; then
    echo "WARNING: Lucene ${CONFIG_WORKLOAD} benchmark failed"
    LU_FAILED=true
  fi

  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # 10b. Trigger data upload
  trigger_data_upload || echo "WARNING: Failed to trigger data upload"

  # 11. Store results
  if [ "$PQ_FAILED" = true ] && [ "$PQL_FAILED" = true ] && [ "$LU_FAILED" = true ]; then
    record_failure "$RUN_ID" "All engines failed (${CONFIG_WORKLOAD})"
  else
    parse_and_store_results "$RUN_ID" "$CONFIG_MODE" "$START_TIME" "$END_TIME"
  fi

  # 12. Publish CloudWatch metrics
  publish_cloudwatch_metrics "$RUN_ID"

  # 13. Generate trend chart
  csv_suffix=""
  if [ "$REMOTE_STORE_ENABLED" = "true" ]; then
    csv_suffix="-remote"
  fi
  local_csv="/tmp/indexing-throughput-${CONFIG_WORKLOAD}${csv_suffix}.csv"
  if [ -f "$local_csv" ]; then
    python3 "$SCRIPT_DIR/generate-nightly-trend.py" \
      --csv "$local_csv" \
      --output "/tmp/nightly-indexing-trend-${CONFIG_WORKLOAD}${csv_suffix}.html" \
      --workload "$CONFIG_WORKLOAD" && \
    aws s3 cp "/tmp/nightly-indexing-trend-${CONFIG_WORKLOAD}${csv_suffix}.html" \
      "s3://$CONFIG_S3_BUCKET/nightly/nightly-indexing-trend-${CONFIG_WORKLOAD}${csv_suffix}.html" || \
    echo "WARNING: Trend chart generation/upload failed"
  fi

  # 14. Do NOT teardown — next run's precheck handles it
  TEARDOWN_NEEDED=false

  # 15. Release lock
  release_lock

  # 16. Exit or sleep
  if [ "$CONFIG_MODE" = "adhoc" ]; then
    echo "Adhoc run complete (${CONFIG_WORKLOAD}). Exiting."
    exit 0
  fi

  echo "Sleeping ${CONFIG_RUN_INTERVAL_HOURS} hours..."
  sleep $((CONFIG_RUN_INTERVAL_HOURS * 3600))
done
