# OpenSearch Nightly Indexing Benchmark

Automated pipeline that deploys 3 OpenSearch engines (Parquet, Lucene, ParquetLucene) via CDK, runs indexing benchmarks, collects results to S3, and generates AI-powered reports.

## Nightly Instance

```bash
ssh -i ~/.ssh/<YOUR_KEY>.pem ec2-user@<NIGHTLY_INSTANCE_DNS>
```

## Quick Start

```bash
# Pull latest code
cd ~/nightly-repo && git fetch origin && git reset --hard origin/main

# Clear any stale locks
rm -f /tmp/nightly-benchmark-*.lock
```

## Running Benchmarks

### All 4 combinations (default)

Runs: clickbench → http_logs → clickbench-remote → http_logs-remote

```bash
nohup bash ~/nightly-repo/run-all-workloads.sh > ~/run-all.log 2>&1 &
tail -f ~/run-all.log
```

### Only single-node (2 runs)

```bash
nohup bash ~/nightly-repo/run-all-workloads.sh --no-remote > ~/run-all.log 2>&1 &
tail -f ~/run-all.log
```

### Only remote store (2 runs)

```bash
nohup bash ~/nightly-repo/run-all-workloads.sh --remote-only > ~/run-all.log 2>&1 &
tail -f ~/run-all.log
```

### Individual runs

```bash
# Single-node clickbench
nohup bash ~/nightly-repo/nightly-benchmark.sh --workload=clickbench > ~/nightly-clickbench.log 2>&1 &

# Single-node http_logs
nohup bash ~/nightly-repo/nightly-benchmark.sh --workload=http_logs > ~/nightly-http_logs.log 2>&1 &

# Remote store clickbench
nohup bash ~/nightly-repo/nightly-benchmark.sh --workload=clickbench --remote > ~/nightly-clickbench-remote.log 2>&1 &

# Remote store http_logs
nohup bash ~/nightly-repo/nightly-benchmark.sh --workload=http_logs --remote > ~/nightly-http_logs-remote.log 2>&1 &
```

## Logs

| Run | Log file |
|-----|----------|
| All combined | `~/run-all.log` |
| clickbench (single-node) | `~/nightly-clickbench.log` |
| http_logs (single-node) | `~/nightly-http_logs.log` |
| clickbench (remote store) | `~/nightly-clickbench-remote.log` |
| http_logs (remote store) | `~/nightly-http_logs-remote.log` |

Previous logs are automatically deleted at the start of each `run-all-workloads.sh` cycle.

## Cron (daily at 3 AM IST / 21:30 UTC)

```
30 21 * * * PATH=/usr/local/bin:/usr/bin:/home/ec2-user/.local/bin && cd /home/ec2-user/nightly-repo && git fetch origin && git reset --hard origin/main && bash run-all-workloads.sh >> /home/ec2-user/nightly-cron.log 2>&1
```

## Configuration

Edit `nightly-config.json`:

| Key | Description |
|-----|-------------|
| `parquetRepo` / `parquetBranch` | OpenSearch repo+branch for parquet engine |
| `luceneRepo` / `luceneBranch` | OpenSearch repo+branch for lucene engine |
| `*WorkloadRepo` / `*WorkloadBranch` | OSB workload repos per engine |
| `ingestPercentage` | % of dataset to ingest (100 = full) |
| `s3Bucket` | Results bucket |
| `runIntervalHours` | Sleep between nightly loop runs |
| `dataNodeCount` | Data nodes per engine (remote store only) |
| `numberOfShards` / `numberOfReplicas` | Index settings (remote store only) |

## Results (S3)

| Type | Single-node | Remote store |
|------|-------------|--------------|
| CSV | `nightly/indexing-throughput-clickbench.csv` | `nightly/indexing-throughput-clickbench-remote.csv` |
| Trend HTML | `nightly/nightly-indexing-trend-clickbench.html` | `nightly/nightly-indexing-trend-clickbench-remote.html` |
| AI Report | `nightly/reports/nightly-report-clickbench-20260524.md` | `nightly/reports/nightly-report-clickbench-remote-20260524.md` |
| Node stats | `runs/{RUN_ID}/node-stats/{engine}/...` | same |

## AI Reports

After each workload+mode run, an AI report is generated via Amazon Bedrock (Claude Opus 4.5):
- Reads the full benchmark log (cluster settings, index settings, `_cat/indices`, OSB output)
- Reads the complete CSV results for all 3 engines
- Produces a comparison report with settings validation, throughput ratios, and anomaly detection
- Uploaded to `s3://<bucket>/nightly/reports/`

## Troubleshooting

```bash
# Check locks
ls -la /tmp/nightly-benchmark-*.lock

# Force remove all locks
rm -f /tmp/nightly-benchmark-*.lock

# Check CDK outputs
cat ~/nightly-cdk-outputs.json

# Destroy stuck stacks
aws cloudformation delete-stack --stack-name OpenSearchCodeGuruStack-nightly-clickbench --region us-east-1
aws cloudformation delete-stack --stack-name OpenSearchCodeGuruStack-nightly-http-logs --region us-east-1
aws cloudformation delete-stack --stack-name OpenSearchCodeGuruStack-nightly-clickbench-remote --region us-east-1
aws cloudformation delete-stack --stack-name OpenSearchCodeGuruStack-nightly-http-logs-remote --region us-east-1

# Kill stuck processes
pkill -9 -f nightly-benchmark
pkill -9 -f "npx cdk"
```

## File Structure

```
nightly-benchmark.sh        # Main entrypoint (one workload + cluster mode)
run-all-workloads.sh        # Orchestrator: runs all combos sequentially
nightly-config.json         # All config (repos, branches, bucket, topology)
generate-report.py          # AI report generation (Bedrock Claude)
generate-nightly-trend.py   # Plotly trend chart from CSV
lib/
  config.sh                 # Reads nightly-config.json into env vars
  deploy.sh                 # CDK clone, deploy, parse outputs
  benchmark.sh              # OSB run logic (workload + cluster mode aware)
  results.sh                # CSV aggregation + S3 upload
  metrics.sh                # CloudWatch metric publishing
  teardown.sh               # Stack destroy
  lock.sh                   # File-based locking
```
