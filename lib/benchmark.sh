#!/bin/bash
# OSB indexing benchmark execution

# Ensure pip --user binaries (opensearch-benchmark) are in PATH
export PATH="$HOME/.local/bin:$PATH"

ensure_workloads_cloned() {
  local pq_repo="${CONFIG_PARQUET_WORKLOAD_REPO:-https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git}"
  local pq_branch="${CONFIG_PARQUET_WORKLOAD_BRANCH:-parquet}"
  local pql_repo="${CONFIG_PARQUET_LUCENE_WORKLOAD_REPO:-https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git}"
  local pql_branch="${CONFIG_PARQUET_LUCENE_WORKLOAD_BRANCH:-indexed_parquet}"
  local lu_repo="${CONFIG_LUCENE_WORKLOAD_REPO:-https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git}"
  local lu_branch="${CONFIG_LUCENE_WORKLOAD_BRANCH:-lucene}"

  rm -rf "$HOME/parquet-workloads"
  echo "Cloning workloads for parquet: ${pq_repo}@${pq_branch}..."
  git clone "$pq_repo" -b "$pq_branch" "$HOME/parquet-workloads"

  rm -rf "$HOME/parquetLucene-workloads"
  echo "Cloning workloads for parquetLucene: ${pql_repo}@${pql_branch}..."
  git clone "$pql_repo" -b "$pql_branch" "$HOME/parquetLucene-workloads"

  rm -rf "$HOME/lucene-workloads"
  echo "Cloning workloads for lucene: ${lu_repo}@${lu_branch}..."
  git clone "$lu_repo" -b "$lu_branch" "$HOME/lucene-workloads"
}

wait_for_health() {
  local host="$1"
  local engine="$2"
  local max_attempts=999999

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

  echo "ERROR: $engine cluster did not become healthy"
  return 1
}

# Unified benchmark function
run_benchmark() {
  local host="$1"
  local engine="$2"
  local run_id="$3"
  local workload="${CONFIG_WORKLOAD:-clickbench}"

  local test_procedure workload_path bulk_clients include_tasks

  # Determine workload path based on engine and workload type
  if [ "$engine" = "parquet" ]; then
    workload_path="$HOME/parquet-workloads/${workload}"
    bulk_clients=50
  elif [ "$engine" = "parquetLucene" ]; then
    workload_path="$HOME/parquetLucene-workloads/${workload}"
    bulk_clients=50
  else
    workload_path="$HOME/lucene-workloads/${workload}"
    bulk_clients=8
  fi

  # Determine test procedure based on workload and engine
  if [ "$workload" = "clickbench" ]; then
    if [ "$engine" = "lucene" ]; then
      test_procedure="dsl-clickbench"
    else
      test_procedure="datafusion-ppl"
    fi
    include_tasks="delete-index,create-index,index-append"
  elif [ "$workload" = "http_logs" ]; then
    test_procedure="append-no-conflicts-index-only"
    include_tasks="delete-index,create-index,index-append"
  else
    echo "ERROR: Unknown workload: $workload"
    return 1
  fi

  local results_file="/tmp/nightly-result-${engine}-${workload}.csv"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  BENCHMARK: ${engine} / ${workload}"
  echo "╠══════════════════════════════════════════════════════════════════╣"
  echo "║  Host:           ${host}:9200"
  echo "║  Test Procedure: ${test_procedure}"
  echo "║  Workload Path:  ${workload_path}"
  echo "║  Bulk Clients:   ${bulk_clients}"
  echo "║  Include Tasks:  ${include_tasks}"
  echo "║  Ingest %:       ${CONFIG_INGEST_PERCENTAGE}"
  echo "║  Results File:   ${results_file}"
  echo "╚══════════════════════════════════════════════════════════════════╝"

  # --- PRE-BENCHMARK: Show opensearch.yml config ---
  echo ""
  echo "──────────────────────────────────────────────────────────────────"
  echo "  [PRE] OpenSearch Configuration (opensearch.yml via API)"
  echo "──────────────────────────────────────────────────────────────────"
  curl -s "http://${host}:9200/_cluster/settings?include_defaults=true&flat_settings=true&pretty" 2>/dev/null | grep -E "cluster.name|node.name|discovery|network|pluggable|composite|parquet" | head -20
  echo ""

  # --- PRE-BENCHMARK: Cluster health ---
  echo "──────────────────────────────────────────────────────────────────"
  echo "  [PRE] Cluster Health"
  echo "──────────────────────────────────────────────────────────────────"
  curl -s "http://${host}:9200/_cluster/health?pretty" 2>/dev/null
  echo ""

  # --- RUN OSB ---
  echo "──────────────────────────────────────────────────────────────────"
  echo "  [RUN] opensearch-benchmark"
  echo "──────────────────────────────────────────────────────────────────"
  echo "CMD: opensearch-benchmark run \\"
  echo "  --pipeline=benchmark-only \\"
  echo "  --workload-path=\"${workload_path}\" \\"
  echo "  --target-hosts=\"${host}:9200\" \\"
  echo "  --test-procedure=\"${test_procedure}\" \\"
  echo "  --include-tasks=\"${include_tasks}\" \\"
  echo "  --kill-running-processes \\"
  echo "  --results-format=csv \\"
  echo "  --results-file=\"${results_file}\" \\"
  echo "  --workload-params='{\"ingest_percentage\": ${CONFIG_INGEST_PERCENTAGE}, \"number_of_replicas\": 0, \"bulk_indexing_clients\": ${bulk_clients}}'"
  echo ""

  opensearch-benchmark run \
    --pipeline=benchmark-only \
    --workload-path="$workload_path" \
    --target-hosts="${host}:9200" \
    --test-procedure="$test_procedure" \
    --include-tasks="$include_tasks" \
    --kill-running-processes \
    --results-format=csv \
    --results-file="$results_file" \
    --workload-params="{\"ingest_percentage\": ${CONFIG_INGEST_PERCENTAGE}, \"number_of_replicas\": 0, \"bulk_indexing_clients\": ${bulk_clients}, \"distribution_version\": \"3.7.0\"}"

  local exit_code=$?

  # --- POST-BENCHMARK: Cluster health ---
  echo ""
  echo "──────────────────────────────────────────────────────────────────"
  echo "  [POST] Cluster Health"
  echo "──────────────────────────────────────────────────────────────────"
  curl -s "http://${host}:9200/_cluster/health?pretty" 2>/dev/null
  echo ""

  # --- POST-BENCHMARK: Index settings ---
  echo "──────────────────────────────────────────────────────────────────"
  echo "  [POST] Index Settings"
  echo "──────────────────────────────────────────────────────────────────"
  curl -s "http://${host}:9200/_all/_settings?pretty" 2>/dev/null | head -60
  echo ""

  # --- POST-BENCHMARK: _cat/indices ---
  echo "──────────────────────────────────────────────────────────────────"
  echo "  [POST] _cat/indices"
  echo "──────────────────────────────────────────────────────────────────"
  curl -s "http://${host}:9200/_cat/indices?v" 2>/dev/null
  echo ""

  # --- Result ---
  echo "══════════════════════════════════════════════════════════════════"
  if [ $exit_code -eq 0 ]; then
    echo "  ✅ ${engine} ${workload} benchmark PASSED"
  else
    echo "  ❌ ${engine} ${workload} benchmark FAILED (exit code: $exit_code)"
  fi
  echo "══════════════════════════════════════════════════════════════════"
  echo ""

  return $exit_code
}

trigger_data_upload() {
  echo "Triggering data folder upload on all instances..."
  echo "BENCHMARK_COMPLETE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | \
    aws s3 cp - "s3://${CONFIG_S3_BUCKET}/flags/BENCHMARK_COMPLETE"
  echo "Flag written → s3://${CONFIG_S3_BUCKET}/flags/BENCHMARK_COMPLETE"
}
