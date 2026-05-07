#!/usr/bin/env python3
"""generate-nightly-trend.py — Plotly HTML trend chart generator.

Reads the nightly indexing throughput CSV and generates a self-contained HTML file
with a Plotly.js line chart showing DataFusion vs Lucene indexing throughput over time.

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


def generate_html(rows, output_path):
    """Generate self-contained Plotly HTML trend chart."""
    # Separate by engine
    df_rows = [r for r in rows if r.get("engine") == "datafusion"]
    lu_rows = [r for r in rows if r.get("engine") == "lucene"]

    # Extract data — use mean_throughput for the trend line
    df_dates = [r["date"] for r in df_rows]
    df_throughputs = [
        float(r["mean_throughput"]) if r.get("status") == "success" and r.get("mean_throughput") and float(r["mean_throughput"]) > 0 else None
        for r in df_rows
    ]
    df_modes = [r.get("mode", "nightly") for r in df_rows]

    lu_dates = [r["date"] for r in lu_rows]
    lu_throughputs = [
        float(r["mean_throughput"]) if r.get("status") == "success" and r.get("mean_throughput") and float(r["mean_throughput"]) > 0 else None
        for r in lu_rows
    ]
    lu_modes = [r.get("mode", "nightly") for r in lu_rows]

    # Compute regressions on valid (non-None) values
    df_valid = [t for t in df_throughputs if t is not None]
    lu_valid = [t for t in lu_throughputs if t is not None]
    df_rolling = compute_rolling_average(df_valid)
    lu_rolling = compute_rolling_average(lu_valid)
    df_regressions = detect_regressions(df_valid, df_rolling)
    lu_regressions = detect_regressions(lu_valid, lu_rolling)

    # Build hover text
    df_hover = [
        f"Date: {r['date']}<br>Engine: datafusion<br>"
        f"Mean: {r.get('mean_throughput','')} docs/s<br>"
        f"Min: {r.get('min_throughput','')} | Max: {r.get('max_throughput','')}<br>"
        f"Error Rate: {r.get('error_rate','')}%<br>"
        f"p50 Latency: {r.get('p50_latency_ms','')} ms<br>"
        f"p99 Latency: {r.get('p99_latency_ms','')} ms<br>"
        f"Run: {r.get('run_id','')}<br>"
        f"Duration: {r.get('duration_sec','')}s"
        for r in df_rows
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
    df_symbols = ["diamond" if m == "adhoc" else "circle" for m in df_modes]
    lu_symbols = ["diamond" if m == "adhoc" else "circle" for m in lu_modes]

    # Build Plotly traces
    traces = []

    # DataFusion trace
    traces.append({
        "x": df_dates,
        "y": [t if t else None for t in df_throughputs],
        "mode": "lines+markers",
        "name": "DataFusion",
        "line": {"color": "#FF6B35", "width": 2},
        "marker": {"color": "#FF6B35", "size": 8, "symbol": df_symbols},
        "text": df_hover,
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

    # Regression markers for DataFusion
    if df_regressions:
        valid_dates = [df_dates[i] for i in range(len(df_dates)) if df_throughputs[i] is not None]
        reg_dates = [valid_dates[i] for i in df_regressions if i < len(valid_dates)]
        reg_values = [df_valid[i] for i in df_regressions if i < len(df_valid)]
        traces.append({
            "x": reg_dates,
            "y": reg_values,
            "mode": "markers",
            "name": "DataFusion Regression",
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
        "title": "Nightly Indexing Throughput: DataFusion vs Lucene",
        "xaxis": {"title": "Date", "type": "date"},
        "yaxis": {"title": "Mean Indexing Throughput (docs/sec)"},
        "legend": {"x": 0.01, "y": 0.99},
        "hovermode": "closest",
        "template": "plotly_white",
    }

    # Write self-contained HTML
    setup_info = """
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; padding: 16px 24px; background: #f8f9fa; border-bottom: 1px solid #dee2e6; font-size: 13px; color: #495057;">
      <h2 style="margin: 0 0 8px 0; font-size: 18px; color: #212529;">Nightly Indexing Benchmark - DataFusion vs Lucene</h2>
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 8px;">
        <div><b>Instance:</b> r7g.2xlarge (8 vCPU, 64GB RAM, ARM64)</div>
        <div><b>EBS:</b> 500GB gp3, 6000 IOPS, 500 MB/s throughput</div>
        <div><b>JVM Heap:</b> 32GB</div>
        <div><b>Dataset:</b> ClickBench (100M docs)</div>
        <div><b>Workload:</b> index-append only (no queries)</div>
        <div><b>Shards:</b> 1 primary, 0 replicas</div>
        <div><b>Bulk Clients:</b> DataFusion: 50, Lucene: 8 (OSB side)</div>
        <div><b>DataFusion:</b> opensearch-project/OpenSearch main (Parquet engine)</div>
        <div><b>Lucene:</b> opensearch-project/OpenSearch main (standard engine)</div>
        <div><b>Region:</b> us-east-1</div>
      </div>
      <div style="margin-top: 8px; font-size: 11px; color: #6c757d;">
        [*] Circle = nightly run &nbsp; [&lt;&gt;] Diamond = adhoc run &nbsp; [O] Red circle = regression (&gt;10% drop from 7-day avg)
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
    parser.add_argument("--csv", required=True, help="Path to indexing-throughput.csv")
    parser.add_argument("--output", required=True, help="Output HTML file path")
    args = parser.parse_args()

    rows = load_csv(args.csv)
    if not rows:
        print("No data in CSV. Skipping chart generation.")
        sys.exit(0)

    generate_html(rows, args.output)


if __name__ == "__main__":
    main()
