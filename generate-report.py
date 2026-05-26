#!/usr/bin/env python3
"""
generate-report.py — Generate a polished HTML benchmark report from nightly CSV results.

Usage:
  # Per-mode report (called after each workload run):
  python3 generate-report.py --bucket <S3_BUCKET> --workload clickbench --suffix ""
  python3 generate-report.py --bucket <S3_BUCKET> --workload clickbench --suffix "-remote"

  # Aggregated report (called at end of run-all-workloads.sh):
  python3 generate-report.py --bucket <S3_BUCKET> --aggregate

Requires: pip install boto3
"""

import argparse
import csv
import io
import json
import os
import sys
from datetime import datetime, timezone

try:
    import boto3
except ImportError:
    print("ERROR: boto3 not installed. Run: pip install boto3")
    sys.exit(1)


# ═══════════════════════════════════════════════════════════════════════════════
# HTML Template (dark theme, same style as nightly-report-20260526.html)
# ═══════════════════════════════════════════════════════════════════════════════

CSS = """
:root { --bg: #0f1117; --card: #1a1d27; --border: #2d3140; --text: #e4e7ec; --muted: #8b92a5; --accent: #4f8cff; --green: #34d399; --red: #f87171; --orange: #fbbf24; }
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: var(--bg); color: var(--text); line-height: 1.6; padding: 2rem; }
h1 { font-size: 1.8rem; margin-bottom: 0.5rem; }
h2 { font-size: 1.4rem; margin: 2rem 0 1rem; color: var(--accent); border-bottom: 1px solid var(--border); padding-bottom: 0.5rem; }
h3 { font-size: 1.1rem; margin: 1.5rem 0 0.75rem; color: var(--muted); }
.subtitle { color: var(--muted); margin-bottom: 2rem; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 1.5rem; margin-bottom: 1.5rem; }
table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
th, td { padding: 0.6rem 0.8rem; text-align: left; border-bottom: 1px solid var(--border); }
th { color: var(--muted); font-weight: 600; text-transform: uppercase; font-size: 0.75rem; letter-spacing: 0.5px; }
td { font-variant-numeric: tabular-nums; }
.engine-parquet { color: var(--green); font-weight: 600; }
.engine-parquetLucene { color: var(--orange); font-weight: 600; }
.engine-lucene { color: var(--accent); font-weight: 600; }
.ratio-high { color: var(--green); font-weight: 700; }
.ratio-mid { color: var(--orange); font-weight: 700; }
.ratio-base { color: var(--muted); font-weight: 700; }
.config-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; }
@media (max-width: 900px) { .config-grid { grid-template-columns: 1fr; } }
.setting-row { display: flex; justify-content: space-between; padding: 0.4rem 0; border-bottom: 1px solid var(--border); }
.setting-key { color: var(--muted); font-size: 0.85rem; }
.setting-val { font-family: 'SF Mono', 'Fira Code', monospace; font-size: 0.85rem; }
.highlight-box { background: #1e293b; border-left: 3px solid var(--accent); padding: 1rem 1.5rem; margin: 1rem 0; border-radius: 0 6px 6px 0; }
.takeaway { margin: 0.5rem 0; padding-left: 1rem; border-left: 2px solid var(--green); }
.takeaway-warn { border-left-color: var(--orange); }
code { background: #2d3140; padding: 0.15rem 0.4rem; border-radius: 3px; font-size: 0.85rem; }
.section-divider { border: none; border-top: 2px solid var(--border); margin: 3rem 0; }
.status-pass { color: var(--green); } .status-fail { color: var(--red); }
"""


# ═══════════════════════════════════════════════════════════════════════════════
# S3 Helpers
# ═══════════════════════════════════════════════════════════════════════════════

def s3_read(bucket, key):
    """Read an S3 object as string. Returns None if not found."""
    try:
        s3 = boto3.client("s3")
        obj = s3.get_object(Bucket=bucket, Key=key)
        return obj["Body"].read().decode("utf-8")
    except Exception as e:
        print(f"  [WARN] Could not read s3://{bucket}/{key}: {e}")
        return None


def s3_upload(bucket, key, content, content_type="text/html"):
    """Upload content to S3."""
    try:
        s3 = boto3.client("s3")
        s3.put_object(Bucket=bucket, Key=key, Body=content.encode("utf-8"), ContentType=content_type)
        print(f"  ☁️  Uploaded to s3://{bucket}/{key}")
    except Exception as e:
        print(f"  WARNING: Failed to upload to S3: {e}")


def get_history(bucket, workload_suffix):
    """Get last 7 rows per engine from the indexing throughput CSV in S3."""
    csv_key = f"nightly/indexing-throughput-{workload_suffix}.csv"
    content = s3_read(bucket, csv_key)
    if not content:
        return {}
    reader = csv.DictReader(io.StringIO(content))
    engines = {}
    for row in reader:
        engine = row.get("engine", "unknown")
        engines.setdefault(engine, []).append(row)
    for engine in engines:
        engines[engine] = engines[engine][-7:]
    return engines


# ═══════════════════════════════════════════════════════════════════════════════
# Data Collection — read today's results from local CSV files
# ═══════════════════════════════════════════════════════════════════════════════

def read_local_csv(engine, workload):
    """Read the local CSV result file for a given engine+workload."""
    csv_file = f"/tmp/nightly-result-{engine}-{workload}.csv"
    if not os.path.isfile(csv_file):
        return None
    with open(csv_file, "r") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    return rows


def extract_metrics(csv_rows):
    """Extract key metrics from OSB CSV output."""
    metrics = {}
    if not csv_rows:
        return metrics
    for row in csv_rows:
        task = row.get("Task", row.get("task", ""))
        metric = row.get("Metric", row.get("metric", ""))
        value = row.get("Value", row.get("value", "0"))
        try:
            val = float(value)
        except (ValueError, TypeError):
            val = 0.0

        # Only consider index-append rows (not global metrics)
        if "index-append" not in task.lower():
            continue

        # Use exact metric name matches to avoid 99 vs 99.9 collisions
        if metric == "Min Throughput":
            metrics["min_throughput"] = val
        elif metric == "Mean Throughput":
            metrics["mean_throughput"] = val
        elif metric == "Median Throughput":
            metrics["median_throughput"] = val
        elif metric == "Max Throughput":
            metrics["max_throughput"] = val
        elif metric == "50th percentile latency":
            metrics["p50_latency_ms"] = val
        elif metric == "99th percentile latency":
            metrics["p99_latency_ms"] = val
        elif metric == "error rate":
            metrics["error_rate"] = val
    return metrics


# ═══════════════════════════════════════════════════════════════════════════════
# HTML Generation — deterministic, no AI needed for structure
# ═══════════════════════════════════════════════════════════════════════════════

def fmt(n):
    """Format number with commas."""
    if n == 0:
        return "—"
    if n >= 1000:
        return f"{n:,.0f}"
    return f"{n:.2f}"


def ratio_class(r):
    if r >= 1.5:
        return "ratio-high"
    elif r >= 1.1:
        return "ratio-mid"
    return "ratio-base"


def build_results_table(results_by_engine):
    """Build an HTML table from engine results dict."""
    lucene_tp = results_by_engine.get("lucene", {}).get("mean_throughput", 1) or 1

    rows_html = ""
    for engine in ["parquet", "parquetLucene", "lucene"]:
        m = results_by_engine.get(engine, {})
        if not m:
            rows_html += f'<tr><td class="engine-{engine}">{engine}</td>' + '<td>—</td>' * 7 + '<td>—</td></tr>\n'
            continue
        ratio = m.get("mean_throughput", 0) / lucene_tp if lucene_tp else 0
        rc = ratio_class(ratio)
        err = m.get("error_rate", 0)
        err_str = f'{err:.2f}%' if err > 0 else "0%"
        rows_html += f'''<tr>
  <td class="engine-{engine}">{engine}</td>
  <td>{fmt(m.get("mean_throughput", 0))}</td>
  <td>{fmt(m.get("median_throughput", 0))}</td>
  <td>{fmt(m.get("min_throughput", 0))}</td>
  <td>{fmt(m.get("max_throughput", 0))}</td>
  <td>{fmt(m.get("p50_latency_ms", 0))}</td>
  <td>{fmt(m.get("p99_latency_ms", 0))}</td>
  <td>{err_str}</td>
  <td class="{rc}">{ratio:.2f}x</td>
</tr>\n'''

    return f"""<div class="card">
<table>
<thead>
<tr><th>Engine</th><th>Mean Throughput (docs/s)</th><th>Median</th><th>Min</th><th>Max</th><th>p50 Latency (ms)</th><th>p99 Latency (ms)</th><th>Error %</th><th>Ratio vs Lucene</th></tr>
</thead>
<tbody>
{rows_html}
</tbody>
</table>
</div>"""


def parse_log_sections(log_content):
    """Parse the benchmark log to extract real cluster health and index settings per engine."""
    import re

    engine_data = {}  # engine -> {cluster_health: {...}, index_settings: {...}}

    # Split by BENCHMARK headers
    benchmark_blocks = re.split(r'║\s+BENCHMARK:\s+(\w+)\s+/', log_content)
    # benchmark_blocks[0] = preamble, then alternating: engine_name, block_content

    for i in range(1, len(benchmark_blocks) - 1, 2):
        engine = benchmark_blocks[i].strip()
        block = benchmark_blocks[i + 1] if i + 1 < len(benchmark_blocks) else ""

        data = {"cluster_health": {}, "index_settings": {}}

        # Extract [PRE] Cluster Health JSON.
        # JSON ends at the next section header (either another bracketed [TAG]
        # or the heavy box drawing chars used for benchmark boundaries).
        pre_health_match = re.search(
            r'\[PRE\] Cluster Health[^\n]*\n[─]+\n(\{.*?\})\s*\n', block, re.DOTALL
        )
        if pre_health_match:
            try:
                data["cluster_health"] = json.loads(pre_health_match.group(1).strip())
            except (json.JSONDecodeError, ValueError):
                pass

        # Extract [POST] Index Settings JSON
        post_settings_match = re.search(
            r'\[POST\] Index Settings[^\n]*\n[─]+\n(\{.*?\})\s*\n', block, re.DOTALL
        )
        if post_settings_match:
            try:
                data["index_settings"] = json.loads(post_settings_match.group(1).strip())
            except (json.JSONDecodeError, ValueError):
                # Sometimes it's truncated by `head -60`, just store raw for debug
                data["index_settings_raw"] = post_settings_match.group(1).strip()[:2000]

        engine_data[engine] = data

    return engine_data


def extract_index_settings_from_json(settings_json):
    """Extract key index settings from the _all/_settings API response."""
    result = {}
    if not settings_json or not isinstance(settings_json, dict):
        return result

    # Navigate into the first index's settings
    for index_name, index_data in settings_json.items():
        s = index_data.get("settings", {}).get("index", {})
        result["number_of_shards"] = s.get("number_of_shards", "?")
        result["number_of_replicas"] = s.get("number_of_replicas", "?")
        result["refresh_interval"] = s.get("refresh_interval", "?")

        # Pluggable dataformat — handle both flat-key and nested forms
        # Flat form (parquet engine):    "pluggable": {"dataformat": "composite", "dataformat.enabled": "true"}
        # Nested form (lucene engine):   "pluggable": {"dataformat": {"enabled": "false"}}
        # Also handle truly flat:        "pluggable.dataformat.enabled": "true" at index level
        pluggable = s.get("pluggable", {})
        enabled = "false"
        df_value = "—"
        if isinstance(pluggable, dict):
            df = pluggable.get("dataformat")
            if isinstance(df, dict):
                # Nested form
                enabled = str(df.get("enabled", "false"))
            elif isinstance(df, str):
                # Flat form: dataformat is a string ("composite")
                df_value = df
                enabled = str(pluggable.get("dataformat.enabled", "true"))
            # Also check the dotted key directly
            if "dataformat.enabled" in pluggable:
                enabled = str(pluggable.get("dataformat.enabled"))
        # Top-level dotted keys (rare)
        if s.get("pluggable.dataformat.enabled"):
            enabled = str(s.get("pluggable.dataformat.enabled"))
        result["pluggable.dataformat.enabled"] = enabled

        # Composite primary/secondary
        composite = s.get("composite", {})
        if isinstance(composite, dict):
            result["composite.primary_data_format"] = composite.get("primary_data_format", "—")
            result["composite.secondary_data_formats"] = composite.get("secondary_data_formats", "—")
        else:
            result["composite.primary_data_format"] = "—"
            result["composite.secondary_data_formats"] = "—"

        # Replication
        replication = s.get("replication", {})
        result["replication.type"] = replication.get("type", "DOCUMENT") if isinstance(replication, dict) else "DOCUMENT"

        # Remote store
        remote = s.get("remote_store", {})
        result["remote_store.enabled"] = remote.get("enabled", "false") if isinstance(remote, dict) else "false"

        # Parquet
        parquet = s.get("parquet", {})
        result["parquet.bloom_filter_enabled"] = parquet.get("bloom_filter_enabled", "—") if isinstance(parquet, dict) else "—"

        # Translog — may be flat ("translog.durability") or nested ({"durability": ...})
        translog = s.get("translog", {})
        if isinstance(translog, dict):
            result["translog.durability"] = translog.get("durability", "?")
        else:
            result["translog.durability"] = "?"

        break  # Only need first index

    return result


def build_setup_section(log_content, workload):
    """Build the benchmark setup section from REAL log data."""
    engine_data = parse_log_sections(log_content) if log_content else {}

    # Build per-engine settings from real data
    engines_settings = {}
    for engine in ["parquet", "parquetLucene", "lucene"]:
        ed = engine_data.get(engine, {})
        settings_json = ed.get("index_settings", {})
        engines_settings[engine] = extract_index_settings_from_json(settings_json)

    # Cluster health from first engine that has it
    cluster_health = {}
    for engine in ["parquet", "parquetLucene", "lucene"]:
        ch = engine_data.get(engine, {}).get("cluster_health", {})
        if ch:
            cluster_health = ch
            break

    # Build cluster health card
    if cluster_health:
        ch_status = cluster_health.get("status", "unknown")
        ch_nodes = cluster_health.get("number_of_nodes", "?")
        ch_data_nodes = cluster_health.get("number_of_data_nodes", "?")
        ch_class = "status-pass" if ch_status == "green" else "status-fail"
        cluster_html = f"""<div class="card">
<h3>Cluster Health (from API)</h3>
<div class="setting-row"><span class="setting-key">Status</span><span class="setting-val {ch_class}">{ch_status}</span></div>
<div class="setting-row"><span class="setting-key">Nodes</span><span class="setting-val">{ch_nodes} total, {ch_data_nodes} data</span></div>
<div class="setting-row"><span class="setting-key">Cluster Name</span><span class="setting-val">{cluster_health.get("cluster_name", "?")}</span></div>
<div class="setting-row"><span class="setting-key">Active Shards</span><span class="setting-val">{cluster_health.get("active_shards", "?")}</span></div>
<div class="setting-row"><span class="setting-key">Relocating Shards</span><span class="setting-val">{cluster_health.get("relocating_shards", "?")}</span></div>
<div class="setting-row"><span class="setting-key">Unassigned Shards</span><span class="setting-val">{cluster_health.get("unassigned_shards", "?")}</span></div>
</div>"""
    else:
        cluster_html = '<div class="card"><h3>Cluster Health</h3><p>Not available in log.</p></div>'

    # Build index settings table from real data
    settings_keys = [
        "pluggable.dataformat.enabled", "composite.primary_data_format",
        "composite.secondary_data_formats", "refresh_interval", "translog.durability",
        "parquet.bloom_filter_enabled", "number_of_shards", "number_of_replicas",
        "replication.type", "remote_store.enabled"
    ]

    rows_html = ""
    for key in settings_keys:
        pq_val = engines_settings.get("parquet", {}).get(key, "—")
        pql_val = engines_settings.get("parquetLucene", {}).get(key, "—")
        lu_val = engines_settings.get("lucene", {}).get(key, "—")
        rows_html += f"<tr><td>{key}</td><td>{pq_val}</td><td>{pql_val}</td><td>{lu_val}</td></tr>\n"

    index_html = f"""<div class="card">
<h3>Index Settings per Engine (from API — POST benchmark)</h3>
<table>
<thead><tr><th>Setting</th><th>Parquet</th><th>ParquetLucene</th><th>Lucene</th></tr></thead>
<tbody>
{rows_html}
</tbody>
</table>
</div>"""

    return f"""<div class="config-grid">{cluster_html}</div>\n{index_html}"""


def build_takeaways(results_by_engine, workload, is_remote):
    """Generate key takeaways based on the numbers."""
    pq = results_by_engine.get("parquet", {}).get("mean_throughput", 0)
    pql = results_by_engine.get("parquetLucene", {}).get("mean_throughput", 0)
    lu = results_by_engine.get("lucene", {}).get("mean_throughput", 0)

    if lu == 0:
        return '<div class="card"><p>Insufficient data for takeaways.</p></div>'

    pq_ratio = pq / lu if lu else 0
    pql_ratio = pql / lu if lu else 0

    mode_str = "Remote Store" if is_remote else "Single Node"
    items = []

    if pq_ratio > 1:
        items.append(f'<div class="takeaway"><p><strong>Parquet is {pq_ratio:.2f}x faster than Lucene</strong> — {fmt(pq)} vs {fmt(lu)} docs/s on {workload} ({mode_str}).</p></div>')
    if pql_ratio > 1:
        items.append(f'<div class="takeaway"><p><strong>ParquetLucene is {pql_ratio:.2f}x faster than Lucene</strong> — the secondary lucene index adds overhead but still outperforms vanilla Lucene.</p></div>')

    # Check for errors
    for engine in ["parquet", "parquetLucene", "lucene"]:
        err = results_by_engine.get(engine, {}).get("error_rate", 0)
        if err > 0:
            items.append(f'<div class="takeaway takeaway-warn"><p><strong>{engine} had {err:.2f}% error rate</strong> — possible bulk rejections under backpressure.</p></div>')

    return f'<div class="card">\n{"".join(items)}\n</div>'


def build_cross_config_table(all_results):
    """Build a local vs remote throughput comparison table."""
    rows_html = ""
    for engine in ["parquet", "parquetLucene", "lucene"]:
        for workload in ["clickbench", "http_logs"]:
            local_tp = all_results.get(f"{workload}", {}).get(engine, {}).get("mean_throughput", 0)
            remote_tp = all_results.get(f"{workload}-remote", {}).get(engine, {}).get("mean_throughput", 0)
            if local_tp > 0 and remote_tp > 0:
                drop = ((remote_tp - local_tp) / local_tp) * 100
                rows_html += f'<tr><td class="engine-{engine}">{engine}</td><td>{workload}</td><td>{fmt(local_tp)}</td><td>{fmt(remote_tp)}</td><td>{drop:+.0f}%</td></tr>\n'
            elif local_tp > 0:
                rows_html += f'<tr><td class="engine-{engine}">{engine}</td><td>{workload}</td><td>{fmt(local_tp)}</td><td>—</td><td>—</td></tr>\n'

    if not rows_html:
        return ""

    return f"""<div class="card">
<h3>Local vs Remote Store Throughput Comparison</h3>
<table>
<thead><tr><th>Engine</th><th>Workload</th><th>Local (docs/s)</th><th>Remote (docs/s)</th><th>Change</th></tr></thead>
<tbody>{rows_html}</tbody>
</table>
</div>"""


def build_trend_section(bucket):
    """Build a 7-day trend table from S3 historical data."""
    modes = ["clickbench", "http_logs", "clickbench-remote", "http_logs-remote"]
    all_trends = {}
    for mode in modes:
        history = get_history(bucket, mode)
        if history:
            all_trends[mode] = history

    if not all_trends:
        return '<div class="card"><p>No historical data available for trend analysis.</p></div>'

    rows_html = ""
    for mode, engines in all_trends.items():
        for engine, data_points in engines.items():
            valid = [float(r.get("mean_throughput", 0)) for r in data_points if float(r.get("mean_throughput", 0)) > 0]
            if len(valid) >= 2:
                change = ((valid[-1] - valid[0]) / valid[0]) * 100
                trend = "IMPROVING" if change > 5 else ("DEGRADING" if change < -5 else "STABLE")
                trend_class = "status-pass" if trend == "IMPROVING" else ("status-fail" if trend == "DEGRADING" else "")
                rows_html += f'<tr><td>{mode}</td><td class="engine-{engine}">{engine}</td><td>{len(valid)}</td><td>{fmt(valid[-1])}</td><td class="{trend_class}">{trend} ({change:+.1f}%)</td></tr>\n'
            elif len(valid) == 1:
                rows_html += f'<tr><td>{mode}</td><td class="engine-{engine}">{engine}</td><td>1</td><td>{fmt(valid[0])}</td><td>Insufficient data</td></tr>\n'

    if not rows_html:
        return ""

    return f"""<div class="card">
<h3>7-Day Throughput Trend</h3>
<table>
<thead><tr><th>Mode</th><th>Engine</th><th>Data Points</th><th>Latest (docs/s)</th><th>Trend</th></tr></thead>
<tbody>{rows_html}</tbody>
</table>
</div>"""


# ═══════════════════════════════════════════════════════════════════════════════
# Report Assembly
# ═══════════════════════════════════════════════════════════════════════════════

def generate_per_mode_report(workload, suffix, bucket, run_id):
    """Generate a report for a single mode (e.g., clickbench or clickbench-remote)."""
    is_remote = suffix == "-remote"
    mode_label = f"{workload}{suffix}"
    mode_title = f"{workload.upper()} — {'Remote Store (Multi-Node)' if is_remote else 'Single Node (Local)'}"
    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # Read the benchmark log (contains real cluster health + index settings)
    log_file = os.path.expanduser(f"~/nightly-{mode_label}.log")
    log_content = ""
    if os.path.isfile(log_file):
        with open(log_file, "r") as f:
            log_content = f.read()
        print(f"  Log file: {log_file} ({len(log_content)} chars)")
    else:
        print(f"  WARNING: Log not found: {log_file}")

    # Collect results from CSV
    results = {}
    for engine in ["parquet", "parquetLucene", "lucene"]:
        csv_rows = read_local_csv(engine, workload)
        if csv_rows:
            results[engine] = extract_metrics(csv_rows)

    # Build HTML sections
    setup_html = build_setup_section(log_content, workload)
    results_html = build_results_table(results)
    takeaways_html = build_takeaways(results, workload, is_remote)

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Nightly Report — {mode_title} | {date_str}</title>
<style>{CSS}</style>
</head>
<body>
<h1>🔥 OpenSearch Nightly Benchmark</h1>
<p class="subtitle">{date_str} | <code>opensearch-project/OpenSearch@main</code> | {mode_title}</p>
<hr class="section-divider">
<h2>📋 Benchmark Setup</h2>
{setup_html}
<hr class="section-divider">
<h2>📊 Results — {mode_title}</h2>
{results_html}
<h2>🔑 Key Takeaways</h2>
{takeaways_html}
<hr class="section-divider">
<p style="color: var(--muted); text-align: center; font-size: 0.8rem;">
  Generated: {date_str} | Run: {run_id or 'adhoc'}
</p>
</body>
</html>"""

    # Upload to S3
    if run_id and bucket:
        s3_key = f"runs/nightly-{mode_label}/{run_id}/report.html"
        s3_upload(bucket, s3_key, html)

    return html, results


def generate_aggregate_report(bucket):
    """Generate one combined report for all 4 modes."""
    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    modes = [
        ("clickbench", ""),
        ("http_logs", ""),
        ("clickbench", "-remote"),
        ("http_logs", "-remote"),
    ]

    all_results = {}  # key: "clickbench" or "clickbench-remote" → {engine: metrics}
    sections = []

    for workload, suffix in modes:
        is_remote = suffix == "-remote"
        mode_key = f"{workload}{suffix}" if suffix else workload
        mode_title = f"{workload.upper()} — {'Remote Store (Multi-Node)' if is_remote else 'Single Node (Local)'}"

        # Read the benchmark log for this mode
        log_file = os.path.expanduser(f"~/nightly-{mode_key}.log")
        log_content = ""
        if os.path.isfile(log_file):
            with open(log_file, "r") as f:
                log_content = f.read()

        results = {}
        for engine in ["parquet", "parquetLucene", "lucene"]:
            csv_rows = read_local_csv(engine, workload)
            if csv_rows:
                results[engine] = extract_metrics(csv_rows)
        all_results[mode_key] = results

        if results:
            setup_html = build_setup_section(log_content, workload)
            results_html = build_results_table(results)
            takeaways_html = build_takeaways(results, workload, is_remote)
            sections.append(f"""
<h2>📊 {mode_title}</h2>
<h3>Setup</h3>
{setup_html}
<h3>Results</h3>
{results_html}
<h3>Takeaways</h3>
{takeaways_html}
""")
        else:
            sections.append(f'<h2>📊 {mode_title}</h2>\n<div class="card"><p>No results available.</p></div>')

    # Cross-config comparison
    cross_html = build_cross_config_table(all_results)

    # Trend
    trend_html = build_trend_section(bucket) if bucket else ""

    body = "\n<hr class='section-divider'>\n".join(sections)

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Nightly Benchmark Report — {date_str} (Aggregated)</title>
<style>{CSS}</style>
</head>
<body>
<h1>🔥 OpenSearch Nightly Benchmark Report</h1>
<p class="subtitle">{date_str} | <code>opensearch-project/OpenSearch@main</code> | All Modes | r8g.2xlarge</p>
<hr class="section-divider">
{body}
<hr class="section-divider">
<h2>🔄 Local vs Remote Store Comparison</h2>
{cross_html}
<h2>📈 7-Day Trend</h2>
{trend_html}
<hr class="section-divider">
<p style="color: var(--muted); text-align: center; font-size: 0.8rem;">
  Generated: {date_str} | Source: opensearch-project/OpenSearch@main
</p>
</body>
</html>"""

    # Upload to S3
    if bucket:
        s3_key = f"nightly/reports/report-{datetime.now(timezone.utc).strftime('%Y%m%d')}.html"
        s3_upload(bucket, s3_key, html)

    return html


# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="Generate nightly benchmark HTML report")
    parser.add_argument("--bucket", required=True, help="S3 bucket name")
    parser.add_argument("--workload", default="", help="Workload name (clickbench or http_logs)")
    parser.add_argument("--suffix", default="", help="Suffix like -remote")
    parser.add_argument("--run-id", default="", help="Run ID for S3 path")
    parser.add_argument("--aggregate", action="store_true",
                        help="Generate one aggregated report for all 4 modes")
    parser.add_argument("--output", help="Save report to local file")
    args = parser.parse_args()

    if args.aggregate:
        print("📊 Generating AGGREGATED nightly report...")
        html = generate_aggregate_report(args.bucket)
    else:
        if not args.workload:
            print("ERROR: --workload required when not using --aggregate")
            sys.exit(1)
        print(f"📊 Generating report for {args.workload}{args.suffix}...")
        html, _ = generate_per_mode_report(
            args.workload, args.suffix, args.bucket, args.run_id
        )

    # Save locally
    if args.output:
        with open(args.output, "w") as f:
            f.write(html)
        print(f"💾 Report saved to {args.output}")
    elif not args.aggregate and not args.output:
        # Print to stdout if no output specified
        print(html[:500] + "...\n(truncated)")

    print("✅ Done!")


if __name__ == "__main__":
    main()
