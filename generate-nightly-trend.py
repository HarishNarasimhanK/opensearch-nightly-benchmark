#!/usr/bin/env python3
"""generate-nightly-trend.py — Plotly HTML trend chart generator.

Reads the nightly indexing throughput CSV and generates a self-contained HTML file
with a Plotly.js line chart showing Parquet vs Lucene indexing throughput over time.

Usage:
  python3 generate-nightly-trend.py --csv <path> --output <path>
"""

import argparse
import csv
import json
import sys


def load_csv(filepath):
    """Load CSV into list of dicts."""
    rows = []
    with open(filepath, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def compute_rolling_average(values, window=7):
    """Compute rolling average. Returns None for points with < window preceding values."""
    averages = []
    for i in range(len(values)):
        if i < window:
            averages.append(None)
        else:
            window_vals = [v for v in values[i - window:i] if v is not None]
            averages.append(sum(window_vals) / len(window_vals) if window_vals else None)
    return averages


def detect_regressions(throughputs, rolling_avgs, threshold=0.10):
    """Identify indices where throughput drops >threshold from rolling average."""
    regressions = []
    for i, (tp, avg) in enumerate(zip(throughputs, rolling_avgs)):
        if avg is not None and tp is not None and avg > 0:
            if tp < avg * (1 - threshold):
                regressions.append(i)
    return regressions


def generate_html(rows, output_path, workload="clickbench"):
    """Generate self-contained Plotly HTML trend chart."""
    # Separate by engine
    pq_rows = [r for r in rows if r.get("engine") in ("parquet", "datafusion")]
    lu_rows = [r for r in rows if r.get("engine") == "lucene"]
    pql_rows = [r for r in rows if r.get("engine") == "parquetLucene"]

    # Extract data — use mean_throughput for the trend line
    pq_dates = [r["date"] for r in pq_rows]
    pq_throughputs = [
        float(r["mean_throughput"]) if r.get("status") == "success" and r.get("mean_throughput") and float(r["mean_throughput"]) > 0 else None
        for r in pq_rows
    ]
    pq_modes = [r.get("mode", "nightly") for r in pq_rows]

    lu_dates = [r["date"] for r in lu_rows]
    lu_throughputs = [
        float(r["mean_throughput"]) if r.get("status") == "success" and r.get("mean_throughput") and float(r["mean_throughput"]) > 0 else None
        for r in lu_rows
    ]
    lu_modes = [r.get("mode", "nightly") for r in lu_rows]

    pql_dates = [r["date"] for r in pql_rows]
    pql_throughputs = [
        float(r["mean_throughput"]) if r.get("status") == "success" and r.get("mean_throughput") and float(r["mean_throughput"]) > 0 else None
        for r in pql_rows
    ]
    pql_modes = [r.get("mode", "nightly") for r in pql_rows]

    # Compute regressions on valid (non-None) values
    pq_valid = [t for t in pq_throughputs if t is not None]
    lu_valid = [t for t in lu_throughputs if t is not None]
    pql_valid = [t for t in pql_throughputs if t is not None]
    pq_rolling = compute_rolling_average(pq_valid)
    lu_rolling = compute_rolling_average(lu_valid)
    pql_rolling = compute_rolling_average(pql_valid)
    pq_regressions = detect_regressions(pq_valid, pq_rolling)
    lu_regressions = detect_regressions(lu_valid, lu_rolling)

    # Build hover text
    pq_hover = [
        f"Date: {r['date']}<br>Engine: parquet<br>"
        f"Mean: {r.get('mean_throughput','')} docs/s<br>"
        f"Min: {r.get('min_throughput','')} | Max: {r.get('max_throughput','')}<br>"
        f"Error Rate: {r.get('error_rate','')}%<br>"
        f"p50 Latency: {r.get('p50_latency_ms','')} ms<br>"
        f"p99 Latency: {r.get('p99_latency_ms','')} ms<br>"
        f"Run: {r.get('run_id','')}<br>"
        f"Duration: {r.get('duration_sec','')}s"
        for r in pq_rows
    ]
    lu_hover = [
        f"Date: {r['date']}<br>Engine: lucene<br>"
        f"Mean: {r.get('mean_throughput','')} docs/s<br>"
        f"Min: {r.get('min_throughput','')} | Max: {r.get('max_throughput','')}<br>"
        f"Error Rate: {r.get('error_rate','')}%<br>"
        f"p50 Latency: {r.get('p50_latency_ms','')} ms<br>"
        f"p99 Latency: {r.get('p99_latency_ms','')} ms<br>"
        f"Run: {r.get('run_id','')}<br>"
        f"Duration: {r.get('duration_sec','')}s"
        for r in lu_rows
    ]

    # Marker symbols: circle for nightly, diamond for adhoc
    pq_symbols = ["diamond" if m == "adhoc" else "circle" for m in pq_modes]
    lu_symbols = ["diamond" if m == "adhoc" else "circle" for m in lu_modes]

    # Build Plotly traces
    traces = []

    # Parquet trace
    traces.append({
        "x": pq_dates,
        "y": [t if t else None for t in pq_throughputs],
        "mode": "lines+markers",
        "name": "Parquet",
        "line": {"color": "#FF6B35", "width": 2},
        "marker": {"color": "#FF6B35", "size": 8, "symbol": pq_symbols},
        "text": pq_hover,
        "hoverinfo": "text",
        "connectgaps": False,
    })

    # Lucene trace
    traces.append({
        "x": lu_dates,
        "y": [t if t else None for t in lu_throughputs],
        "mode": "lines+markers",
        "name": "Lucene",
        "line": {"color": "#004E89", "width": 2},
        "marker": {"color": "#004E89", "size": 8, "symbol": lu_symbols},
        "text": lu_hover,
        "hoverinfo": "text",
        "connectgaps": False,
    })

    # ParquetLucene trace
    pql_symbols = ["diamond" if m == "adhoc" else "circle" for m in pql_modes]
    pql_hover = [
        f"Date: {r['date']}<br>Engine: parquetLucene<br>"
        f"Mean: {float(r.get('mean_throughput', 0)):.0f} docs/s<br>"
        f"Mode: {r.get('mode', 'nightly')}"
        for r in pql_rows
    ]
    traces.append({
        "x": pql_dates,
        "y": [t if t else None for t in pql_throughputs],
        "mode": "lines+markers",
        "name": "ParquetLucene",
        "line": {"color": "#2ECC71", "width": 2},
        "marker": {"color": "#2ECC71", "size": 8, "symbol": pql_symbols},
        "text": pql_hover,
        "hoverinfo": "text",
        "connectgaps": False,
    })

    # Regression markers for Parquet
    if pq_regressions:
        valid_dates = [pq_dates[i] for i in range(len(pq_dates)) if pq_throughputs[i] is not None]
        reg_dates = [valid_dates[i] for i in pq_regressions if i < len(valid_dates)]
        reg_values = [pq_valid[i] for i in pq_regressions if i < len(pq_valid)]
        traces.append({
            "x": reg_dates,
            "y": reg_values,
            "mode": "markers",
            "name": "Parquet Regression",
            "marker": {"color": "red", "size": 14, "symbol": "circle-open", "line": {"width": 3}},
            "hoverinfo": "text",
            "text": [f"REGRESSION: {v:.1f} docs/s" for v in reg_values],
        })

    # Regression markers for Lucene
    if lu_regressions:
        valid_dates = [lu_dates[i] for i in range(len(lu_dates)) if lu_throughputs[i] is not None]
        reg_dates = [valid_dates[i] for i in lu_regressions if i < len(valid_dates)]
        reg_values = [lu_valid[i] for i in lu_regressions if i < len(lu_valid)]
        traces.append({
            "x": reg_dates,
            "y": reg_values,
            "mode": "markers",
            "name": "Lucene Regression",
            "marker": {"color": "red", "size": 14, "symbol": "circle-open", "line": {"width": 3}},
            "hoverinfo": "text",
            "text": [f"REGRESSION: {v:.1f} docs/s" for v in reg_values],
        })

    layout = {
        "title": f"Nightly Indexing Throughput ({workload}): Parquet vs ParquetLucene vs Lucene",
        "xaxis": {"title": "Date", "type": "date"},
        "yaxis": {"title": "Mean Indexing Throughput (docs/sec)"},
        "legend": {"x": 0.01, "y": 0.99},
        "hovermode": "closest",
        "template": "plotly_white",
    }

    # Write self-contained HTML
    dataset_info = "ClickBench (100M docs)" if workload == "clickbench" else f"{workload} dataset"
    setup_info = f"""
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; padding: 16px 24px; background: #f8f9fa; border-bottom: 1px solid #dee2e6; font-size: 13px; color: #495057;">
      <h2 style="margin: 0 0 8px 0; font-size: 18px; color: #212529;">Nightly Indexing Benchmark ({workload}) — Parquet vs ParquetLucene vs Lucene</h2>
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 8px;">
        <div><b>Parquet/ParquetLucene Instance:</b> r8g.2xlarge (8 vCPU, 64GB RAM, ARM64)</div>
        <div><b>Lucene Instance:</b> r8g.2xlarge (8 vCPU, 64GB RAM, ARM64)</div>
        <div><b>Benchmark Client:</b> r8g.8xlarge (32 vCPU, 256GB RAM, ARM64)</div>
        <div><b>EBS:</b> 1000GB gp3, 12000 IOPS, 500 MB/s throughput</div>
        <div><b>JVM Heap:</b> Parquet/ParquetLucene: 16GB, Lucene: 32GB</div>
        <div><b>Dataset:</b> {dataset_info}</div>
        <div><b>Workload:</b> delete-index → create-index → index-append</div>
        <div><b>Shards:</b> 1 primary, 0 replicas</div>
        <div><b>Bulk Clients:</b> Parquet/ParquetLucene: 50, Lucene: 8</div>
        <div><b>Source:</b> opensearch-project/OpenSearch@main (all engines)</div>
        <div><b>Parquet:</b> parquet-only (secondary_data_formats=[])</div>
        <div><b>ParquetLucene:</b> parquet + lucene secondary (indexed_parquet)</div>
        <div><b>Lucene:</b> standard engine (pluggable.dataformat=false)</div>
        <div><b>Region:</b> us-east-1</div>
      </div>
      <div style="margin-top: 8px; font-size: 11px; color: #6c757d;">
        [●] Circle = nightly run &nbsp; [◆] Diamond = adhoc run &nbsp; [○] Red circle = regression (&gt;10% drop from 7-day avg)
      </div>
    </div>
    """

    html = f"""<!DOCTYPE html>
<html>
<head>
  <title>Nightly Indexing Throughput Trend</title>
  <script src="https://cdn.plot.ly/plotly-latest.min.js"></script>
</head>
<body style="margin:0;">
  {setup_info}
  <div id="chart" style="width:100%;height:80vh;"></div>
  <script>
    var data = {json.dumps(traces, default=str)};
    var layout = {json.dumps(layout)};
    Plotly.newPlot('chart', data, layout);
  </script>
</body>
</html>"""

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(html)

    print(f"Trend chart generated: {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Generate nightly indexing throughput trend chart")
    parser.add_argument("--csv", required=True, help="Path to indexing-throughput-{workload}.csv")
    parser.add_argument("--output", required=True, help="Output HTML file path")
    parser.add_argument("--workload", default=None, help="Workload name (auto-detected from CSV if not specified)")
    args = parser.parse_args()

    rows = load_csv(args.csv)
    if not rows:
        print("No data in CSV. Skipping chart generation.")
        sys.exit(0)

    # Auto-detect workload from CSV data or filename
    workload = args.workload
    if not workload:
        workload = rows[0].get("workload", "clickbench") if rows else "clickbench"

    generate_html(rows, args.output, workload=workload)


if __name__ == "__main__":
    main()
