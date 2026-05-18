#!/bin/bash
# test-benchmark-only.sh — Minimal OSB indexing test against one engine.
#
# Usage:
#   bash test-benchmark-only.sh <ip> <engine> [workload]
#
# Example:
#   bash test-benchmark-only.sh 172.31.84.155 parquet clickbench
#   bash test-benchmark-only.sh 172.31.83.3 lucene clickbench
#   bash test-benchmark-only.sh 172.31.86.81 parquetLucene http_logs

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: bash test-benchmark-only.sh <ip> <engine> [workload]"
  echo "  engine:   parquet, parquetLucene, or lucene"
  echo "  workload: clickbench (default) or http_logs"
  exit 1
fi

HOST="$1"
ENGINE="$2"
WORKLOAD="${3:-clickbench}"

if [ "$ENGINE" = "parquet" ]; then
  WORKLOAD_PATH="$HOME/parquet-workloads/${WORKLOAD}"
  BULK_CLIENTS=50
elif [ "$ENGINE" = "parquetLucene" ]; then
  WORKLOAD_PATH="$HOME/parquetLucene-workloads/${WORKLOAD}"
  BULK_CLIENTS=50
elif [ "$ENGINE" = "lucene" ]; then
  WORKLOAD_PATH="$HOME/lucene-workloads/${WORKLOAD}"
  BULK_CLIENTS=8
else
  echo "Unknown engine: $ENGINE (use parquet, parquetLucene, or lucene)"
  exit 1
fi

if [ "$WORKLOAD" = "clickbench" ]; then
  if [ "$ENGINE" = "lucene" ]; then
    TEST_PROC="dsl-clickbench"
  else
    TEST_PROC="datafusion-ppl"
  fi
  INCLUDE_TASKS="delete-index,create-index,index-append"
elif [ "$WORKLOAD" = "http_logs" ]; then
  TEST_PROC="append-no-conflicts-index-only"
  INCLUDE_TASKS="delete-index,create-index,index-append"
else
  echo "Unknown workload: $WORKLOAD (use clickbench or http_logs)"
  exit 1
fi

RESULTS="/tmp/nightly-result-${ENGINE}-${WORKLOAD}.csv"

echo "Host:       $HOST"
echo "Engine:     $ENGINE"
echo "Workload:   $WORKLOAD"
echo "Procedure:  $TEST_PROC"
echo "Path:       $WORKLOAD_PATH"
echo "Tasks:      $INCLUDE_TASKS"
echo "Clients:    $BULK_CLIENTS"
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
  --include-tasks="$INCLUDE_TASKS" \
  --workload-params="{\"ingest_percentage\": 100, \"number_of_replicas\": 0, \"bulk_indexing_clients\": ${BULK_CLIENTS}}"

echo ""
echo "Done. Results: $RESULTS"
