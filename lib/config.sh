#!/bin/bash
# Config parsing and validation

clamp_interval() {
  local val="$1"
  # Handle non-numeric input
  if ! [[ "$val" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo 24
    return
  fi
  # Clamp to [4, 24]
  if (( $(echo "$val < 4" | bc -l) )); then
    echo 4
  elif (( $(echo "$val > 24" | bc -l) )); then
    echo 24
  else
    echo "$val"
  fi
}

validate_ingest_percentage() {
  local val="$1"
  if ! [[ "$val" =~ ^[0-9]*\.?[0-9]+$ ]]; then
    echo "ERROR: ingestPercentage must be numeric, got: $val"
    exit 1
  fi
  if (( $(echo "$val <= 0" | bc -l) )); then
    echo "ERROR: ingestPercentage must be > 0, got: $val"
    exit 1
  fi
  if (( $(echo "$val > 100" | bc -l) )); then
    echo "ERROR: ingestPercentage must be <= 100, got: $val"
    exit 1
  fi
}

load_config() {
  local config_file="$1"

  if [ ! -f "$config_file" ]; then
    echo "ERROR: Config file not found: $config_file"
    exit 1
  fi

  # Parse JSON with jq, apply defaults for missing fields
  CONFIG_PARQUET_REPO=$(jq -r '.parquetRepo // "https://github.com/opensearch-project/OpenSearch.git"' "$config_file")
  CONFIG_PARQUET_BRANCH=$(jq -r '.parquetBranch // "main"' "$config_file")
  CONFIG_LUCENE_REPO=$(jq -r '.luceneRepo // "https://github.com/opensearch-project/OpenSearch.git"' "$config_file")
  CONFIG_LUCENE_BRANCH=$(jq -r '.luceneBranch // "main"' "$config_file")
  CONFIG_CDK_REPO=$(jq -r '.cdkRepo // "https://github.com/HarishNarasimhanK/opensearch-benchmark-cdk.git"' "$config_file")
  CONFIG_CDK_BRANCH=$(jq -r '.cdkBranch // "main"' "$config_file")
  CONFIG_INGEST_PERCENTAGE=$(jq -r '.ingestPercentage // 100' "$config_file")
  CONFIG_S3_BUCKET=$(jq -r '.s3Bucket // "opensearch-nightly-500923064869"' "$config_file")
  CONFIG_MODE=$(jq -r '.mode // "nightly"' "$config_file")
  CONFIG_PARQUET_WORKLOAD_REPO=$(jq -r '.parquetWorkloadRepo // "https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git"' "$config_file")
  CONFIG_PARQUET_WORKLOAD_BRANCH=$(jq -r '.parquetWorkloadBranch // "parquet"' "$config_file")
  CONFIG_PARQUET_LUCENE_WORKLOAD_REPO=$(jq -r '.parquetLuceneWorkloadRepo // "https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git"' "$config_file")
  CONFIG_PARQUET_LUCENE_WORKLOAD_BRANCH=$(jq -r '.parquetLuceneWorkloadBranch // "indexed_parquet"' "$config_file")
  CONFIG_LUCENE_WORKLOAD_REPO=$(jq -r '.luceneWorkloadRepo // "https://github.com/opensearch-project/opensearch-benchmark-workloads.git"' "$config_file")
  CONFIG_LUCENE_WORKLOAD_BRANCH=$(jq -r '.luceneWorkloadBranch // "main"' "$config_file")
  CONFIG_WORKLOAD=$(jq -r '.workload // "clickbench"' "$config_file")

  # Cluster topology (nightly is always multi-node with remote store)
  CONFIG_DATA_NODE_COUNT=$(jq -r '.dataNodeCount // 3' "$config_file")
  CONFIG_NUMBER_OF_SHARDS=$(jq -r '.numberOfShards // 1' "$config_file")
  CONFIG_NUMBER_OF_REPLICAS=$(jq -r '.numberOfReplicas // 1' "$config_file")

  # Validate: replicas must be < dataNodeCount
  if [ "$CONFIG_NUMBER_OF_REPLICAS" -ge "$CONFIG_DATA_NODE_COUNT" ]; then
    echo "ERROR: numberOfReplicas ($CONFIG_NUMBER_OF_REPLICAS) must be < dataNodeCount ($CONFIG_DATA_NODE_COUNT)"
    exit 1
  fi

  # Slack — read from env or ~/.nightly-secrets (NOT from config file)
  if [ -z "${SLACK_WEBHOOK_URL:-}" ] && [ -f "$HOME/.nightly-secrets" ]; then
    SLACK_WEBHOOK_URL=$(grep -s '^SLACK_WEBHOOK_URL=' "$HOME/.nightly-secrets" | cut -d'=' -f2- || true)
  fi
  if [ -z "${SLACK_TOKEN:-}" ] && [ -f "$HOME/.nightly-secrets" ]; then
    SLACK_TOKEN=$(grep -s '^SLACK_TOKEN=' "$HOME/.nightly-secrets" | cut -d'=' -f2- || true)
  fi
  if [ -z "${SLACK_CHANNEL:-}" ] && [ -f "$HOME/.nightly-secrets" ]; then
    SLACK_CHANNEL=$(grep -s '^SLACK_CHANNEL=' "$HOME/.nightly-secrets" | cut -d'=' -f2- || true)
  fi
  # Use token as webhook if no webhook URL set
  if [ -z "${SLACK_WEBHOOK_URL:-}" ] && [ -n "${SLACK_TOKEN:-}" ]; then
    SLACK_WEBHOOK_URL="$SLACK_TOKEN"
  fi

  # Clamp runIntervalHours to [4, 24]
  local raw_interval
  raw_interval=$(jq -r '.runIntervalHours // 24' "$config_file")
  CONFIG_RUN_INTERVAL_HOURS=$(clamp_interval "$raw_interval")

  # Validate ingestPercentage
  validate_ingest_percentage "$CONFIG_INGEST_PERCENTAGE"

  # Export config variables
  export CONFIG_PARQUET_REPO
  export CONFIG_PARQUET_BRANCH
  export CONFIG_LUCENE_REPO
  export CONFIG_LUCENE_BRANCH
  export CONFIG_CDK_REPO
  export CONFIG_CDK_BRANCH
  export CONFIG_INGEST_PERCENTAGE
  export CONFIG_RUN_INTERVAL_HOURS
  export CONFIG_S3_BUCKET
  export CONFIG_MODE
  export CONFIG_PARQUET_WORKLOAD_REPO
  export CONFIG_PARQUET_WORKLOAD_BRANCH
  export CONFIG_PARQUET_LUCENE_WORKLOAD_REPO
  export CONFIG_PARQUET_LUCENE_WORKLOAD_BRANCH
  export CONFIG_LUCENE_WORKLOAD_REPO
  export CONFIG_LUCENE_WORKLOAD_BRANCH
  export CONFIG_WORKLOAD
  export CONFIG_DATA_NODE_COUNT
  export CONFIG_NUMBER_OF_SHARDS
  export CONFIG_NUMBER_OF_REPLICAS
  export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
  export SLACK_CHANNEL="${SLACK_CHANNEL:-}"

  echo "Config loaded:"
  echo "  Parquet:    ${CONFIG_PARQUET_REPO}@${CONFIG_PARQUET_BRANCH}"
  echo "  Lucene:     ${CONFIG_LUCENE_REPO}@${CONFIG_LUCENE_BRANCH}"
  echo "  Workload:   ${CONFIG_WORKLOAD}"
  echo "  Ingest:     ${CONFIG_INGEST_PERCENTAGE}%"
  echo "  Interval:   ${CONFIG_RUN_INTERVAL_HOURS}h"
  echo "  S3 Bucket:  ${CONFIG_S3_BUCKET}"
  echo "  Mode:       ${CONFIG_MODE}"
  echo "  Cluster:    multi (${CONFIG_DATA_NODE_COUNT} data nodes, ${CONFIG_NUMBER_OF_SHARDS} shards, ${CONFIG_NUMBER_OF_REPLICAS} replicas)"
  echo "  Remote Store: enabled (segment replication)"
}
