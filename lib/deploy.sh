#!/bin/bash
# CDK deploy + output parsing

CDK_REPO_DIR="$HOME/cdk-repo"
CDK_DIR="$CDK_REPO_DIR"
CDK_REPO_URL="${CONFIG_CDK_REPO:-https://github.com/HarishNarasimhanK/opensearch-benchmark-cdk.git}"
CDK_REPO_BRANCH="${CONFIG_CDK_BRANCH:-main}"
DATAFUSION_IP=""
LUCENE_IP=""

git_pull_cdk_repo() {
  # Always fresh clone to ensure correct repo/branch from config
  cd "$HOME"

  # Preserve .env (contains VPC_ID, SUBNET_ID, etc. — not in git)
  if [ -f "$CDK_REPO_DIR/.env" ]; then
    cp "$CDK_REPO_DIR/.env" /tmp/cdk-env-backup
  fi

  rm -rf "$CDK_REPO_DIR"
  echo "Cloning CDK repo: $CDK_REPO_URL@$CDK_REPO_BRANCH..."
  git clone -b "$CDK_REPO_BRANCH" "$CDK_REPO_URL" "$CDK_REPO_DIR"

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
  local stack_status
  stack_status=$(aws cloudformation describe-stacks \
    --stack-name "OpenSearchCodeGuruStack-nightly" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [ "$stack_status" != "DOES_NOT_EXIST" ]; then
    echo "WARNING: Existing nightly stack found (status: $stack_status). Destroying..."
    cd "$CDK_DIR"
    npx cdk destroy OpenSearchCodeGuruStack-nightly --force || true
    sleep 30
  fi
}

deploy_cdk_stack() {
  local run_id="$1"

  cd "$CDK_DIR"

  # Set STACK_SUFFIX in .env for this deploy
  if grep -q "^STACK_SUFFIX=" .env 2>/dev/null; then
    sed -i'' -e 's/^STACK_SUFFIX=.*/STACK_SUFFIX=nightly/' .env
  else
    echo "STACK_SUFFIX=nightly" >> .env
  fi

  npx cdk deploy OpenSearchCodeGuruStack-nightly \
    --require-approval never \
    --outputs-file "$HOME/nightly-cdk-outputs.json" \
    -c benchmarkEnabled=false \
    -c runIdPrefix=nightly \
    -c s3Bucket="$CONFIG_S3_BUCKET" \
    -c datafusionBranch="$CONFIG_DATAFUSION_BRANCH" \
    -c datafusionRepo="$CONFIG_DATAFUSION_REPO" \
    -c luceneBranch="$CONFIG_LUCENE_BRANCH" \
    -c luceneRepo="$CONFIG_LUCENE_REPO" \
    -c datafusionWorkloadRepo="$CONFIG_DATAFUSION_WORKLOAD_REPO" \
    -c datafusionWorkloadBranch="$CONFIG_DATAFUSION_WORKLOAD_BRANCH" \
    -c luceneWorkloadRepo="$CONFIG_LUCENE_WORKLOAD_REPO" \
    -c luceneWorkloadBranch="$CONFIG_LUCENE_WORKLOAD_BRANCH" \
    -c ingestPercentage="$CONFIG_INGEST_PERCENTAGE"
}

parse_cdk_outputs() {
  local outputs_file="$HOME/nightly-cdk-outputs.json"
  local stack_key="OpenSearchCodeGuruStack-nightly"

  DATAFUSION_IP=$(jq -r ".\"$stack_key\".B4DataFusionPrivateIp // empty" "$outputs_file")
  LUCENE_IP=$(jq -r ".\"$stack_key\".C3LucenePrivateIp // empty" "$outputs_file")

  if [ -z "$DATAFUSION_IP" ] || [ -z "$LUCENE_IP" ]; then
    echo "ERROR: Could not extract IPs from CDK outputs"
    echo "Outputs: $(cat "$outputs_file")"
    return 1
  fi

  echo "DataFusion IP: $DATAFUSION_IP"
  echo "Lucene IP:     $LUCENE_IP"
}
