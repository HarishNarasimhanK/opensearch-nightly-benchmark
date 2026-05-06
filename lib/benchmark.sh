#!/bin/bash
# OSB indexing benchmark execution
#
# Prerequisites on the nightly instance:
#   git clone https://github.com/AjayRajNelapudi/opensearch-benchmark-workloads.git -b indexing ~/datafusion-workloads
#   git clone https://github.com/AjayRajNelapudi/opensearch-benchmark-workloads.git -b indexing ~/lucene-workloads

DATAFUSION_WORKLOAD_REPO="https://github.com/AjayRajNelapudi/opensearch-benchmark-workloads.git"
DATAFUSION_WORKLOAD_BRANCH="main-benchmark"
LUCENE_WORKLOAD_REPO="https://github.com/opensearch-project/opensearch-benchmark-workloads.git"
LUCENE_WORKLOAD_BRANCH="main"

ensure_workloads_cloned() {
  if [ ! -d "$HOME/datafusion-workloads/clickbench" ]; then
    echo "Cloning workloads for datafusion..."
    git clone "$DATAFUSION_WORKLOAD_REPO" -b "$DATAFUSION_WORKLOAD_BRANCH" "$HOME/datafusion-workloads"
  else
    git -C "$HOME/datafusion-workloads" pull --ff-only 2>/dev/null || true
  fi

  if [ ! -d "$HOME/lucene-workloads/clickbench" ]; then
    echo "Cloning workloads for lucene..."
    git clone "$LUCENE_WORKLOAD_REPO" -b "$LUCENE_WORKLOAD_BRANCH" "$HOME/lucene-workloads"
  else
    git -C "$HOME/lucene-workloads" pull --ff-only 2>/dev/null || true
  fi
}

wait_for_health() {
  local host="$1"
  local engine="$2"
  local max_attempts=240  # 120 minutes at 30s intervals

  echo "Waiting for $engine cluster health at $host:9200..."
  for i in $(seq 1 $max_attempts); do
    local status
    status=$(curl -s "http://${host}:9200/_cluster/health" 2>/dev/null | \
      jq -r '.status // empty' 2>/dev/null || echo "")

    if [ "$status" = "green" ]; then
      echo "$engine cluster health is green (attempt $i)!"
      return 0
    fi

    if [ $((i % 20)) -eq 0 ]; then
      echo "  $engine status: ${status:-unreachable} (attempt $i/$max_attempts)"
    fi
    sleep 30
  done

  echo "ERROR: $engine cluster did not become healthy within 120 minutes"
  return 1
}

run_indexing_benchmark() {
  local host="$1"
  local engine="$2"
  local run_id="$3"

  local test_procedure workload_path
  if [ "$engine" = "datafusion" ]; then
    test_procedure="datafusion-ppl"
    workload_path="$HOME/datafusion-workloads/clickbench"
  else
    test_procedure="dsl-clickbench"
    workload_path="$HOME/lucene-workloads/clickbench"
  fi

  local results_file="/tmp/nightly-result-${engine}.csv"

  echo "Running indexing benchmark against $engine ($host:9200)..."
  echo "  Test procedure: $test_procedure"
  echo "  Workload: $workload_path"
  echo "  Include tasks: index-append"

  opensearch-benchmark run \
    --pipeline=benchmark-only \
    --workload-path="$workload_path" \
    --target-hosts="${host}:9200" \
    --test-procedure="$test_procedure" \
    --include-tasks="index-append" \
    --kill-running-processes \
    --results-format=csv \
    --results-file="$results_file"

  local exit_code=$?
  if [ $exit_code -eq 0 ]; then
    echo "$engine benchmark completed successfully."
  else
    echo "ERROR: $engine benchmark failed (exit code: $exit_code)"
  fi
  return $exit_code
}
