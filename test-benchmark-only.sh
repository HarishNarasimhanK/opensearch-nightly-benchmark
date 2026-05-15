#!/bin/bash
# test-benchmark-only.sh — Minimal OSB indexing test against one engine.
#
# Usage:
#   bash test-benchmark-only.sh <ip> <engine>
#
# Example:
#   bash test-benchmark-only.sh 172.31.84.155 parquet
#   bash test-benchmark-only.sh 172.31.83.3 lucene

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: bash test-benchmark-only.sh <ip> <engine>"
  echo "  engine: parquet or lucene"
  exit 1
fi

HOST="$1"
ENGINE="$2"

if [ "$ENGINE" = "parquet" ]; then
  WORKLOAD_PATH="$HOME/parquet-workloads/clickbench"
  TEST_PROC="datafusion-ppl"
elif [ "$ENGINE" = "lucene" ]; then
  WORKLOAD_PATH="$HOME/lucene-workloads/clickbench"
  TEST_PROC="dsl-clickbench"
else
  echo "Unknown engine: $ENGINE (use parquet or lucene)"
  exit 1
fi

RESULTS="/tmp/nightly-result-${ENGINE}.csv"

echo "Host:       $HOST"
echo "Engine:     $ENGINE"
echo "Procedure:  $TEST_PROC"
echo "Workload:   $WORKLOAD_PATH"
echo "Output:     $RESULTS"
echo ""

opensearch-benchmark run \
  --pipeline="benchmark-only" \
  --workload-path="$WORKLOAD_PATH" \
  --target-hosts="${HOST}:9200" \
  --test-procedure="$TEST_PROC" \
  --kill-running-processes \
  --results-format=csv \
  --results-file="$RESULTS" \
  --include-tasks="index-append"

echo ""
echo "Done. Results:"
cat "$RESULTS"
