#!/bin/bash
# Results parsing, CSV construction, and S3 upload

CSV_HEADERS="date,run_id,engine,min_throughput,mean_throughput,median_throughput,max_throughput,error_rate,p50_latency_ms,p99_latency_ms,duration_sec,ingest_percentage,status,error_reason,mode,parquet_repo,parquet_branch"

extract_metric() {
  local csv_file="$1"
  local metric_name="$2"
  local task="$3"
  # OSB CSV format: Metric,Task,Value,Unit
  grep "^${metric_name}," "$csv_file" | grep ",${task}," | awk -F',' '{print $3}' | tail -1
}

parse_osb_results() {
  local engine="$1"
  local csv_file="/tmp/nightly-result-${engine}.csv"

  if [ ! -f "$csv_file" ]; then
    echo "0,0,0,0,0,0,0"
    return
  fi

  local min_tp mean_tp median_tp max_tp error_rate p50_lat p99_lat
  min_tp=$(extract_metric "$csv_file" "Min Throughput" "index-append")
  mean_tp=$(extract_metric "$csv_file" "Mean Throughput" "index-append")
  median_tp=$(extract_metric "$csv_file" "Median Throughput" "index-append")
  max_tp=$(extract_metric "$csv_file" "Max Throughput" "index-append")
  error_rate=$(extract_metric "$csv_file" "error rate" "index-append")
  p50_lat=$(extract_metric "$csv_file" "50th percentile latency" "index-append")
  p99_lat=$(extract_metric "$csv_file" "99th percentile latency" "index-append")

  echo "${min_tp:-0},${mean_tp:-0},${median_tp:-0},${max_tp:-0},${error_rate:-0},${p50_lat:-0},${p99_lat:-0}"
}

parse_and_store_results() {
  local run_id="$1"
  local mode="$2"
  local start_time="$3"
  local end_time="$4"
  local CSV_S3_PATH="s3://${CONFIG_S3_BUCKET}/nightly/indexing-throughput.csv"

  local date_str
  date_str=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Calculate duration
  local duration_sec=0
  if [ -n "$start_time" ] && [ -n "$end_time" ]; then
    duration_sec=$(( $(date -d "$end_time" +%s 2>/dev/null || echo 0) - $(date -d "$start_time" +%s 2>/dev/null || echo 0) ))
  fi

  # Download existing CSV (or create new)
  local local_csv="/tmp/indexing-throughput.csv"
  aws s3 cp "$CSV_S3_PATH" "$local_csv" 2>/dev/null || {
    echo "$CSV_HEADERS" > "$local_csv"
  }

  # Parse results for all engines
  local pq_metrics pql_metrics lu_metrics
  pq_metrics=$(parse_osb_results "parquet")
  pql_metrics=$(parse_osb_results "parquetLucene")
  lu_metrics=$(parse_osb_results "lucene")

  # Append rows for all engines
  echo "${date_str},${run_id},parquet,${pq_metrics},${duration_sec},${CONFIG_INGEST_PERCENTAGE},success,,${mode},${CONFIG_PARQUET_REPO},${CONFIG_PARQUET_BRANCH}" >> "$local_csv"
  echo "${date_str},${run_id},parquetLucene,${pql_metrics},${duration_sec},${CONFIG_INGEST_PERCENTAGE},success,,${mode},${CONFIG_PARQUET_REPO},${CONFIG_PARQUET_BRANCH}" >> "$local_csv"
  echo "${date_str},${run_id},lucene,${lu_metrics},${duration_sec},${CONFIG_INGEST_PERCENTAGE},success,,${mode},${CONFIG_LUCENE_REPO},${CONFIG_LUCENE_BRANCH}" >> "$local_csv"

  # Upload back to S3
  aws s3 cp "$local_csv" "$CSV_S3_PATH"
  echo "Results stored to $CSV_S3_PATH"
}

record_failure() {
  local run_id="$1"
  local error_reason="$2"
  local date_str
  date_str=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local mode="${CONFIG_MODE:-nightly}"
  local CSV_S3_PATH="s3://${CONFIG_S3_BUCKET}/nightly/indexing-throughput.csv"

  local local_csv="/tmp/indexing-throughput.csv"
  aws s3 cp "$CSV_S3_PATH" "$local_csv" 2>/dev/null || {
    echo "$CSV_HEADERS" > "$local_csv"
  }

  echo "${date_str},${run_id},parquet,0,0,0,0,0,0,0,0,${CONFIG_INGEST_PERCENTAGE},failed,${error_reason},${mode},${CONFIG_PARQUET_REPO},${CONFIG_PARQUET_BRANCH}" >> "$local_csv"
  echo "${date_str},${run_id},parquetLucene,0,0,0,0,0,0,0,0,${CONFIG_INGEST_PERCENTAGE},failed,${error_reason},${mode},${CONFIG_PARQUET_REPO},${CONFIG_PARQUET_BRANCH}" >> "$local_csv"
  echo "${date_str},${run_id},lucene,0,0,0,0,0,0,0,0,${CONFIG_INGEST_PERCENTAGE},failed,${error_reason},${mode},${CONFIG_LUCENE_REPO},${CONFIG_LUCENE_BRANCH}" >> "$local_csv"

  aws s3 cp "$local_csv" "$CSV_S3_PATH"
  echo "Failure recorded: $error_reason"
}

parse_and_store_httplogs_results() {
  local run_id="$1"
  local mode="$2"
  local CSV_S3_PATH="s3://${CONFIG_S3_BUCKET}/nightly/indexing-throughput-httplogs.csv"
  local CSV_HEADERS_HL="date,run_id,engine,min_throughput,mean_throughput,median_throughput,max_throughput,error_rate,p50_latency_ms,p99_latency_ms,ingest_percentage,status,mode"

  local date_str
  date_str=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local local_csv="/tmp/indexing-throughput-httplogs.csv"
  aws s3 cp "$CSV_S3_PATH" "$local_csv" 2>/dev/null || {
    echo "$CSV_HEADERS_HL" > "$local_csv"
  }

  for engine in parquet parquetLucene lucene; do
    local csv_file="/tmp/nightly-result-${engine}-httplogs.csv"
    if [ -f "$csv_file" ]; then
      local min_tp mean_tp median_tp max_tp error_rate p50_lat p99_lat
      min_tp=$(extract_metric "$csv_file" "Min Throughput" "index-append")
      mean_tp=$(extract_metric "$csv_file" "Mean Throughput" "index-append")
      median_tp=$(extract_metric "$csv_file" "Median Throughput" "index-append")
      max_tp=$(extract_metric "$csv_file" "Max Throughput" "index-append")
      error_rate=$(extract_metric "$csv_file" "error rate" "index-append")
      p50_lat=$(extract_metric "$csv_file" "50th percentile latency" "index-append")
      p99_lat=$(extract_metric "$csv_file" "99th percentile latency" "index-append")
      echo "${date_str},${run_id},${engine},${min_tp:-0},${mean_tp:-0},${median_tp:-0},${max_tp:-0},${error_rate:-0},${p50_lat:-0},${p99_lat:-0},100,success,${mode}" >> "$local_csv"
    else
      echo "${date_str},${run_id},${engine},0,0,0,0,0,0,0,100,failed,${mode}" >> "$local_csv"
    fi
  done

  aws s3 cp "$local_csv" "$CSV_S3_PATH"
  echo "http_logs results stored to $CSV_S3_PATH"
}
