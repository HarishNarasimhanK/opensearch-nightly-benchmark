# OpenSearch Nightly Indexing Benchmark

Automated pipeline that deploys 3 OpenSearch engines (Parquet, Lucene, ParquetLucene) via CDK, runs indexing benchmarks, collects results to S3, and tears down on next run.

Supports two cluster topologies, selected via the `--remote` flag:

| Mode | Topology | Replication | Storage |
|---|---|---|---|
| Default (no flag) | Single-node per engine | None (replicas=0) | Local disk |
| `--remote` | 3 managers + N data nodes per engine | Segment replication | S3 remote store |

Each mode runs in isolation — separate CDK stacks, separate S3 paths, separate CSVs and trend charts. You can run both modes (single-node + remote) in the same execution and they produce parallel result sets you can compare.

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

### Single-node only (original path)

```bash
# One workload at a time
nohup bash ~/nightly-repo/nightly-benchmark.sh --workload=clickbench > ~/nightly-adhoc-clickbench.log 2>&1 &
nohup bash ~/nightly-repo/nightly-benchmark.sh --workload=http_logs > ~/nightly-adhoc-http_logs.log 2>&1 &

# Both workloads sequentially (single-node only)
nohup bash ~/nightly-repo/run-all-workloads.sh --no-remote > ~/run-all-no-remote.log 2>&1 &
```

### Remote store / multi-node (segment replication)

```bash
# One workload at a time with remote store
nohup bash ~/nightly-repo/nightly-benchmark.sh --workload=clickbench --remote > ~/nightly-adhoc-clickbench-remote.log 2>&1 &
nohup bash ~/nightly-repo/nightly-benchmark.sh --workload=http_logs --remote > ~/nightly-adhoc-http_logs-remote.log 2>&1 &

# Both workloads sequentially (remote store only)
nohup bash ~/nightly-repo/run-all-workloads.sh --remote-only > ~/run-all-remote.log 2>&1 &
```

### All 4 combinations (default for `run-all-workloads.sh`)

Runs in this order: `clickbench` → `http_logs` → `clickbench-remote` → `http_logs-remote`

```bash
nohup bash ~/nightly-repo/run-all-workloads.sh > ~/run-all.log 2>&1 &
tail -f ~/run-all.log
```

## Nightly Loop Mode

Runs forever, sleeping `runIntervalHours` between runs. Loops all 4 combinations by default.

```bash
screen -S nightly
bash ~/nightly-repo/run-all-workloads.sh --nightly
# Detach: Ctrl+A, D
```

Loop options:
```bash
bash run-all-workloads.sh --nightly                # All 4 combos in a loop
bash run-all-workloads.sh --nightly --remote-only  # Only remote variants in a loop
bash run-all-workloads.sh --nightly --no-remote    # Only single-node variants in a loop
```

## What It Does

For each workload + cluster mode combination:

1. Destroys any existing stack for the same combination (idempotent)
2. Clones CDK repo + workload repos (parquet, lucene, indexed_parquet branches)
3. Deploys CDK stack:
   - **Single-node mode**: 1 instance per engine (Parquet, Lucene, ParquetLucene) + Builder
   - **Remote store mode**: 3 cluster managers + N data nodes per engine + ALB + S3 remote store bucket + Builder
4. Waits for all 3 clusters to be green
5. Runs OSB indexing benchmark against all 3 engines:
   - **Single-node mode**: `replicas=0`, no replication type
   - **Remote store mode**: `number_of_shards`/`number_of_replicas` from config, `replication_type=SEGMENT`
6. Stores CSV results to S3 and publishes CloudWatch metrics
7. Generates trend chart HTML → S3
8. Triggers data-folder upload to S3 from each data node (via flag file)

## Configuration

Edit `nightly-config.json`:

| Key | Description | Default |
|-----|-------------|---------|
| `parquetRepo` / `parquetBranch` | OpenSearch repo+branch for parquet engine | — |
| `luceneRepo` / `luceneBranch` | OpenSearch repo+branch for lucene engine | — |
| `*WorkloadRepo` / `*WorkloadBranch` | OSB workload repos per engine | — |
| `workload` | Workload name (clickbench / http_logs) | `clickbench` |
| `ingestPercentage` | % of dataset to ingest (100 = full) | `100` |
| `s3Bucket` | Results bucket | — |
| `runIntervalHours` | Sleep between nightly runs (clamped to [4, 24]) | `24` |
| `dataNodeCount` | Data nodes per engine cluster (used by `--remote` only) | `3` |
| `numberOfShards` | Shards per index (used by `--remote` only) | `1` |
| `numberOfReplicas` | Replicas per shard (used by `--remote` only). Must be `< dataNodeCount` | `1` |

## Results

Single-node and remote store runs produce **separate** result sets so you can compare them side by side.

### Single-node results

- **S3 CSV**: `s3://<bucket>/nightly/indexing-throughput-clickbench.csv`
- **S3 HTML**: `s3://<bucket>/nightly/nightly-indexing-trend-clickbench.html`
- **CloudWatch logs**: `/opensearch/nightly-clickbench/`
- **Stack name**: `OpenSearchCodeGuruStack-nightly-clickbench`
- **Run ID prefix**: `nightly-clickbench`

### Remote store results

- **S3 CSV**: `s3://<bucket>/nightly/indexing-throughput-clickbench-remote.csv`
- **S3 HTML**: `s3://<bucket>/nightly/nightly-indexing-trend-clickbench-remote.html`
- **CloudWatch logs**: `/opensearch/nightly-clickbench-remote/`
- **Stack name**: `OpenSearchCodeGuruStack-nightly-clickbench-remote`
- **Run ID prefix**: `nightly-clickbench-remote`
- **Remote store bucket**: created by CDK, name like `opensearchcodegurustack-remotestorebucket-...`
- **Remote store contents**: segments + translog + cluster state for all 3 engines under `<RUN_ID>/<engine>/...`

### Common to both

- **CloudWatch metrics namespace**: `OpenSearch/Nightly`
- **Node stats**: `s3://<bucket>/runs/{RUN_ID}/node-stats/{engine}/...`

## Remote Store — How It Works

When `--remote` is passed:

1. The deploy passes `-c remoteStoreEnabled=true -c clusterMode=multi -c dataNodeCount=N` to the CDK
2. The CDK creates an S3 bucket (with auto-delete on `cdk destroy` and 30-day lifecycle expiry)
3. The CDK adds remote store settings to `opensearch.yml` on every node:
   ```yaml
   s3.client.default.region: us-east-1
   node.attr.remote_store.segment.repository: my-s3-repo
   node.attr.remote_store.translog.repository: my-s3-repo
   node.attr.remote_store.state.repository: my-s3-repo
   cluster.remote_store.state.enabled: true
   node.attr.remote_store.repository.my-s3-repo.type: s3
   node.attr.remote_store.repository.my-s3-repo.settings.bucket: <CDK-CREATED-BUCKET>
   node.attr.remote_store.repository.my-s3-repo.settings.base_path: <RUN_ID>/<engine>
   ```
4. The CDK builds the `repository-s3` plugin and includes it in the engine tar.gz
5. OpenSearch authenticates to S3 via the EC2 instance profile (no access keys, no keystore)
6. Indexes are created with `index.replication.type: SEGMENT` and `number_of_replicas` from config
7. Primaries flush segments to S3; replicas pull from S3 via segment replication

This unlocks replicas for the Parquet engine, which doesn't support document replication. All 3 engines use segment replication for a fair comparison.

## CLI Reference

### `nightly-benchmark.sh`

```
bash nightly-benchmark.sh --workload=<NAME> [--remote] [--nightly]
```

| Flag | Description |
|---|---|
| `--workload=<NAME>` | Required. `clickbench` or `http_logs` |
| `--remote` | Optional. Use multi-node + remote store + segment replication |
| `--nightly` | Optional. Loop forever (sleep + repeat) |

### `run-all-workloads.sh`

```
bash run-all-workloads.sh [--remote-only | --no-remote] [--nightly]
```

| Flag | Description |
|---|---|
| (none) | Run all 4 combos: clickbench, http_logs, clickbench-remote, http_logs-remote |
| `--remote-only` | Only the 2 remote-store variants |
| `--no-remote` | Only the 2 single-node variants |
| `--nightly` | Loop forever (sleep + repeat) |

## Troubleshooting

```bash
# Check if a run is stuck (lock file exists)
ls -la /tmp/nightly-benchmark-*.lock

# Force remove all locks
rm -f /tmp/nightly-benchmark-*.lock

# Check CDK outputs from last deploy
cat ~/nightly-cdk-outputs.json

# Manually destroy a stuck stack
cd ~/cdk-repo
npx cdk destroy OpenSearchCodeGuruStack-nightly-clickbench --force
npx cdk destroy OpenSearchCodeGuruStack-nightly-clickbench-remote --force
npx cdk destroy OpenSearchCodeGuruStack-nightly-http-logs --force
npx cdk destroy OpenSearchCodeGuruStack-nightly-http-logs-remote --force

# If `cdk.out` is locked by another CDK process, kill it first
ps aux | grep -E "cdk|run-all|nightly-benchmark" | grep -v grep
pkill -9 -f run-all-workloads
pkill -9 -f "node.*cdk"

# Cancel a stuck CloudFormation stack (CREATE_IN_PROGRESS)
aws cloudformation cancel-update-stack --stack-name <STACK> --region us-east-1
aws cloudformation delete-stack --stack-name <STACK> --region us-east-1
```

## File Structure

```
nightly-benchmark.sh        # Main entrypoint (one workload + cluster mode)
run-all-workloads.sh        # Orchestrator: runs all 4 combos sequentially
nightly-config.json         # All config (repos, branches, bucket, cluster topology)
lib/
  config.sh                 # Reads nightly-config.json into env vars
  deploy.sh                 # CDK clone, deploy, parse outputs (ALB or private IP)
  benchmark.sh              # OSB run logic (workload + cluster mode aware)
  results.sh                # CSV aggregation + S3 upload (per cluster mode)
  metrics.sh                # CloudWatch metric publishing
  teardown.sh               # Stack destroy (per workload + cluster mode)
  lock.sh                   # File-based locking
generate-nightly-trend.py   # Plotly trend chart from CSV
generate-report.py          # AI summary report (posts to Slack)
```

## Stack and Resource Naming

For each `(workload, cluster_mode)` combination:

| Resource | Pattern | Example |
|---|---|---|
| CDK stack | `OpenSearchCodeGuruStack-nightly-{workload}[-remote]` | `OpenSearchCodeGuruStack-nightly-clickbench-remote` |
| CSV | `nightly/indexing-throughput-{workload}[-remote].csv` | `nightly/indexing-throughput-clickbench-remote.csv` |
| HTML | `nightly/nightly-indexing-trend-{workload}[-remote].html` | `nightly/nightly-indexing-trend-clickbench-remote.html` |
| Run ID prefix | `nightly-{workload}[-remote]` | `nightly-clickbench-remote` |
| CloudWatch log group | `/opensearch/nightly-{workload}[-remote]/...` | `/opensearch/nightly-clickbench-remote/parquet/runtime` |
| Lock file | `/tmp/nightly-benchmark-{workload}.lock` | `/tmp/nightly-benchmark-clickbench.lock` |
| Adhoc log | `~/nightly-adhoc-{workload}[-remote].log` | `~/nightly-adhoc-clickbench-remote.log` |

Workload underscores are converted to hyphens in stack names (e.g. `http_logs` → `http-logs`) for CloudFormation compliance.

## Validation

The remote store integration was end-to-end validated against the Parquet engine:

- **100M ClickBench docs** ingested in ~20 min on a 3-data-node multi-node cluster
- **1 shard, 2 replicas** all reached `STARTED` state (no `UNASSIGNED`)
- **18.1 GB** of segments + parquet files replicated to all 3 nodes via S3
- **No `TranslogCorruptedException`** errors (the failure mode without remote store)
- **Parquet primary doc count display** is blank in `_cat/shards` due to a Parquet engine quirk; `_stats/docs` confirms doc count on both primary and replicas

See `~/REMOTE-STORE-VALIDATION.md` for the full validation log with curl commands and responses.

## Design Decisions

### Instance Profile (not IAM user with access keys)

OpenSearch authenticates to the remote store S3 bucket via the **EC2 instance profile** that the CDK attaches to each node. The `repository-s3` plugin auto-discovers credentials via the EC2 instance metadata service (IMDS) and rotates them automatically.

| Aspect | Instance Profile | IAM User + Access Keys |
|---|---|---|
| Credential rotation | Automatic (every few hours) | Manual |
| Storage | None (in-memory, IMDS) | On disk or in keystore |
| Leak blast radius | Bound to instance lifetime | Indefinite until revoked |
| Setup | CDK grants `bucket.grantReadWrite(role)` | Create user, generate keys, install in OS keystore |

Instance profile is the AWS-recommended pattern for any compute that lives inside AWS. We avoid the access key path because keys would have to be persisted somewhere on disk or in the OpenSearch keystore, which adds operational risk for no benefit.

### SSE-S3 (not KMS)

The remote store bucket uses **server-side encryption with S3-managed keys (SSE-S3)** rather than KMS.

| Aspect | SSE-S3 | KMS (SSE-KMS) |
|---|---|---|
| Cost | Free | $1/key/month + $0.03/10k requests |
| Setup | Zero config | Create CMK, grant permissions, configure plugin |
| `cdk destroy` delay | Immediate | 7–30 day pending-deletion window on the CMK |
| Key control | None (AWS-managed) | Full (rotation, access logging, revocation) |
| Compliance | Meets AES-256 at-rest | Meets stricter regulated workloads |

For an ephemeral benchmarking bucket that is created and destroyed every nightly run, the KMS pending-deletion window blocks `cdk destroy` cleanup. SSE-S3 has no such delay and gives us the same AES-256 at-rest guarantee. We are not subject to a compliance regime that requires customer-managed keys for this data.

### `--remote` is opt-in (both paths preserved)

The original single-node path is preserved as the default. `--remote` adds a parallel multi-node + remote-store path with its own stack name, S3 paths, CSV, HTML, and CloudWatch log group. The two modes never collide and produce side-by-side results so historical single-node trend data stays intact.

### Segment replication for all engines (no document replication)

When `--remote` is on, all 3 engines (Parquet, Lucene, ParquetLucene) use `index.replication.type: SEGMENT`. The Parquet engine cannot do document replication, so for a fair throughput comparison every engine uses the same replication strategy.

## Changelog

### 2026-05-21 — Remote store integration

- Added `--remote` CLI flag to `nightly-benchmark.sh` and `run-all-workloads.sh`
- `nightly-config.json` now carries `dataNodeCount`, `numberOfShards`, `numberOfReplicas` (defaults: 3, 1, 1)
- `lib/config.sh` parses cluster topology fields and validates `numberOfReplicas < dataNodeCount`
- `lib/deploy.sh` conditionally passes `-c remoteStoreEnabled=true -c clusterMode=multi -c dataNodeCount=N` when `--remote` is on
- `lib/deploy.sh` (`parse_cdk_outputs`) tries ALB endpoints first, falls back to private IPs for single-node mode
- `lib/deploy.sh` switches the CDK `runIdPrefix` to include `-remote` suffix when remote store is enabled
- `lib/benchmark.sh` (`run_benchmark`) passes `replication_type=SEGMENT`, `number_of_shards`, `number_of_replicas` in OSB workload-params when `--remote` is on
- `lib/results.sh` writes to `indexing-throughput-{workload}-remote.csv` (separate from single-node CSV)
- `lib/teardown.sh` bug fix: now uses `OpenSearchCodeGuruStack-${NIGHTLY_STACK_SUFFIX}` instead of hardcoded `OpenSearchCodeGuruStack-nightly`
- `nightly-benchmark.sh` sets `NIGHTLY_STACK_SUFFIX=nightly-{workload}-remote` when `--remote` is on, giving every resource (stack, CW logs, S3 paths, lock files, adhoc logs) a distinct namespace
- `run-all-workloads.sh` rewritten to run 4 sequential combos by default (`clickbench`, `http_logs`, `clickbench-remote`, `http_logs-remote`); `--remote-only` and `--no-remote` flags subset the run list
- Trend chart generation now writes `nightly-indexing-trend-{workload}-remote.html` for remote runs

### CDK side (depends on `mustang-infra` repo)

- New `remoteStoreEnabled` context flag in `bin/app.ts` (default `false`)
- `lib/opensearch-codeguru-stack.ts` conditionally creates an S3 bucket (SSE-S3, `autoDeleteObjects`, 30-day lifecycle expiry) and grants R/W to all engine instance roles
- `scripts/user-data-builder.sh` builds and installs the `repository-s3` plugin into the engine tar.gz when the flag is on
- `scripts/user-data-{parquet,lucene,parquetLucene}.sh` append remote-store settings to `opensearch.yml` with isolated `base_path: <RUN_ID>/<engine>` per engine

## References

- Spec: `.kiro/specs/nightly-remote-store-integration/design.md`
- Validation log: `~/REMOTE-STORE-VALIDATION.md`
- CDK deep dive: `~/MAIN-BRANCH-DEEP-DIVE.md`
