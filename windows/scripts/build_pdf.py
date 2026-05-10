#!/usr/bin/env python3
"""build_pdf.py -- assemble a workload-baseline PDF from collected captures.

Reads:    %SNAPSHOT_DIR%\\YYYY-MM-DD\\HH-mm-{report.txt,data.json,chart.png}
Writes:   %OUTPUT_DIR%\\Workload-Baseline-Report-YYYY-MM-DD.pdf

Self-contained: builds matplotlib time-series chart, renders an HTML page,
then runs headless Chrome to print the HTML to PDF.

Environment variables:
    SNAPSHOT_DIR   default: %USERPROFILE%\\Workload-Baseline
    OUTPUT_DIR     default: %USERPROFILE%\\Desktop
    MIN_CAPTURE_TS optional, format YYYY-MM-DD_HH-MM; filter earlier captures
"""
import base64
import datetime as dt
import glob
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

os.environ.setdefault('MPLBACKEND', 'Agg')
import matplotlib  # noqa: E402

matplotlib.use('Agg')
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402


USERPROFILE = os.environ.get('USERPROFILE') or os.environ.get('HOME') or os.path.expanduser('~')
SNAPSHOT_DIR = os.environ.get('SNAPSHOT_DIR') or os.path.join(USERPROFILE, 'Workload-Baseline')
OUTPUT_DIR = os.environ.get('OUTPUT_DIR') or os.path.join(USERPROFILE, 'Desktop')
MIN_CAPTURE_TS = os.environ.get('MIN_CAPTURE_TS', '').strip()

CHROME_CANDIDATES = [
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    os.path.join(os.environ.get('LOCALAPPDATA', ''), r'Google\Chrome\Application\chrome.exe'),
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
]


def find_chrome() -> str | None:
    for p in CHROME_CANDIDATES:
        if p and os.path.isfile(p):
            return p
    for name in ('chrome', 'chrome.exe', 'msedge', 'msedge.exe'):
        path = shutil.which(name)
        if path:
            return path
    return None


def parse_min_ts(s: str) -> dt.datetime | None:
    if not s:
        return None
    try:
        d_str, t_str = s.split('_')
        h, m = t_str.split('-')
        return dt.datetime.strptime(f"{d_str} {h}:{m}", "%Y-%m-%d %H:%M")
    except Exception:
        return None


def load_captures(snapshot_dir: str, min_ts: dt.datetime | None) -> list[dict]:
    points = []
    pattern = os.path.join(snapshot_dir, '20*-*-*', '*-data.json')
    for path in sorted(glob.glob(pattern)):
        day = os.path.basename(os.path.dirname(path))
        fname = os.path.basename(path)
        time_str = fname.replace('-data.json', '')
        try:
            hh, mm = time_str.split('-')
            ts = dt.datetime.strptime(f"{day} {hh}:{mm}", "%Y-%m-%d %H:%M")
        except Exception:
            continue
        if min_ts and ts < min_ts:
            continue
        try:
            with open(path, 'r', encoding='utf-8') as fh:
                d = json.load(fh)
        except Exception:
            continue
        mem = d.get('memory_mb') or {}
        cpu = d.get('cpu') or {}
        gpu = d.get('gpu') or {}
        used_mb = mem.get('used')
        total_mb = mem.get('total')
        if used_mb is None or total_mb is None or total_mb == 0:
            continue
        points.append({
            'ts': ts,
            'used_gb': used_mb / 1024.0,
            'total_gb': total_mb / 1024.0,
            'unused_mb': mem.get('unused') or 0,
            'committed_pct': mem.get('committed_pct') or 0,
            'pages_per_sec': mem.get('pages_per_sec') or 0,
            'gpu_pct': gpu.get('device_util_pct') or 0,
            'cpu_busy': cpu.get('busy_pct') or 0,
            'cpu_idle': cpu.get('idle_pct') or 0,
            'chart_path': path.replace('-data.json', '-chart.png'),
            'host': d.get('host') or {},
        })
    points.sort(key=lambda p: p['ts'])
    return points


def build_chart(points: list[dict], out_path: str) -> tuple[dict, str]:
    used = [p['used_gb'] for p in points]
    gpu_vals = [p['gpu_pct'] for p in points]
    cpu_busy = [p['cpu_busy'] for p in points]
    committed = [p['committed_pct'] for p in points]

    total_gb = round((max(p['total_gb'] for p in points)) / 8) * 8 or 16

    stats = {
        'count': len(points),
        'used_min': min(used), 'used_max': max(used),
        'used_median': statistics.median(used),
        'committed_max': max(committed),
        'committed_median': statistics.median(committed),
        'pct_committed_above_80': 100 * sum(1 for v in committed if v >= 80) / len(committed),
        'pct_committed_above_90': 100 * sum(1 for v in committed if v >= 90) / len(committed),
        'gpu_max': max(gpu_vals) if gpu_vals else 0,
        'gpu_median': statistics.median(gpu_vals) if gpu_vals else 0,
        'pct_gpu_above_50': 100 * sum(1 for v in gpu_vals if v >= 50) / len(gpu_vals) if gpu_vals else 0,
        'cpu_median': statistics.median(cpu_busy),
        'cpu_max': max(cpu_busy),
        'pct_cpu_above_80': 100 * sum(1 for v in cpu_busy if v >= 80) / len(cpu_busy),
        'total_gb': total_gb,
    }

    plt.rcParams.update({
        'font.family': ['Segoe UI', 'Helvetica Neue', 'Arial', 'sans-serif'],
        'font.size': 10.5,
        'axes.spines.top': False,
        'axes.spines.right': False,
    })

    fig, (ax, ax2) = plt.subplots(
        2, 1, figsize=(10, 7.0),
        gridspec_kw={'height_ratios': [3, 2], 'hspace': 0.35},
    )

    ts = [p['ts'] for p in points]

    # Memory in use over time, with committed-% as secondary line
    ax.fill_between(ts, 0, used, color='#cc0000', alpha=0.18, zorder=2)
    ax.plot(ts, used, color='#cc0000', linewidth=1.6, marker='.', markersize=3,
            label='Physical memory in use (GB)', zorder=4)
    ax.axhline(y=total_gb, color='#bbb', linestyle=':', linewidth=0.8, alpha=0.8)
    ax.text(ts[-1], total_gb + 0.4, f' {total_gb:.0f} GB total RAM',
            color='#999', fontsize=8.5, ha='right', va='bottom')
    ax.set_ylim(0, total_gb + 4)
    ax.set_ylabel('Memory (GB)', fontsize=10, color='#333')
    ax.set_title('Memory pressure', fontsize=10.5, color='#333', loc='left',
                 pad=6, fontweight='600')
    ax.grid(axis='y', alpha=0.18, zorder=0)
    ax.legend(loc='upper left', frameon=False, fontsize=9)

    # CPU + GPU
    ax2.fill_between(ts, 0, gpu_vals, color='#0066cc', alpha=0.16, zorder=2)
    ax2.plot(ts, gpu_vals, color='#0066cc', linewidth=1.4, marker='.',
             markersize=3, label='GPU 3D utilization (%)', zorder=4)
    ax2.plot(ts, cpu_busy, color='#cc7700', linewidth=0.9, linestyle='--',
             alpha=0.85, label='CPU busy (%)', zorder=3)
    ax2.axhline(y=80, color='#cc0000', linestyle=':', linewidth=0.9, alpha=0.7)
    ax2.text(ts[0], 81, '  >80% = sustained chip-class pressure',
             color='#cc0000', fontsize=8.5, ha='left', va='bottom')
    ax2.set_ylim(0, 105)
    ax2.set_yticks([0, 25, 50, 75, 100])
    ax2.set_yticklabels(['0%', '25%', '50%', '75%', '100%'], fontsize=9, color='#333')
    ax2.set_ylabel('Compute load', fontsize=10, color='#333')
    ax2.set_title('Compute pressure (GPU + CPU)', fontsize=10.5, color='#333',
                  loc='left', pad=6, fontweight='600')
    ax2.grid(axis='y', alpha=0.18, zorder=0)
    ax2.legend(loc='upper left', frameon=False, fontsize=9)

    for axis in (ax, ax2):
        axis.xaxis.set_major_locator(mdates.AutoDateLocator())
        single_day = len({p['ts'].date() for p in points}) <= 1
        axis.xaxis.set_major_formatter(
            mdates.DateFormatter('%m-%d %H:%M' if single_day else '%m-%d')
        )
        plt.setp(axis.get_xticklabels(), rotation=0, ha='center', fontsize=9, color='#333')

    plt.tight_layout()
    plt.savefig(out_path, dpi=200, bbox_inches='tight', facecolor='white')
    plt.close()
    return stats, out_path


def build_html(points: list[dict], chart_png: str, stats: dict, tmp_dir: str) -> str:
    """Build an HTML page with the time-series chart and an appendix grid of chart PNGs."""
    with open(chart_png, 'rb') as fh:
        chart_b64 = base64.b64encode(fh.read()).decode()

    first_ts = points[0]['ts']
    last_ts = points[-1]['ts']
    days = (last_ts.date() - first_ts.date()).days + 1
    title_range = f"{first_ts:%Y-%m-%d} to {last_ts:%Y-%m-%d} ({days} day{'s' if days != 1 else ''})"

    host = points[-1].get('host') or {}
    subtitle = (
        f"{stats['count']} captures &middot; {host.get('computer','?')} "
        f"({host.get('os','?')[:48]})"
    )

    appendix_rows = []
    for p in points:
        chart_path = p.get('chart_path')
        if not chart_path or not os.path.isfile(chart_path):
            continue
        label = f"{p['ts']:%m-%d %H:%M}"
        appendix_rows.append(
            f'<div class="pair"><div class="pair-label">{label}</div>'
            f'<div class="pair-imgs"><div><img src="file:///{chart_path.replace(os.sep, "/")}"></div></div></div>'
        )
    appendix_html = '\n'.join(appendix_rows) or '<p><em>No per-capture chart PNGs found.</em></p>'

    html = f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>Workload Baseline Report</title>
<style>
  @page {{ size: A4 portrait; margin: 1.6cm 1.5cm 1.4cm 1.5cm; }}
  html {{ -webkit-print-color-adjust: exact; print-color-adjust: exact; }}
  body {{ font-family: 'Segoe UI', 'Helvetica Neue', Arial, sans-serif; color: #1a1a1a; margin: 0; line-height: 1.5; }}
  h1 {{ font-size: 15pt; font-weight: 600; margin: 0 0 4px 0; }}
  .subtitle {{ font-size: 10pt; color: #666; margin-bottom: 18px; }}
  .chart-wrap img {{ width: 100%; height: auto; display: block; margin-bottom: 14px; }}
  h2 {{ font-size: 10pt; font-weight: 600; margin: 18px 0 7px 0; color: #333; text-transform: uppercase; letter-spacing: 0.5px; }}
  .stats-grid {{ display: flex; gap: 16px; margin: 8px 0 14px 0; }}
  .stat {{ flex: 1; padding: 8px 10px; background: #f6f6f6; border-radius: 3px; }}
  .stat .v {{ font-size: 13pt; font-weight: 600; }}
  .stat .l {{ font-size: 8.5pt; color: #666; margin-top: 2px; line-height: 1.3; }}
  .footer {{ margin-top: 14px; font-size: 8pt; color: #888; line-height: 1.5; }}
  .pairs {{ display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px 14px; margin-top: 8px; }}
  .pair {{ break-inside: avoid; margin-bottom: 4px; }}
  .pair-label {{ font-size: 8pt; color: #333; margin-bottom: 3px; font-variant-numeric: tabular-nums; font-weight: 500; }}
  .pair-imgs img {{ width: 100%; height: auto; display: block; border: 1px solid #ccc; }}
</style>
</head><body>

<h1>Windows Workload Baseline -- {title_range}</h1>
<div class="subtitle">{subtitle}</div>

<div class="chart-wrap"><img src="data:image/png;base64,{chart_b64}"></div>

<div class="stats-grid">
  <div class="stat"><div class="v">{stats['committed_median']:.0f}%</div><div class="l">median memory-committed (range {min(p['committed_pct'] for p in points):.0f}-{stats['committed_max']:.0f}%)</div></div>
  <div class="stat"><div class="v">{stats['pct_committed_above_80']:.0f}%</div><div class="l">of captures with memory committed &gt; 80% (workload pressure)</div></div>
  <div class="stat"><div class="v">{stats['pct_committed_above_90']:.0f}%</div><div class="l">of captures with memory committed &gt; 90% (near limit)</div></div>
</div>
<div class="stats-grid">
  <div class="stat"><div class="v">{stats['gpu_median']:.0f}%</div><div class="l">median GPU 3D utilisation (peak {stats['gpu_max']:.0f}%)</div></div>
  <div class="stat"><div class="v">{stats['pct_gpu_above_50']:.0f}%</div><div class="l">of captures with GPU &gt; 50%</div></div>
  <div class="stat"><div class="v">{stats['pct_cpu_above_80']:.0f}%</div><div class="l">of captures with CPU &gt; 80% (median {stats['cpu_median']:.0f}%, peak {stats['cpu_max']:.0f}%)</div></div>
</div>

<div class="footer">
  <p>Total physical memory: {points[-1]['total_gb']:.0f} GB. Captures every 30 min while the machine is awake.</p>
  <p>Raw evidence: per-capture chart PNGs in the appendix that follows.</p>
</div>

<div style="page-break-before: always;"></div>
<h1 style="margin-top: 0;">Appendix -- {stats['count']} captures</h1>
<div class="subtitle">Chronological. Each thumbnail is the per-capture summary chart.</div>
<div class="pairs">
{appendix_html}
</div>

</body></html>
"""
    html_path = os.path.join(tmp_dir, 'report.html')
    with open(html_path, 'w', encoding='utf-8') as fh:
        fh.write(html)
    return html_path


def render_pdf(html_path: str, pdf_path: str, chrome: str, tmp_dir: str) -> None:
    profile = os.path.join(tmp_dir, 'chrome-profile')
    os.makedirs(profile, exist_ok=True)
    args = [
        chrome,
        '--headless=new',
        '--disable-gpu',
        '--no-pdf-header-footer',
        '--no-sandbox',
        '--allow-file-access-from-files',
        f'--user-data-dir={profile}',
        '--virtual-time-budget=60000',
        f'--print-to-pdf={pdf_path}',
        f'file:///{html_path.replace(os.sep, "/")}',
    ]
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 90
    while time.time() < deadline:
        if os.path.isfile(pdf_path) and os.path.getsize(pdf_path) > 0:
            time.sleep(1)
            break
        time.sleep(1)
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
    if not (os.path.isfile(pdf_path) and os.path.getsize(pdf_path) > 0):
        raise RuntimeError(f"Chrome did not produce a PDF at {pdf_path}")


def main() -> int:
    if not os.path.isdir(SNAPSHOT_DIR):
        print(f"ERROR: SNAPSHOT_DIR not found: {SNAPSHOT_DIR}", file=sys.stderr)
        return 1
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    min_ts = parse_min_ts(MIN_CAPTURE_TS)
    points = load_captures(SNAPSHOT_DIR, min_ts)
    if not points:
        print(f"ERROR: no parseable captures in {SNAPSHOT_DIR}", file=sys.stderr)
        return 1
    print(f"Parsed {len(points)} captures")

    chrome = find_chrome()
    if not chrome:
        print("ERROR: Chrome (or Edge) not found. Install Chrome from "
              "https://www.google.com/chrome/", file=sys.stderr)
        return 1

    out_name = f"Workload-Baseline-Report-{dt.date.today():%Y-%m-%d}.pdf"
    pdf_out = os.path.join(OUTPUT_DIR, out_name)

    with tempfile.TemporaryDirectory() as tmp:
        chart_png = os.path.join(tmp, 'chart.png')
        stats, _ = build_chart(points, chart_png)
        html_path = build_html(points, chart_png, stats, tmp)
        render_pdf(html_path, pdf_out, chrome, tmp)

    size_kb = os.path.getsize(pdf_out) // 1024
    print(f"\n=== PDF built ===")
    print(f"Output: {pdf_out}")
    print(f"Size: {size_kb} KB")
    return 0


if __name__ == '__main__':
    sys.exit(main())
