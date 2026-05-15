#!/bin/bash
# CloudWatch custom metrics publisher

publish_cloudwatch_metrics() {
  local run_id="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Parse mean throughput for each engine
  local pq_metrics lu_metrics pq_mean lu_mean
  pq_metrics=$(parse_osb_results "parquet")
  lu_metrics=$(parse_osb_results "lucene")
  pq_mean=$(echo "$pq_metrics" | cut -d',' -f2)
  lu_mean=$(echo "$lu_metrics" | cut -d',' -f2)

  echo "Publishing CloudWatch metrics..."
  echo "  Parquet mean throughput: $pq_mean docs/s"
  echo "  Lucene mean throughput:     $lu_mean docs/s"

  # Publish Parquet metric
  aws cloudwatch put-metric-data \
    --namespace "OpenSearch/Nightly" \
    --metric-name "IndexingThroughput" \
    --value "${pq_mean:-0}" \
    --unit "Count/Second" \
    --dimensions "Engine=parquet" \
    --timestamp "$timestamp" || echo "WARNING: Failed to publish Parquet metric"

  # Publish Lucene metric
  aws cloudwatch put-metric-data \
    --namespace "OpenSearch/Nightly" \
    --metric-name "IndexingThroughput" \
    --value "${lu_mean:-0}" \
    --unit "Count/Second" \
    --dimensions "Engine=lucene" \
    --timestamp "$timestamp" || echo "WARNING: Failed to publish Lucene metric"

  echo "CloudWatch metrics published."
}
