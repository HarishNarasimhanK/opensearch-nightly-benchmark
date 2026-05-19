# OpenSearch Nightly Indexing Benchmark

Automated pipeline that deploys 3 OpenSearch engines (Parquet, Lucene, ParquetLucene) via CDK, runs indexing benchmarks, collects results to S3, and tears down on next run.

## Nightly Instance

```
ssh -i ~/.ssh/benchmark-mustang.pem ec2-user@ec2-44-202-145-93.compute-1.amazonaws.com
```

## Quick Start

```bash
# Pull latest code
cd ~/nightly-repo && git fetch origin && git reset --hard origin/main

# Run clickbench (adhoc, one-shot)
rm -f /tmp/nightly-benchmark-clickbench.lock
nohup bash ~/nightly-repo/nightly-benchmark.sh --workload=clickbench > ~/nightly-adhoc-clickbench.log 2>&1 &
tail -f ~/nightly-adhoc-clickbench.log

# Run http_logs (adhoc, one-shot)
rm -f /tmp/nightly-benchmark-http-logs.lock
nohup bash ~/nightly-repo/nightly-benchmark.sh --workload=http_logs > ~/nightly-adhoc-http-logs.log 2>&1 &
tail -f ~/nightly-adhoc-http-logs.log

# Run both sequentially
bash ~/nightly-repo/run-all-workloads.sh
```

## Nightly Loop Mode

Runs forever, sleeping `runIntervalHours` between runs:

```bash
screen -S nightly
bash ~/nightly-repo/nightly-benchmark.sh --workload=clickbench --nightly
```

## What It Does

1. Destroys any existing stack for the workload
2. Clones CDK repo + workload repos (parquet, lucene, indexed_parquet branches)
3. Deploys CDK stack: Builder + Parquet + Lucene + ParquetLucene instances
4. Waits for all 3 clusters to be green
5. Runs OSB indexing benchmark against all 3 engines
6. Stores CSV results to S3 and publishes CloudWatch metrics
7. Generates trend chart HTML → S3

## Configuration

Edit `nightly-config.json`:

| Key | Description |
|-----|-------------|
| `parquetRepo` / `parquetBranch` | OpenSearch repo+branch for parquet engine |
| `luceneRepo` / `luceneBranch` | OpenSearch repo+branch for lucene engine |
| `*WorkloadRepo` / `*WorkloadBranch` | OSB workload repos per engine |
| `ingestPercentage` | % of dataset to ingest (100 = full) |
| `s3Bucket` | Results bucket |
| `runIntervalHours` | Sleep between nightly runs |

## Results

- **S3**: `s3://opensearch-nightly-500923064869/nightly/`
  - `indexing-throughput-clickbench.csv`
  - `nightly-indexing-trend-clickbench.html`
- **CloudWatch**: Namespace `OpenSearch/Nightly`
- **Node stats**: `s3://.../runs/{RUN_ID}/node-stats/{engine}/...`

## Troubleshooting

```bash
# Check if a run is stuck (lock file exists)
ls -la /tmp/nightly-benchmark-*.lock

# Force remove lock
rm -f /tmp/nightly-benchmark-clickbench.lock

# Check CDK outputs from last deploy
cat ~/nightly-cdk-outputs.json

# Manually destroy a stuck stack
cd ~/cdk-repo && npx cdk destroy OpenSearchCodeGuruStack-nightly-clickbench --force
```

## File Structure

```
nightly-benchmark.sh    # Main entrypoint
run-all-workloads.sh    # Orchestrator: runs clickbench then http_logs
nightly-config.json     # All config (repos, branches, bucket, etc.)
lib/
  config.sh             # Reads nightly-config.json into env vars
  deploy.sh             # CDK clone, deploy, parse outputs
  benchmark.sh          # OSB run logic (workload-aware)
  results.sh            # CSV aggregation + S3 upload
  metrics.sh            # CloudWatch metric publishing
  teardown.sh           # Stack destroy
  lock.sh               # File-based locking
generate-nightly-trend.py  # Plotly trend chart from CSV
```
