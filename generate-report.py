#!/usr/bin/env python3
"""
generate-report.py — Generate an AI-powered nightly benchmark report using Amazon Bedrock (Claude)
and post it to Slack.

Usage:
  python3 generate-report.py --bucket <S3_BUCKET> --slack-webhook <WEBHOOK_URL>
  python3 generate-report.py --bucket <S3_BUCKET> --dry-run  # Print report without posting

Requires:
  pip install boto3
"""

import argparse
import json
import csv
import io
import os
import subprocess
import sys
from datetime import datetime, timezone

try:
    import boto3
except ImportError:
    print("ERROR: boto3 not installed. Run: pip install boto3")
    sys.exit(1)


def s3_read(bucket, key):
    """Read an S3 object as string. Returns None if not found."""
    try:
        s3 = boto3.client("s3")
        obj = s3.get_object(Bucket=bucket, Key=key)
        return obj["Body"].read().decode("utf-8")
    except Exception as e:
        print(f"  [WARN] Could not read s3://{bucket}/{key}: {e}")
        return None


def get_latest_results(bucket, workload):
    """Get the last 7 rows for each engine from the indexing throughput CSV."""
    csv_key = f"nightly/indexing-throughput-{workload}.csv"
    content = s3_read(bucket, csv_key)
    if not content:
        return None

    reader = csv.DictReader(io.StringIO(content))
    rows = list(reader)

    # Get last N rows per engine
    engines = {}
    for row in rows:
        engine = row.get("engine", "unknown")
        if engine not in engines:
            engines[engine] = []
        engines[engine].append(row)

    # Keep last 7 per engine
    for engine in engines:
        engines[engine] = engines[engine][-7:]

    return engines


def get_today_results(bucket, workload):
    """Get only today's results."""
    csv_key = f"nightly/indexing-throughput-{workload}.csv"
    content = s3_read(bucket, csv_key)
    if not content:
        return []

    reader = csv.DictReader(io.StringIO(content))
    rows = list(reader)

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    today_rows = [r for r in rows if r.get("date", "").startswith(today)]
    return today_rows


def call_bedrock_comparison(log_content, csv_content, workload, suffix, model_id):
    """Prompt 1: Engine-wise comparison using full benchmark logs + CSV results.
    
    Feeds the complete benchmark log (cluster settings, index settings, _cat/indices, 
    errors) plus the full CSV results for all 3 engines into the model.
    Produces a per-engine comparison report with settings validation.
    """
    bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")

    mode_label = "Remote Store (segment replication, multi-node)" if suffix == "-remote" else "Single-Node (local disk, no replication)"

    prompt = f"""You are a performance engineering analyst reviewing an OpenSearch indexing benchmark.

**Workload:** {workload}
**Cluster Mode:** {mode_label}

The benchmark ran 3 storage engines on the same workload:
- **Parquet**: Columnar storage (DataFusion-based, PPL queries)
- **ParquetLucene**: Parquet primary + Lucene secondary index (hybrid)
- **Lucene**: Standard OpenSearch (baseline)

Below is the FULL benchmark log (contains PRE/POST cluster health, opensearch.yml settings, 
index settings, _cat/indices output, and OSB run commands for all 3 engines) followed by 
the complete CSV results.

YOUR TASK — produce a structured report with these sections:

**1. Settings Validation** (per engine):
- What data format is configured? (composite.primary_data_format, pluggable.dataformat)
- Is replication enabled? (replication.type, number_of_replicas)
- Cluster health before and after?
- Any misconfigurations or unexpected settings?

**2. Results Summary** (table format):
- Engine | Mean Throughput (docs/s) | Median | Max | Error Rate | Store Size | Doc Count
- Include ALL metrics from the CSV, not just throughput

**3. Parquet vs Lucene Comparison**:
- Parquet/Lucene ratio (X.Xx faster)
- ParquetLucene/Lucene ratio
- Storage efficiency comparison (store size per doc)

**4. Issues & Observations**:
- Any engine that failed (error_rate > 0, status != success)
- Any engine that didn't start (0 docs indexed)
- Settings that look wrong for the cluster mode
- One-line verdict: PASS / PARTIAL / FAIL

Use markdown. Be precise with numbers. Under 2000 characters.

--- BENCHMARK LOG ---
{log_content}

--- CSV RESULTS (all 3 engines) ---
{csv_content}
"""

    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 2500,
        "messages": [{"role": "user", "content": prompt}],
    })

    response = bedrock.invoke_model(
        modelId=model_id, contentType="application/json",
        accept="application/json", body=body,
    )
    return json.loads(response["body"].read())["content"][0]["text"]


def call_bedrock_trend(trend_data, model_id):
    """Prompt 2: 7-day trend analysis per engine."""
    bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")

    prompt = f"""You are a performance engineering analyst. Analyze the 7-day throughput trend 
for each engine and identify regressions or improvements.

Engines:
- **Parquet**: Columnar storage
- **ParquetLucene**: Hybrid (parquet + lucene secondary)
- **Lucene**: Standard OpenSearch baseline

Your task:
1. For each engine, state: IMPROVING / STABLE / DEGRADING (with % change from first to last valid run)
2. Flag any days with 0.00 docs/s as "failed run" (don't include in trend calculation)
3. Note if any engine has fewer than 3 valid data points (insufficient data for trend)
4. If there's a significant change (>10%), highlight it

Use markdown formatting. Be concise — under 800 characters.

Historical data (last 7 runs per engine):
{trend_data}
"""

    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 1000,
        "messages": [{"role": "user", "content": prompt}],
    })

    response = bedrock.invoke_model(
        modelId=model_id, contentType="application/json",
        accept="application/json", body=body,
    )
    return json.loads(response["body"].read())["content"][0]["text"]


def post_to_slack(webhook_url, message):
    """Post a message to Slack via API token or webhook."""
    # Check if it's a token (xoxe/xoxp/xoxb) or webhook URL
    if webhook_url.startswith("xox"):
        # Use Slack API with token
        channel = os.environ.get("SLACK_CHANNEL", "harish-test-nightly")
        payload = json.dumps({"channel": channel, "text": message})
        result = subprocess.run(
            ["curl", "-s", "-X", "POST", "https://slack.com/api/chat.postMessage",
             "-H", f"Authorization: Bearer {webhook_url}",
             "-H", "Content-type: application/json",
             "--data", payload],
            capture_output=True, text=True
        )
        response = result.stdout
        if '"ok":true' in response:
            print("✅ Report posted to Slack")
        else:
            print(f"WARNING: Slack post may have failed: {response}")
    else:
        # Use webhook URL
        payload = json.dumps({"text": message})
        result = subprocess.run(
            ["curl", "-s", "-X", "POST", "-H", "Content-type: application/json",
             "--data", payload, webhook_url],
            capture_output=True, text=True
        )
        if result.returncode != 0 or "ok" not in result.stdout.lower():
            print(f"WARNING: Slack post may have failed: {result.stdout} {result.stderr}")
        else:
            print("✅ Report posted to Slack")


def main():
    parser = argparse.ArgumentParser(description="Generate nightly benchmark report")
    parser.add_argument("--bucket", required=True, help="S3 bucket name")
    parser.add_argument("--workload", default="", help="Specific workload (clickbench or http_logs). Empty = all.")
    parser.add_argument("--suffix", default="", help="Suffix like -remote. Empty = single-node.")
    parser.add_argument("--run-id", default="", help="Run ID for S3 path (e.g., nightly-clickbench-run-20260524_213057)")
    parser.add_argument("--slack-webhook", help="Slack incoming webhook URL")
    parser.add_argument("--model", default="us.anthropic.claude-opus-4-5-20251101-v1:0",
                        help="Bedrock model ID")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print report without posting to Slack")
    parser.add_argument("--output", help="Save report to file")
    args = parser.parse_args()

    print("📊 Generating nightly benchmark report...")
    print(f"   Bucket: {args.bucket}")
    print(f"   Model:  {args.model}")
    print(f"   Workload: {args.workload or 'all'}")
    print(f"   Suffix: {args.suffix or '(none)'}")

    # 1. Determine workloads
    if args.workload:
        workloads = [args.workload]
    else:
        workloads = ["clickbench", "http_logs"]

    print(f"\n📋 Workloads: {workloads}, Suffix: '{args.suffix}'")

    # 2. Call Bedrock — two specialized prompts
    print(f"\n🤖 Calling Bedrock ({args.model})...")

    # --- Prompt 1: Engine comparison from logs + CSV ---
    # Read the benchmark log for this workload+mode
    log_file = os.path.expanduser(f"~/nightly-{args.workload}{args.suffix}.log")
    if os.path.isfile(log_file):
        with open(log_file, "r") as f:
            log_content = f.read()
        print(f"  Log file: {log_file} ({len(log_content)} chars)")
    else:
        log_content = "(Log file not found)"
        print(f"  WARNING: Log file not found: {log_file}")

    # Read all 3 engine CSV result files
    csv_parts = []
    for engine in ["parquet", "parquetLucene", "lucene"]:
        csv_name = f"{args.workload}{args.suffix}"
        csv_file = f"/tmp/nightly-result-{engine}-{args.workload}.csv"
        if os.path.isfile(csv_file):
            with open(csv_file, "r") as f:
                csv_parts.append(f"=== {engine} CSV ===\n{f.read()}")
        else:
            csv_parts.append(f"=== {engine} CSV ===\n(not found: {csv_file})")
    csv_content = "\n\n".join(csv_parts)

    print("  [1/2] Engine comparison (from logs + CSV)...")
    try:
        comparison = call_bedrock_comparison(
            log_content, csv_content, args.workload, args.suffix, model_id=args.model
        )
    except Exception as e:
        comparison = f"(Failed to generate comparison: {e})"
        print(f"  ERROR: {e}")

    # --- Prompt 2: Trend analysis from S3 historical CSV ---
    # Build trend data string
    trend_parts = []
    for workload in workloads:
        csv_name = f"{workload}{args.suffix}"
        history = get_latest_results(args.bucket, csv_name)
        if history:
            trend_parts.append(f"Workload: {workload}")
            for engine, rows in history.items():
                trend_parts.append(f"  {engine}:")
                for r in rows:
                    trend_parts.append(f"    {r.get('date','?')[:10]}: {float(r.get('mean_throughput',0)):.2f} docs/s")
    trend_str = "\n".join(trend_parts) if trend_parts else "No historical data."

    print("  [2/2] Trend analysis...")
    try:
        trend = call_bedrock_trend(trend_str, model_id=args.model)
    except Exception as e:
        trend = f"(Failed to generate trend: {e})"
        print(f"  ERROR: {e}")

    # Assemble final report (markdown)
    report_md = f"{comparison}\n\n---\n\n### 📈 7-Day Trend\n\n{trend}"

    # Wrap in HTML
    mode_label = "Remote Store" if args.suffix == "-remote" else "Single-Node"
    workload_label = args.workload or "All Workloads"
    date_str = datetime.now(timezone.utc).strftime('%Y-%m-%d')
    
    full_report = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Nightly Report — {workload_label} | {mode_label} | {date_str}</title>
<style>
body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 900px; margin: 40px auto; padding: 0 20px; line-height: 1.6; color: #333; }}
h1 {{ color: #1a1a2e; border-bottom: 2px solid #e94560; padding-bottom: 10px; }}
h2, h3 {{ color: #16213e; }}
table {{ border-collapse: collapse; width: 100%; margin: 16px 0; }}
th, td {{ border: 1px solid #ddd; padding: 8px 12px; text-align: left; }}
th {{ background: #16213e; color: white; }}
tr:nth-child(even) {{ background: #f9f9f9; }}
code {{ background: #f4f4f4; padding: 2px 6px; border-radius: 3px; font-size: 0.9em; }}
pre {{ background: #1a1a2e; color: #e0e0e0; padding: 16px; border-radius: 6px; overflow-x: auto; }}
hr {{ border: none; border-top: 1px solid #eee; margin: 30px 0; }}
.header {{ background: linear-gradient(135deg, #1a1a2e, #16213e); color: white; padding: 20px 30px; border-radius: 8px; margin-bottom: 30px; }}
.header h1 {{ color: white; border: none; margin: 0; }}
.header p {{ color: #ccc; margin: 5px 0 0 0; }}
.pass {{ color: #27ae60; font-weight: bold; }}
.fail {{ color: #e74c3c; font-weight: bold; }}
</style>
</head>
<body>
<div class="header">
<h1>🌙 Nightly Benchmark Report</h1>
<p>{date_str} &nbsp;|&nbsp; {workload_label} &nbsp;|&nbsp; {mode_label}</p>
</div>

{report_md}

<hr>
<p style="color:#999; font-size:0.85em;">Generated by opensearch-nightly-benchmark via Amazon Bedrock (Claude Opus 4.5)</p>
</body>
</html>"""

    # 3. Print report to stdout
    print("\n" + "=" * 60)
    print(full_report)
    print("=" * 60)

    # 4. Save to file if requested
    if args.output:
        with open(args.output, "w") as f:
            f.write(full_report)
        print(f"\n💾 Report saved to {args.output}")

    # 5. Upload to S3
    if args.run_id:
        # Structure: runs/nightly-clickbench/ or runs/nightly-clickbench-remote/ then run_id/report.html
        group_folder = f"nightly-{args.workload}{args.suffix}" if args.workload else "nightly"
        s3_key = f"runs/{group_folder}/{args.run_id}/report.html"
    else:
        report_name = f"nightly-report-{args.workload or 'all'}{args.suffix}-{datetime.now(timezone.utc).strftime('%Y%m%d')}.html"
        s3_key = f"nightly/reports/{report_name}"
    try:
        s3 = boto3.client("s3")
        s3.put_object(Bucket=args.bucket, Key=s3_key, Body=full_report.encode("utf-8"), ContentType="text/html")
        print(f"\n☁️  Report uploaded to s3://{args.bucket}/{s3_key}")
    except Exception as e:
        print(f"\nWARNING: Failed to upload report to S3: {e}")

    # 6. Post to Slack (disabled — waiting for webhook approval)
    # if args.slack_webhook and not args.dry_run:
    #     print("\n📤 Posting to Slack...")
    #     post_to_slack(args.slack_webhook, full_report)
    # elif args.dry_run:
    #     print("\n[DRY RUN] Skipping Slack post.")
    # elif not args.slack_webhook:
    #     print("\n[INFO] No --slack-webhook provided. Skipping Slack post.")


if __name__ == "__main__":
    main()
