#!/bin/bash
# CloudWatch custom metrics publisher

publish_cloudwatch_metrics() {
  local run_id="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Parse mean throughput for each engine
  local df_metrics lu_metrics df_mean lu_mean
  df_metrics=$(parse_osb_results "datafusion")
  lu_metrics=$(parse_osb_results "lucene")
  df_mean=$(echo "$df_metrics" | cut -d',' -f2)
  lu_mean=$(echo "$lu_metrics" | cut -d',' -f2)

  echo "Publishing CloudWatch metrics..."
  echo "  DataFusion mean throughput: $df_mean docs/s"
  echo "  Lucene mean throughput:     $lu_mean docs/s"

  # Publish DataFusion metric
  aws cloudwatch put-metric-data \
    --namespace "OpenSearch/Nightly" \
    --metric-name "IndexingThroughput" \
    --value "${df_mean:-0}" \
    --unit "Count/Second" \
    --dimensions "Engine=datafusion" \
    --timestamp "$timestamp" || echo "WARNING: Failed to publish DataFusion metric"

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
