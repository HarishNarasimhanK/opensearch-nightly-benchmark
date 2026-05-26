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
  local max_attempts=240  # 240 × 30s = 2 hours

  echo "Waiting for $engine cluster health at $host:9200 (timeout: 2h)..."
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

  # Ensure we're in a valid directory (cdk-repo may have been deleted)
  cd "$HOME"

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
    bulk_clients=50
  fi

  # Determine test procedure based on workload and engine
  if [ "$workload" = "clickbench" ]; then
    if [ "$engine" = "lucene" ]; then
      test_procedure="dsl-clickbench"
    else
      test_procedure="datafusion-ppl"
    fi
    include_tasks="delete-index,create-index,check-cluster-health,index-append,refresh-after-index,force-merge,refresh-after-force-merge,wait-until-merges-finish"
  elif [ "$workload" = "http_logs" ]; then
    test_procedure="append-no-conflicts-index-only"
    include_tasks="delete-index,create-index,check-cluster-health,index-append,refresh-after-index,force-merge,refresh-after-force-merge,wait-until-merges-finish"
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
  if [ "${REMOTE_STORE_ENABLED:-false}" = "true" ]; then
  echo "║  Shards:         ${CONFIG_NUMBER_OF_SHARDS:-1}"
  echo "║  Replicas:       ${CONFIG_NUMBER_OF_REPLICAS:-0}"
  echo "║  Replication:    SEGMENT (auto, via cluster-level remote store)"
  fi
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

  # --- RUN OSB (4 iterations: 1 warmup + 3 measured) ---
  echo "──────────────────────────────────────────────────────────────────"
  echo "  [RUN] opensearch-benchmark (1 warmup + 3 measured iterations)"
  echo "──────────────────────────────────────────────────────────────────"
  # Build workload-params based on remote store flag
  local workload_params
  if [ "${REMOTE_STORE_ENABLED:-false}" = "true" ]; then
    workload_params="{\"ingest_percentage\": ${CONFIG_INGEST_PERCENTAGE}, \"number_of_shards\": ${CONFIG_NUMBER_OF_SHARDS:-1}, \"number_of_replicas\": ${CONFIG_NUMBER_OF_REPLICAS:-0}, \"bulk_indexing_clients\": ${bulk_clients}}"
  else
    workload_params="{\"ingest_percentage\": ${CONFIG_INGEST_PERCENTAGE}, \"number_of_replicas\": 0, \"bulk_indexing_clients\": ${bulk_clients}}"
  fi

  # Warmup params: 10% of configured ingest to warm JVM/cache without full run time
  local warmup_ingest=$(echo "${CONFIG_INGEST_PERCENTAGE} * 0.1" | bc -l | awk '{printf "%.2f", $0}')
  local warmup_params
  if [ "${REMOTE_STORE_ENABLED:-false}" = "true" ]; then
    warmup_params="{\"ingest_percentage\": ${warmup_ingest}, \"number_of_shards\": ${CONFIG_NUMBER_OF_SHARDS:-1}, \"number_of_replicas\": ${CONFIG_NUMBER_OF_REPLICAS:-0}, \"bulk_indexing_clients\": ${bulk_clients}}"
  else
    warmup_params="{\"ingest_percentage\": ${warmup_ingest}, \"number_of_replicas\": 0, \"bulk_indexing_clients\": ${bulk_clients}}"
  fi

  echo "CMD: opensearch-benchmark run \\"
  echo "  --pipeline=benchmark-only \\"
  echo "  --workload-path=\"${workload_path}\" \\"
  echo "  --target-hosts=\"${host}:9200\" \\"
  echo "  --test-procedure=\"${test_procedure}\" \\"
  echo "  --include-tasks=\"${include_tasks}\" \\"
  echo "  --kill-running-processes \\"
  echo "  --results-format=csv \\"
  echo "  --workload-params='${workload_params}'"
  echo ""

  local iteration_dir="/tmp/nightly-iterations-${engine}-${workload}"
  rm -rf "$iteration_dir"
  mkdir -p "$iteration_dir"

  local exit_code=0

  # --- Iteration 0: Warmup (10% ingest, result discarded) ---
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────┐"
  echo "  │  WARMUP ITERATION (10% ingest, result discarded)        │"
  echo "  └─────────────────────────────────────────────────────────┘"
  opensearch-benchmark run \
    --pipeline=benchmark-only \
    --workload-path="$workload_path" \
    --target-hosts="${host}:9200" \
    --test-procedure="$test_procedure" \
    --include-tasks="$include_tasks" \
    --kill-running-processes \
    --results-format=csv \
    --results-file="${iteration_dir}/warmup.csv" \
    --workload-params="$warmup_params" || true
  echo "  Warmup complete (result discarded)."
  echo ""

  # --- Iterations 1-3: Measured runs (full ingest) ---
  for iter in 1 2 3; do
    echo "  ┌─────────────────────────────────────────────────────────┐"
    echo "  │  MEASURED ITERATION ${iter}/3                              │"
    echo "  └─────────────────────────────────────────────────────────┘"
    opensearch-benchmark run \
      --pipeline=benchmark-only \
      --workload-path="$workload_path" \
      --target-hosts="${host}:9200" \
      --test-procedure="$test_procedure" \
      --include-tasks="$include_tasks" \
      --kill-running-processes \
      --results-format=csv \
      --results-file="${iteration_dir}/iter${iter}.csv" \
      --workload-params="$workload_params"

    local iter_exit=$?
    if [ $iter_exit -ne 0 ]; then
      echo "  WARNING: Iteration ${iter} failed (exit code: $iter_exit)"
      exit_code=$iter_exit
    else
      echo "  ✓ Iteration ${iter} complete."
    fi
    echo ""
  done

  # --- Average the 3 measured CSVs into the final results file ---
  echo "  Averaging 3 iterations → ${results_file}"
  python3 -c "
import csv, sys, os
from collections import defaultdict

iteration_dir = '${iteration_dir}'
output_file = '${results_file}'

# Read all iteration CSVs
all_rows = []
for i in range(1, 4):
    f = os.path.join(iteration_dir, f'iter{i}.csv')
    if os.path.isfile(f):
        with open(f) as fh:
            reader = csv.DictReader(fh)
            all_rows.append(list(reader))

if not all_rows:
    print('ERROR: No iteration CSVs found')
    sys.exit(1)

# Use first iteration as template, average numeric values
averaged = []
for row_idx, row in enumerate(all_rows[0]):
    avg_row = dict(row)
    for key in row:
        if key in ('Metric', 'Task', 'Unit'):
            continue
        try:
            values = [float(all_rows[i][row_idx].get(key, 0)) for i in range(len(all_rows)) if row_idx < len(all_rows[i])]
            if values:
                avg_row[key] = f'{sum(values)/len(values):.2f}'
        except (ValueError, IndexError):
            pass
    averaged.append(avg_row)

# Write averaged CSV
if averaged:
    with open(output_file, 'w', newline='') as fh:
        writer = csv.DictWriter(fh, fieldnames=averaged[0].keys())
        writer.writeheader()
        writer.writerows(averaged)
    print(f'  ✓ Averaged {len(all_rows)} iterations → {output_file}')
else:
    print('  WARNING: No data to average')
" || echo "  WARNING: Averaging failed, using last iteration"
  # Fallback: if averaging failed, copy last iteration
  if [ ! -f "$results_file" ] && [ -f "${iteration_dir}/iter3.csv" ]; then
    cp "${iteration_dir}/iter3.csv" "$results_file"
  fi

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
  curl -s "http://${host}:9200/_all/_settings?pretty" 2>/dev/null
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
