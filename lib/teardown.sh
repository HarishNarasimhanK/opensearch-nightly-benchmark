#!/bin/bash
# CDK destroy with retry

teardown_stack() {
  local stack_name="OpenSearchCodeGuruStack-${NIGHTLY_STACK_SUFFIX}"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Tearing down CDK stack: ${stack_name}..."

  cd "$CDK_DIR"

  npx cdk destroy "$stack_name" --force && {
    echo "Stack ${stack_name} destroyed successfully."
    return 0
  }

  # First attempt failed — retry after 30s
  echo "First destroy attempt failed. Retrying in 30s..."
  sleep 30

  npx cdk destroy "$stack_name" --force && {
    echo "Stack ${stack_name} destroyed on retry."
    return 0
  }

  # Second attempt failed — write alert marker
  echo "ALERT: Teardown failed twice for ${stack_name} — orphaned resources!"
  echo "ORPHANED_STACK=${stack_name} at $(date -u +%Y-%m-%dT%H:%M:%SZ)" | \
    aws s3 cp - "s3://$CONFIG_S3_BUCKET/nightly/ALERT_ORPHANED_STACK_${NIGHTLY_STACK_SUFFIX}"
  return 1
}
