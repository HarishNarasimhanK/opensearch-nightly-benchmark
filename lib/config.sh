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
  CONFIG_DATAFUSION_REPO=$(jq -r '.datafusionRepo // "https://github.com/opensearch-project/OpenSearch.git"' "$config_file")
  CONFIG_DATAFUSION_BRANCH=$(jq -r '.datafusionBranch // "main"' "$config_file")
  CONFIG_LUCENE_REPO=$(jq -r '.luceneRepo // "https://github.com/opensearch-project/OpenSearch.git"' "$config_file")
  CONFIG_LUCENE_BRANCH=$(jq -r '.luceneBranch // "main"' "$config_file")
  CONFIG_INGEST_PERCENTAGE=$(jq -r '.ingestPercentage // 100' "$config_file")
  CONFIG_S3_BUCKET=$(jq -r '.s3Bucket // "opensearch-nightly-500923064869"' "$config_file")
  CONFIG_MODE=$(jq -r '.mode // "nightly"' "$config_file")
  CONFIG_DATAFUSION_WORKLOAD_REPO=$(jq -r '.datafusionWorkloadRepo // "https://github.com/HarishNarasimhanK/opensearch-benchmark-workloads.git"' "$config_file")
  CONFIG_DATAFUSION_WORKLOAD_BRANCH=$(jq -r '.datafusionWorkloadBranch // "nightly"' "$config_file")
  CONFIG_LUCENE_WORKLOAD_REPO=$(jq -r '.luceneWorkloadRepo // "https://github.com/opensearch-project/opensearch-benchmark-workloads.git"' "$config_file")
  CONFIG_LUCENE_WORKLOAD_BRANCH=$(jq -r '.luceneWorkloadBranch // "main"' "$config_file")

  # Clamp runIntervalHours to [4, 24]
  local raw_interval
  raw_interval=$(jq -r '.runIntervalHours // 24' "$config_file")
  CONFIG_RUN_INTERVAL_HOURS=$(clamp_interval "$raw_interval")

  # Validate ingestPercentage
  validate_ingest_percentage "$CONFIG_INGEST_PERCENTAGE"

  # Export config variables
  export CONFIG_DATAFUSION_REPO
  export CONFIG_DATAFUSION_BRANCH
  export CONFIG_LUCENE_REPO
  export CONFIG_LUCENE_BRANCH
  export CONFIG_INGEST_PERCENTAGE
  export CONFIG_RUN_INTERVAL_HOURS
  export CONFIG_S3_BUCKET
  export CONFIG_MODE
  export CONFIG_DATAFUSION_WORKLOAD_REPO
  export CONFIG_DATAFUSION_WORKLOAD_BRANCH
  export CONFIG_LUCENE_WORKLOAD_REPO
  export CONFIG_LUCENE_WORKLOAD_BRANCH

  echo "Config loaded:"
  echo "  DataFusion: ${CONFIG_DATAFUSION_REPO}@${CONFIG_DATAFUSION_BRANCH}"
  echo "  Lucene:     ${CONFIG_LUCENE_REPO}@${CONFIG_LUCENE_BRANCH}"
  echo "  Ingest:     ${CONFIG_INGEST_PERCENTAGE}%"
  echo "  Interval:   ${CONFIG_RUN_INTERVAL_HOURS}h"
  echo "  S3 Bucket:  ${CONFIG_S3_BUCKET}"
  echo "  Mode:       ${CONFIG_MODE}"
}
