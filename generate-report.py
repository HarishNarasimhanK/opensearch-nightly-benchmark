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


def build_context(bucket):
    """Build the full context string for the AI prompt."""
    context_parts = []

    context_parts.append("=" * 60)
    context_parts.append("NIGHTLY BENCHMARK RESULTS")
    context_parts.append("=" * 60)

    for workload in ["clickbench", "http_logs"]:
        context_parts.append(f"\n{'─' * 40}")
        context_parts.append(f"WORKLOAD: {workload}")
        context_parts.append(f"{'─' * 40}")

        # Today's results
        today = get_today_results(bucket, workload)
        if today:
            context_parts.append(f"\nToday's results ({len(today)} rows):")
            for row in today:
                engine = row.get("engine", "?")
                mean_tp = row.get("mean_throughput", "0")
                median_tp = row.get("median_throughput", "0")
                max_tp = row.get("max_throughput", "0")
                error_rate = row.get("error_rate", "0")
                status = row.get("status", "?")
                context_parts.append(
                    f"  {engine}: mean={mean_tp} docs/s, median={median_tp}, "
                    f"max={max_tp}, error_rate={error_rate}%, status={status}"
                )
        else:
            context_parts.append("\n  No results for today.")

        # Historical trend (last 7 runs per engine)
        history = get_latest_results(bucket, workload)
        if history:
            context_parts.append(f"\nHistorical trend (last 7 runs per engine):")
            for engine, rows in history.items():
                means = [float(r.get("mean_throughput", 0)) for r in rows]
                dates = [r.get("date", "?")[:10] for r in rows]
                context_parts.append(f"  {engine}:")
                for d, m in zip(dates, means):
                    context_parts.append(f"    {d}: {m:.2f} docs/s")

    return "\n".join(context_parts)


def call_bedrock(context, model_id="us.anthropic.claude-sonnet-4-20250514"):
    """Call Amazon Bedrock with the context and return the report."""
    bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")

    prompt = f"""You are a performance engineering analyst. Generate a concise nightly benchmark report 
for the OpenSearch Parquet vs Lucene indexing benchmark.

The benchmark compares 3 storage engines:
- **Parquet**: Columnar storage format (DataFusion-based, PPL queries)
- **ParquetLucene**: Parquet primary + Lucene secondary index (hybrid)
- **Lucene**: Standard OpenSearch (baseline)

Format the report for Slack (use Slack mrkdwn: *bold*, `code`, bullet points with •).
Keep it under 2000 characters for Slack message limits.

Include:
1. A one-line summary (pass/fail, any regressions)
2. Today's throughput comparison table (all 3 engines × workloads)
3. *Improvement over Lucene*: Calculate and show how much faster Parquet and ParquetLucene are compared to Lucene (e.g., "Parquet is 2.5x faster than Lucene"). Use the formula: engine_throughput / lucene_throughput.
4. Trend analysis (improving/degrading/stable vs previous runs)
5. Notable observations or anomalies

Here is the data:

{context}
"""

    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 2000,
        "messages": [{"role": "user", "content": prompt}],
    })

    response = bedrock.invoke_model(
        modelId=model_id,
        contentType="application/json",
        accept="application/json",
        body=body,
    )

    result = json.loads(response["body"].read())
    return result["content"][0]["text"]


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

    # 1. Build context from S3 data
    context = build_context(args.bucket)
    print(f"\n📋 Context ({len(context)} chars):")
    print(context)

    # 2. Call Bedrock
    print(f"\n🤖 Calling Bedrock ({args.model})...")
    report = call_bedrock(context, model_id=args.model)

    # 3. Add header
    header = f"🌙 *Nightly Benchmark Report* — {datetime.now(timezone.utc).strftime('%Y-%m-%d')}\n\n"
    full_report = header + report

    print("\n" + "=" * 60)
    print(full_report)
    print("=" * 60)

    # 4. Save to file if requested
    if args.output:
        with open(args.output, "w") as f:
            f.write(full_report)
        print(f"\n💾 Report saved to {args.output}")

    # 5. Upload to S3
    s3_key = f"nightly/reports/nightly-report-{datetime.now(timezone.utc).strftime('%Y%m%d')}.md"
    try:
        s3 = boto3.client("s3")
        s3.put_object(Bucket=args.bucket, Key=s3_key, Body=full_report.encode("utf-8"), ContentType="text/markdown")
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
