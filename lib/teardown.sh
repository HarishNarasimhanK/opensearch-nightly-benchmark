#!/bin/bash
# CDK destroy with retry

teardown_stack() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Tearing down CDK stack..."

  cd "$CDK_DIR"

  npx cdk destroy OpenSearchCodeGuruStack-nightly --force && {
    echo "Stack destroyed successfully."
    return 0
  }

  # First attempt failed — retry after 30s
  echo "First destroy attempt failed. Retrying in 30s..."
  sleep 30

  npx cdk destroy OpenSearchCodeGuruStack-nightly --force && {
    echo "Stack destroyed on retry."
    return 0
  }

  # Second attempt failed — write alert marker
  echo "ALERT: Teardown failed twice — orphaned resources!"
  echo "ORPHANED_STACK=$(date -u +%Y-%m-%dT%H:%M:%SZ)" | \
    aws s3 cp - "s3://$CONFIG_S3_BUCKET/nightly/ALERT_ORPHANED_STACK"
  return 1
}
