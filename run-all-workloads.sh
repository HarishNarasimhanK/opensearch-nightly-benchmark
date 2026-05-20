#!/bin/bash
# run-all-workloads.sh — Orchestrator that runs nightly-benchmark.sh for each workload sequentially.
#
# Usage:
#   bash run-all-workloads.sh           # Adhoc: run clickbench then http_logs, exit
#   bash run-all-workloads.sh --nightly # Loop: run both workloads, sleep, repeat
#
# Each workload gets its own CDK stack, instances, and S3 paths. Zero overlap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/config.sh"

MODE=""
if [[ "${1:-}" == "--nightly" ]]; then
  MODE="--nightly"
fi

WORKLOADS=("clickbench" "http_logs")

while true; do
  load_config "$SCRIPT_DIR/nightly-config.json"

  for WORKLOAD in "${WORKLOADS[@]}"; do
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Running workload: ${WORKLOAD}"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Stack:      OpenSearchCodeGuruStack-nightly-${WORKLOAD}"
    echo "║  Log file:   ~/nightly-adhoc-${WORKLOAD}.log"
    echo "║  CW prefix:  /opensearch/nightly-${WORKLOAD}/"
    echo "║  S3 CSV:     s3://${CONFIG_S3_BUCKET}/nightly/indexing-throughput-${WORKLOAD}.csv"
    echo "║  S3 HTML:    s3://${CONFIG_S3_BUCKET}/nightly/nightly-indexing-trend-${WORKLOAD}.html"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "CMD: bash nightly-benchmark.sh --workload=${WORKLOAD}"
    echo ""

    bash "$SCRIPT_DIR/nightly-benchmark.sh" --workload="$WORKLOAD" 2>&1 | tee "$HOME/nightly-adhoc-${WORKLOAD}.log"
    EXIT_CODE=${PIPESTATUS[0]}

    if [ $EXIT_CODE -ne 0 ]; then
      echo "WARNING: ${WORKLOAD} run failed (exit code: $EXIT_CODE). Continuing to next workload."
    fi
  done

  if [ -z "$MODE" ]; then
    echo "All workloads complete. Generating report..."

    # Generate AI report and post to Slack
    python3 "$SCRIPT_DIR/generate-report.py" \
      --bucket "$CONFIG_S3_BUCKET" \
      --slack-webhook "${SLACK_WEBHOOK_URL:-}" \
      --output "/tmp/nightly-report-$(date -u +%Y%m%d).md" \
      || echo "WARNING: Report generation failed"

    echo "Done. Exiting."
    exit 0
  fi

  echo "All workloads complete. Sleeping ${CONFIG_RUN_INTERVAL_HOURS} hours..."
  sleep $((CONFIG_RUN_INTERVAL_HOURS * 3600))
done
