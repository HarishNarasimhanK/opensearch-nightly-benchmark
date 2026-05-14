#!/bin/bash
# OSB indexing benchmark execution

# Ensure pip --user binaries (opensearch-benchmark) are in PATH
export PATH="$HOME/.local/bin:$PATH"

ensure_workloads_cloned() {
  local df_repo="${CONFIG_DATAFUSION_WORKLOAD_REPO:-https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git}"
  local df_branch="${CONFIG_DATAFUSION_WORKLOAD_BRANCH:-nightly}"
  local lu_repo="${CONFIG_LUCENE_WORKLOAD_REPO:-https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git}"
  local lu_branch="${CONFIG_LUCENE_WORKLOAD_BRANCH:-nightly-lucene}"

  # Always fresh clone to ensure correct repo/branch from config
  rm -rf "$HOME/datafusion-workloads"
  echo "Cloning workloads for datafusion: ${df_repo}@${df_branch}..."
  git clone "$df_repo" -b "$df_branch" "$HOME/datafusion-workloads"

  rm -rf "$HOME/lucene-workloads"
  echo "Cloning workloads for lucene: ${lu_repo}@${lu_branch}..."
  git clone "$lu_repo" -b "$lu_branch" "$HOME/lucene-workloads"
}

wait_for_health() {
  local host="$1"
  local engine="$2"
  local max_attempts=999999  # Effectively infinite — wait until health is green

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

  echo "ERROR: $engine cluster did not become healthy (gave up after $max_attempts attempts)"
  return 1
}

run_indexing_benchmark() {
  local host="$1"
  local engine="$2"
  local run_id="$3"

  local test_procedure workload_path bulk_clients
  if [ "$engine" = "datafusion" ]; then
    test_procedure="datafusion-ppl"
    workload_path="$HOME/datafusion-workloads/clickbench"
    bulk_clients=50
  else
    test_procedure="dsl-clickbench"
    workload_path="$HOME/lucene-workloads/clickbench"
    bulk_clients=8
  fi

  local results_file="/tmp/nightly-result-${engine}.csv"

  echo "Running indexing benchmark against $engine ($host:9200)..."
  echo "  Test procedure: $test_procedure"
  echo "  Workload: $workload_path"
  echo "  Bulk clients: $bulk_clients"

  opensearch-benchmark run \
    --pipeline=benchmark-only \
    --workload-path="$workload_path" \
    --target-hosts="${host}:9200" \
    --test-procedure="$test_procedure" \
    --include-tasks="delete-index,create-index,index-append" \
    --kill-running-processes \
    --results-format=csv \
    --results-file="$results_file" \
    --workload-params="{\"ingest_percentage\": ${CONFIG_INGEST_PERCENTAGE}, \"number_of_replicas\": 0, \"bulk_indexing_clients\": ${bulk_clients}}"

  local exit_code=$?
  if [ $exit_code -eq 0 ]; then
    echo "$engine benchmark completed successfully."
  else
    echo "ERROR: $engine benchmark failed (exit code: $exit_code)"
  fi
  return $exit_code
}

trigger_data_upload() {
  # Writes the BENCHMARK_COMPLETE flag to S3, which signals the upload-data-on-complete.sh
  # poller running on each OpenSearch instance to tar and upload the data folder.
  echo "Triggering data folder upload on DataFusion + Lucene instances..."
  echo "BENCHMARK_COMPLETE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | \
    aws s3 cp - "s3://${CONFIG_S3_BUCKET}/flags/BENCHMARK_COMPLETE"
  echo "Flag written. Instances will upload data folders to s3://${CONFIG_S3_BUCKET}/runs/${RUN_ID}/data/{engine}/"
}
