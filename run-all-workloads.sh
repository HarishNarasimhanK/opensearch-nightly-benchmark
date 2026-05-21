#!/bin/bash
# run-all-workloads.sh — Orchestrator that runs nightly-benchmark.sh for each
# workload + cluster mode combination sequentially.
#
# Usage:
#   bash run-all-workloads.sh                # All 4: clickbench, http_logs, clickbench-remote, http_logs-remote
#   bash run-all-workloads.sh --nightly      # Same 4, but loops (sleep + repeat)
#   bash run-all-workloads.sh --remote-only  # Only remote variants (clickbench-remote, http_logs-remote)
#   bash run-all-workloads.sh --no-remote    # Only single-node variants (clickbench, http_logs)
#
# Each combination gets its own CDK stack, instances, and S3 paths. Zero overlap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"

MODE=""
RUN_REMOTE="true"
RUN_NO_REMOTE="true"
for arg in "$@"; do
  case "$arg" in
    --nightly) MODE="--nightly" ;;
    --remote-only) RUN_NO_REMOTE="false"; RUN_REMOTE="true" ;;
    --no-remote) RUN_REMOTE="false"; RUN_NO_REMOTE="true" ;;
  esac
done

WORKLOADS=("clickbench" "http_logs")

# Build the run list: each entry is "WORKLOAD|REMOTE_FLAG"
RUNS=()
if [ "$RUN_NO_REMOTE" = "true" ]; then
  for w in "${WORKLOADS[@]}"; do RUNS+=("${w}|"); done
fi
if [ "$RUN_REMOTE" = "true" ]; then
  for w in "${WORKLOADS[@]}"; do RUNS+=("${w}|--remote"); done
fi

while true; do
  load_config "$SCRIPT_DIR/nightly-config.json"

  for ENTRY in "${RUNS[@]}"; do
    WORKLOAD="${ENTRY%%|*}"
    REMOTE_FLAG="${ENTRY##*|}"

    SUFFIX=""
    if [ "$REMOTE_FLAG" = "--remote" ]; then
      SUFFIX="-remote"
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Running workload: ${WORKLOAD}${SUFFIX}"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Stack:      OpenSearchCodeGuruStack-nightly-${WORKLOAD//_/-}${SUFFIX}"
    echo "║  Log file:   ~/nightly-adhoc-${WORKLOAD}${SUFFIX}.log"
    echo "║  CW prefix:  /opensearch/nightly-${WORKLOAD}${SUFFIX}/"
    echo "║  S3 CSV:     s3://${CONFIG_S3_BUCKET}/nightly/indexing-throughput-${WORKLOAD}${SUFFIX}.csv"
    echo "║  S3 HTML:    s3://${CONFIG_S3_BUCKET}/nightly/nightly-indexing-trend-${WORKLOAD}${SUFFIX}.html"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "CMD: bash nightly-benchmark.sh --workload=${WORKLOAD} ${REMOTE_FLAG}"
    echo ""

    bash "$SCRIPT_DIR/nightly-benchmark.sh" --workload="$WORKLOAD" $REMOTE_FLAG 2>&1 | tee "$HOME/nightly-adhoc-${WORKLOAD}${SUFFIX}.log"
    EXIT_CODE=${PIPESTATUS[0]}

    if [ $EXIT_CODE -ne 0 ]; then
      echo "WARNING: ${WORKLOAD}${SUFFIX} run failed (exit code: $EXIT_CODE). Continuing to next."
    fi
  done

  if [ -z "$MODE" ]; then
    echo "All runs complete. Generating report..."

    # Generate AI report and post to Slack
    python3 "$SCRIPT_DIR/generate-report.py" \
      --bucket "$CONFIG_S3_BUCKET" \
      --slack-webhook "${SLACK_WEBHOOK_URL:-}" \
      --output "/tmp/nightly-report-$(date -u +%Y%m%d).md" \
      || echo "WARNING: Report generation failed"

    echo "Done. Exiting."
    exit 0
  fi

  echo "All runs complete. Sleeping ${CONFIG_RUN_INTERVAL_HOURS} hours..."
  sleep $((CONFIG_RUN_INTERVAL_HOURS * 3600))
done
