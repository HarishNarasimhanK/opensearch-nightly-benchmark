#!/bin/bash
# CDK deploy + output parsing

CDK_REPO_DIR="$HOME/cdk-repo"
CDK_DIR="$CDK_REPO_DIR"
PARQUET_IP=""
PARQUET_LUCENE_IP=""
LUCENE_IP=""

git_pull_cdk_repo() {
  local repo_url="${CONFIG_CDK_REPO:-https://github.com/HarishNarasimhanK/opensearch-benchmark-cdk.git}"
  local repo_branch="${CONFIG_CDK_BRANCH:-main}"

  # Always fresh clone to ensure correct repo/branch from config
  cd "$HOME"

  # Preserve .env (contains VPC_ID, SUBNET_ID, etc. — not in git)
  if [ -f "$CDK_REPO_DIR/.env" ]; then
    cp "$CDK_REPO_DIR/.env" /tmp/cdk-env-backup
  fi

  rm -rf "$CDK_REPO_DIR"
  echo "Cloning CDK repo: $repo_url@$repo_branch..."
  git clone -b "$repo_branch" "$repo_url" "$CDK_REPO_DIR"

  # Restore .env
  if [ -f /tmp/cdk-env-backup ]; then
    cp /tmp/cdk-env-backup "$CDK_REPO_DIR/.env"
    rm -f /tmp/cdk-env-backup
  else
    # First run: generate .env via setup-env.sh
    echo "No .env backup found — running setup-env.sh..."
    bash "$CDK_REPO_DIR/scripts/setup-env.sh"
  fi

  cd "$CDK_REPO_DIR" && npm install --silent
}

precheck_destroy_existing() {
  local stack_name="OpenSearchCodeGuruStack-${NIGHTLY_STACK_SUFFIX}"
  local stack_status
  stack_status=$(aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "$stack_status" != "DOES_NOT_EXIST" ]; then
    echo "WARNING: Existing stack ${stack_name} found (status: $stack_status). Destroying..."
    cd "$CDK_DIR"
    npx cdk destroy "$stack_name" --force || true
    sleep 30
  fi
}

deploy_cdk_stack() {
  cd "$CDK_DIR"

  # Set STACK_SUFFIX in .env for this deploy
  if grep -q "^STACK_SUFFIX=" .env 2>/dev/null; then
    sed -i'' -e "s/^STACK_SUFFIX=.*/STACK_SUFFIX=${NIGHTLY_STACK_SUFFIX}/" .env
  else
    echo "STACK_SUFFIX=${NIGHTLY_STACK_SUFFIX}" >> .env
  fi

  # Build remote store / multi-node flags only when --remote flag is passed
  local cluster_args=""
  if [ "${REMOTE_STORE_ENABLED:-false}" = "true" ]; then
    cluster_args="-c remoteStoreEnabled=true -c clusterMode=multi -c dataNodeCount=${CONFIG_DATA_NODE_COUNT}"
  fi

  # Run ID prefix differs when remote store is enabled (keeps S3 paths separate)
  local run_id_prefix="nightly-${CONFIG_WORKLOAD}"
  if [ "${REMOTE_STORE_ENABLED:-false}" = "true" ]; then
    run_id_prefix="nightly-${CONFIG_WORKLOAD}-remote"
  fi

  npx cdk deploy "OpenSearchCodeGuruStack-${NIGHTLY_STACK_SUFFIX}" \
    --require-approval never \
    --outputs-file "$HOME/nightly-cdk-outputs.json" \
    -c benchmarkEnabled=false \
    -c runIdPrefix="$run_id_prefix" \
    -c s3Bucket="$CONFIG_S3_BUCKET" \
    -c parquetBranch="$CONFIG_PARQUET_BRANCH" \
    -c parquetRepo="$CONFIG_PARQUET_REPO" \
    -c luceneBranch="$CONFIG_LUCENE_BRANCH" \
    -c luceneRepo="$CONFIG_LUCENE_REPO" \
    -c parquetWorkloadRepo="$CONFIG_PARQUET_WORKLOAD_REPO" \
    -c parquetWorkloadBranch="$CONFIG_PARQUET_WORKLOAD_BRANCH" \
    -c parquetLuceneWorkloadRepo="$CONFIG_PARQUET_LUCENE_WORKLOAD_REPO" \
    -c parquetLuceneWorkloadBranch="$CONFIG_PARQUET_LUCENE_WORKLOAD_BRANCH" \
    -c luceneWorkloadRepo="$CONFIG_LUCENE_WORKLOAD_REPO" \
    -c luceneWorkloadBranch="$CONFIG_LUCENE_WORKLOAD_BRANCH" \
    -c ingestPercentage="$CONFIG_INGEST_PERCENTAGE" \
    $cluster_args
}

parse_cdk_outputs() {
  local outputs_file="$HOME/nightly-cdk-outputs.json"
  local stack_key="OpenSearchCodeGuruStack-${NIGHTLY_STACK_SUFFIX}"

  # Multi-node: extract ALB DNS endpoints (strip http:// and :9200)
  PARQUET_IP=$(jq -r ".\"$stack_key\".ParquetClusterALBUrl // empty" "$outputs_file" | sed 's|http://||' | sed 's|:9200||')
  PARQUET_LUCENE_IP=$(jq -r ".\"$stack_key\".ParquetLuceneClusterALBUrl // empty" "$outputs_file" | sed 's|http://||' | sed 's|:9200||')
  LUCENE_IP=$(jq -r ".\"$stack_key\".LuceneClusterALBUrl // empty" "$outputs_file" | sed 's|http://||' | sed 's|:9200||')
  RUN_ID=$(jq -r ".\"$stack_key\".RunID // empty" "$outputs_file")

  # Fallback to private IPs if ALB URLs not found (single-node deploys)
  if [ -z "$PARQUET_IP" ]; then
    PARQUET_IP=$(jq -r ".\"$stack_key\".ParquetPrivateIp // empty" "$outputs_file")
  fi
  if [ -z "$PARQUET_LUCENE_IP" ]; then
    PARQUET_LUCENE_IP=$(jq -r ".\"$stack_key\".ParquetLucenePrivateIp // empty" "$outputs_file")
  fi
  if [ -z "$LUCENE_IP" ]; then
    LUCENE_IP=$(jq -r ".\"$stack_key\".LucenePrivateIp // empty" "$outputs_file")
  fi

  if [ -z "$PARQUET_IP" ] || [ -z "$LUCENE_IP" ] || [ -z "$PARQUET_LUCENE_IP" ]; then
    echo "ERROR: Could not extract endpoints from CDK outputs"
    echo "Outputs: $(cat "$outputs_file")"
    return 1
  fi

  if [ -z "$RUN_ID" ]; then
    echo "WARNING: Could not extract RUN_ID from CDK outputs, using fallback"
    RUN_ID="nightly-run-$(date +%Y%m%d_%H%M%S)"
  fi

  echo "Parquet:        $PARQUET_IP"
  echo "ParquetLucene:  $PARQUET_LUCENE_IP"
  echo "Lucene:         $LUCENE_IP"
  echo "Run ID:         $RUN_ID"
  if [ "${REMOTE_STORE_ENABLED:-false}" = "true" ]; then
    echo "Cluster:        multi (${CONFIG_DATA_NODE_COUNT} data nodes, remote store enabled)"
  else
    echo "Cluster:        single-node"
  fi
}
