#!/bin/bash
# build-baseline-pdf.sh -- assemble all captures from a baseline campaign
# into a single PDF report with time-series charts + per-capture appendix.
#
# Reads:
#   $SNAPSHOT_DIR/YYYY-MM-DD/HH-MM-report.txt
#   $SNAPSHOT_DIR/YYYY-MM-DD/HH-MM-AM-memory.png
#   $SNAPSHOT_DIR/YYYY-MM-DD/HH-MM-AM-cpu.png
#
# Writes:
#   $OUTPUT_DIR/MacBook-Baseline-Report-YYYY-MM-DD.pdf
#
# Environment variables:
#   SNAPSHOT_DIR   Captures location (default: $HOME/MacBook-Baseline)
#   OUTPUT_DIR     PDF output dir   (default: $HOME/Desktop)
#   MIN_CAPTURE_TS Filter captures before this timestamp (format YYYY-MM-DD_HH-MM, e.g. 2026-05-04_13-34)
#                  Default empty = include every capture.
#
# Requirements: matplotlib (pip3 install matplotlib), Google Chrome installed.

set -eu

SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/MacBook-Baseline}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Desktop}"
TODAY=$(date +%F)
OUT_NAME="MacBook-Baseline-Report-${TODAY}.pdf"
PDF_OUT="$OUTPUT_DIR/$OUT_NAME"

[ -d "$SNAPSHOT_DIR" ] || { echo "ERROR: $SNAPSHOT_DIR not found"; exit 1; }
mkdir -p "$OUTPUT_DIR"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PS_SNAP="$TMPDIR/ps.txt"
ps -axo pid,ppid,rss,command > "$PS_SNAP"

CHART_PNG="$TMPDIR/chart.png"
HTML="$TMPDIR/report.html"

THUMBS_MEM_DIR="$TMPDIR/thumbs-mem"
THUMBS_CPU_DIR="$TMPDIR/thumbs-cpu"
mkdir -p "$THUMBS_MEM_DIR" "$THUMBS_CPU_DIR"

MIN_CAPTURE_TS="${MIN_CAPTURE_TS:-}"
echo "Resizing screenshots to thumbnails (min_ts=${MIN_CAPTURE_TS:-none})..."

include_capture() {
    [ -z "$MIN_CAPTURE_TS" ] && return 0
    local key="$1_$2"
    [ "$key" \< "$MIN_CAPTURE_TS" ] && return 1
    return 0
}

N_MEM=0
N_CPU=0
N_SKIPPED=0
for f in $(find "$SNAPSHOT_DIR" -name "*-AM-memory.png" 2>/dev/null | sort); do
    day=$(basename $(dirname "$f"))
    fname=$(basename "$f")
    time=$(echo "$fname" | sed -E 's/-AM-memory\.png$//')
    if ! include_capture "$day" "$time"; then
        N_SKIPPED=$((N_SKIPPED + 1))
        continue
    fi
    sips -Z 700 -s format jpeg -s formatOptions 70 "$f" --out "$THUMBS_MEM_DIR/${day}_${time}.jpg" >/dev/null 2>&1
    N_MEM=$((N_MEM + 1))
done
for f in $(find "$SNAPSHOT_DIR" -name "*-AM-cpu.png" 2>/dev/null | sort); do
    day=$(basename $(dirname "$f"))
    fname=$(basename "$f")
    time=$(echo "$fname" | sed -E 's/-AM-cpu\.png$//')
    if ! include_capture "$day" "$time"; then
        continue
    fi
    sips -Z 700 -s format jpeg -s formatOptions 70 "$f" --out "$THUMBS_CPU_DIR/${day}_${time}.jpg" >/dev/null 2>&1
    N_CPU=$((N_CPU + 1))
done
echo "  resized $N_MEM mem + $N_CPU cpu thumbnails (skipped $N_SKIPPED pre-cutoff)"

python3 - "$SNAPSHOT_DIR" "$PS_SNAP" "$CHART_PNG" "$TMPDIR/composition.txt" "$TMPDIR/stats.txt" "$MIN_CAPTURE_TS" <<'PYEOF'
import sys, re, os, glob, datetime
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

shots, ps_path, chart_out, comp_out, stats_out, min_ts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
min_ts_dt = None
if min_ts:
    try:
        d, t = min_ts.split('_')
        h, m = t.split('-')
        min_ts_dt = datetime.datetime.strptime(f"{d} {h}:{m}", "%Y-%m-%d %H:%M")
    except Exception:
        min_ts_dt = None

def parse_size_to_mb(s):
    s = s.strip()
    m = re.match(r'(\d+(?:\.\d+)?)\s*([GMK])', s)
    if not m: return None
    val = float(m.group(1))
    unit = m.group(2)
    if unit == 'G': return val * 1024
    if unit == 'M': return val
    if unit == 'K': return val / 1024
    return None

points = []
report_files = sorted(glob.glob(os.path.join(shots, '20*-*-*', '*-report.txt')))
for f in report_files:
    parts = f.split('/')
    day = parts[-2]
    time_str = parts[-1].replace('-report.txt', '')
    try:
        hh, mm = time_str.split('-')
        ts = datetime.datetime.strptime(f"{day} {hh}:{mm}", "%Y-%m-%d %H:%M")
    except Exception:
        continue
    if min_ts_dt and ts < min_ts_dt:
        continue
    try:
        with open(f) as fh:
            text = fh.read()
    except Exception:
        continue
    m = re.search(r'^PhysMem:\s+(\S+)\s+used\s+\([^,]+,\s+(\S+)\s+compressor\),\s+(\S+)\s+unused', text, re.MULTILINE)
    if not m:
        continue
    used = parse_size_to_mb(m.group(1))
    comp = parse_size_to_mb(m.group(2))
    unused = parse_size_to_mb(m.group(3))
    if used is None or comp is None or unused is None:
        continue

    gpu_pct = None
    g = re.search(r'Device Utilization:\s+(\d+)%', text)
    if g: gpu_pct = int(g.group(1))

    load_1 = None
    l = re.search(r'Load Avg:\s+([\d.]+),', text)
    if l: load_1 = float(l.group(1))

    cpu_idle = None
    c = re.search(r'CPU usage:[^,]+,\s+[\d.]+%\s+sys,\s+([\d.]+)%\s+idle', text)
    if c: cpu_idle = float(c.group(1))

    points.append({
        'ts': ts,
        'used_gb': used / 1024,
        'comp_gb': comp / 1024,
        'unused_mb': unused,
        'gpu_pct': gpu_pct,
        'load_1': load_1,
        'cpu_idle': cpu_idle,
    })

points.sort(key=lambda p: p['ts'])
print(f"Parsed {len(points)} captures from {len(report_files)} report files")

if not points:
    print("ERROR: no parseable captures found")
    sys.exit(1)

# Composition snapshot
procs = []
with open(ps_path) as f:
    next(f)
    for line in f:
        m = re.match(r'\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)', line)
        if not m: continue
        rss_kb, cmd = int(m.group(3)), m.group(4)
        procs.append((rss_kb / 1024.0, cmd))

bands = {'Browsers + automation': 0, 'Communication + media': 0, 'macOS + system': 0}
for rss, cmd in procs:
    cl = cmd.lower()
    if 'chrome' in cl or 'chromium' in cl or 'playwright' in cl or 'puppeteer' in cl or 'webkit' in cl or 'safari' in cl or 'firefox' in cl:
        bands['Browsers + automation'] += rss
    elif 'docker' in cl or 'virtualization' in cl or 'node' in cl:
        bands['Browsers + automation'] += rss
    elif 'slack' in cl or 'teams' in cl or 'whatsapp' in cl or 'telegram' in cl or 'messages' in cl or 'spotify' in cl or 'zoom' in cl:
        bands['Communication + media'] += rss
    else:
        bands['macOS + system'] += rss

total_rss = sum(bands.values()) or 1
with open(comp_out, 'w') as f:
    for b, mv in bands.items():
        f.write(f"{b}\t{mv/1024:.1f}\t{mv/total_rss*100:.0f}\n")
    f.write(f"__TOTAL__\t{total_rss/1024:.1f}\t100\n")
    f.write(f"__PROCS__\t{len(procs)}\n")
    f.write(f"__SNAP__\t{datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}\n")

# Stats
import statistics
used_vals = [p['used_gb'] for p in points]
comp_vals = [p['comp_gb'] for p in points]
unused_vals = [p['unused_mb'] for p in points]
gpu_vals = [p['gpu_pct'] for p in points if p.get('gpu_pct') is not None]
load_vals = [p['load_1'] for p in points if p.get('load_1') is not None]
idle_vals = [p['cpu_idle'] for p in points if p.get('cpu_idle') is not None]

stats = {
    'count': len(points),
    'used_min': min(used_vals),
    'used_max': max(used_vals),
    'used_median': statistics.median(used_vals),
    'comp_max': max(comp_vals),
    'comp_median': statistics.median(comp_vals),
    'comp_min': min(comp_vals),
    'pct_unused_below_500': sum(1 for v in unused_vals if v < 500) / len(unused_vals) * 100,
    'pct_comp_above_8': sum(1 for v in comp_vals if v >= 8) / len(comp_vals) * 100,
    'gpu_max': max(gpu_vals) if gpu_vals else 0,
    'gpu_median': statistics.median(gpu_vals) if gpu_vals else 0,
    'pct_gpu_above_50': (sum(1 for v in gpu_vals if v >= 50) / len(gpu_vals) * 100) if gpu_vals else 0,
    'load_max': max(load_vals) if load_vals else 0,
    'load_median': statistics.median(load_vals) if load_vals else 0,
    'idle_median': statistics.median(idle_vals) if idle_vals else 0,
    'pct_idle_below_5': (sum(1 for v in idle_vals if v < 5) / len(idle_vals) * 100) if idle_vals else 0,
}
with open(stats_out, 'w') as f:
    for k, v in stats.items():
        f.write(f"{k}\t{v:.2f}\n")

# Time-series chart
plt.rcParams.update({
    'font.family': ['Helvetica Neue', 'Arial', 'sans-serif'],
    'font.size': 10.5,
    'axes.spines.top': False,
    'axes.spines.right': False,
})

fig, (ax, ax2) = plt.subplots(2, 1, figsize=(10, 7.0), gridspec_kw={'height_ratios': [3, 2], 'hspace': 0.35})

ts = [p['ts'] for p in points]
used = [p['used_gb'] for p in points]
comp = [p['comp_gb'] for p in points]

# Top: memory pressure
ax.fill_between(ts, 0, comp, color='#cc0000', alpha=0.18, zorder=2)
ax.plot(ts, comp, color='#cc0000', linewidth=1.6, marker='.', markersize=3, label='Compressed memory (kernel under pressure)', zorder=4)
ax.plot(ts, used, color='#999', linewidth=0.9, linestyle='--', alpha=0.85, label='Physical memory in use', zorder=3)

# Detect total RAM from data (round used_max up to nearest power-of-2-ish)
total_ram_gb = max(used_vals) + max(0, min(unused_vals) / 1024)
total_ram_gb = round(total_ram_gb / 8) * 8 or 16
ax.axhline(y=total_ram_gb, color='#bbb', linestyle=':', linewidth=0.8, alpha=0.8, zorder=1)
ax.text(ts[-1], total_ram_gb + 0.4, f' {total_ram_gb:.0f} GB total RAM', color='#999', fontsize=8.5, ha='right', va='bottom')
ax.axhline(y=8, color='#cc0000', linestyle=':', linewidth=0.9, alpha=0.7, zorder=1)
ax.text(ts[0], 8.4, '  >8 GB compressor = sustained workload pressure', color='#cc0000', fontsize=8.5, ha='left', va='bottom')

ax.xaxis.set_major_locator(mdates.AutoDateLocator())
ax.xaxis.set_major_formatter(mdates.DateFormatter('%m-%d %H:%M' if len(set(p['ts'].date() for p in points)) <= 1 else '%m-%d'))
plt.setp(ax.get_xticklabels(), rotation=0, ha='center', fontsize=9, color='#333')
ax.set_ylim(0, total_ram_gb + 4)
ax.set_ylabel('Memory (GB)', fontsize=10, color='#333')
ax.set_title('Memory pressure', fontsize=10.5, color='#333', loc='left', pad=6, fontweight='600')
ax.grid(axis='y', alpha=0.18, zorder=0)
ax.legend(loc='upper left', frameon=False, fontsize=9, ncol=1)

# Bottom: GPU + CPU
ts_gpu = [p['ts'] for p in points if p.get('gpu_pct') is not None]
gpu_vals_chart = [p['gpu_pct'] for p in points if p.get('gpu_pct') is not None]
ts_idle = [p['ts'] for p in points if p.get('cpu_idle') is not None]
cpu_busy = [100 - p['cpu_idle'] for p in points if p.get('cpu_idle') is not None]

if gpu_vals_chart:
    ax2.fill_between(ts_gpu, 0, gpu_vals_chart, color='#0066cc', alpha=0.16, zorder=2)
    ax2.plot(ts_gpu, gpu_vals_chart, color='#0066cc', linewidth=1.4, marker='.', markersize=3, label='GPU device utilization (%)', zorder=4)
if cpu_busy:
    ax2.plot(ts_idle, cpu_busy, color='#cc7700', linewidth=0.9, linestyle='--', alpha=0.85, label='CPU busy (100 - idle, %)', zorder=3)

ax2.axhline(y=80, color='#cc0000', linestyle=':', linewidth=0.9, alpha=0.7, zorder=1)
ax2.text(ts[0], 81, '  >80% = sustained chip-class pressure', color='#cc0000', fontsize=8.5, ha='left', va='bottom')

ax2.xaxis.set_major_locator(mdates.AutoDateLocator())
ax2.xaxis.set_major_formatter(mdates.DateFormatter('%m-%d %H:%M' if len(set(p['ts'].date() for p in points)) <= 1 else '%m-%d'))
plt.setp(ax2.get_xticklabels(), rotation=0, ha='center', fontsize=9, color='#333')
ax2.set_ylim(0, 105)
ax2.set_yticks([0, 25, 50, 75, 100])
ax2.set_yticklabels(['0%', '25%', '50%', '75%', '100%'], fontsize=9, color='#333')
ax2.set_ylabel('Compute load', fontsize=10, color='#333')
ax2.set_title('Compute pressure (GPU + CPU)', fontsize=10.5, color='#333', loc='left', pad=6, fontweight='600')
ax2.grid(axis='y', alpha=0.18, zorder=0)
if gpu_vals_chart or cpu_busy:
    ax2.legend(loc='upper left', frameon=False, fontsize=9, ncol=1)

plt.tight_layout()
plt.savefig(chart_out, dpi=200, bbox_inches='tight', facecolor='white')
print(f"Chart written: {chart_out}")
PYEOF

CHART_B64=$(base64 -i "$CHART_PNG")
COMP_DATA="$TMPDIR/composition.txt"
STATS_DATA="$TMPDIR/stats.txt"

ACTUAL_START=$(ls "$THUMBS_MEM_DIR" 2>/dev/null | head -1 | cut -d'_' -f1)
ACTUAL_END=$(ls "$THUMBS_MEM_DIR" 2>/dev/null | tail -1 | cut -d'_' -f1)
if [ -n "$ACTUAL_START" ] && [ -n "$ACTUAL_END" ]; then
    DAYS_COUNT=$(( ( $(date -j -f "%Y-%m-%d" "$ACTUAL_END" +%s) - $(date -j -f "%Y-%m-%d" "$ACTUAL_START" +%s) ) / 86400 + 1 ))
    TITLE_RANGE="${ACTUAL_START} to ${ACTUAL_END} (${DAYS_COUNT} days)"
else
    TITLE_RANGE="workload baseline"
fi

CAPTURE_COUNT=$(awk '$1=="count"{printf "%.0f", $2}' "$STATS_DATA")
COMP_MEDIAN=$(awk '$1=="comp_median"{printf "%.1f", $2}' "$STATS_DATA")
COMP_MAX=$(awk '$1=="comp_max"{printf "%.1f", $2}' "$STATS_DATA")
COMP_MIN=$(awk '$1=="comp_min"{printf "%.1f", $2}' "$STATS_DATA")
PCT_UNUSED_LOW=$(awk '$1=="pct_unused_below_500"{printf "%.0f", $2}' "$STATS_DATA")
PCT_COMP_8=$(awk '$1=="pct_comp_above_8"{printf "%.0f", $2}' "$STATS_DATA")
GPU_MAX=$(awk '$1=="gpu_max"{printf "%.0f", $2}' "$STATS_DATA")
GPU_MEDIAN=$(awk '$1=="gpu_median"{printf "%.0f", $2}' "$STATS_DATA")
PCT_GPU_50=$(awk '$1=="pct_gpu_above_50"{printf "%.0f", $2}' "$STATS_DATA")
PCT_IDLE_LOW=$(awk '$1=="pct_idle_below_5"{printf "%.0f", $2}' "$STATS_DATA")
LOAD_MAX=$(awk '$1=="load_max"{printf "%.0f", $2}' "$STATS_DATA")
LOAD_MEDIAN=$(awk '$1=="load_median"{printf "%.1f", $2}' "$STATS_DATA")

TOTAL_RSS=$(awk -F'\t' '$1=="__TOTAL__"{print $2}' "$COMP_DATA")
PROC_COUNT=$(awk -F'\t' '$1=="__PROCS__"{print $2}' "$COMP_DATA")
SNAP_TIME=$(awk -F'\t' '$1=="__SNAP__"{print $2}' "$COMP_DATA")

COMP_ROWS=""
while IFS=$'\t' read -r cat gb pct; do
    [ "${cat:0:2}" = "__" ] && continue
    COMP_ROWS+="<tr><td>${cat}</td><td>${gb} GB</td><td>${pct}%</td></tr>"
done < "$COMP_DATA"

# Build appendix grid
echo "Building appendix grid..."
GRID_FILE="$TMPDIR/grid.html"
> "$GRID_FILE"

TS_LIST="$TMPDIR/all-timestamps.txt"
{
    ls "$THUMBS_MEM_DIR" 2>/dev/null | sed 's/\.jpg$//'
    ls "$THUMBS_CPU_DIR" 2>/dev/null | sed 's/\.jpg$//'
} | sort -u > "$TS_LIST"

THUMB_COUNT=0
while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    day="${fname%%_*}"
    time="${fname#*_}"
    short_day="${day:5}"
    mem_thumb="$THUMBS_MEM_DIR/${fname}.jpg"
    cpu_thumb="$THUMBS_CPU_DIR/${fname}.jpg"

    have_mem=0; have_cpu=0
    [ -f "$mem_thumb" ] && have_mem=1
    [ -f "$cpu_thumb" ] && have_cpu=1
    n_present=$((have_mem + have_cpu))
    [ "$n_present" = "0" ] && continue

    label="$short_day · $time"
    printf '<div class="pair"><div class="pair-label">%s</div><div class="pair-imgs cols-%d">' "$label" "$n_present" >> "$GRID_FILE"
    if [ "$have_mem" = "1" ]; then
        printf '<div><span class="cap">Memory</span><img src="file://%s"></div>' "$mem_thumb" >> "$GRID_FILE"
    fi
    if [ "$have_cpu" = "1" ]; then
        printf '<div><span class="cap">CPU</span><img src="file://%s"></div>' "$cpu_thumb" >> "$GRID_FILE"
    fi
    printf '</div></div>\n' >> "$GRID_FILE"
    THUMB_COUNT=$((THUMB_COUNT + 1))
done < "$TS_LIST"
GRID_ITEMS=$(cat "$GRID_FILE")
echo "  grid items: $THUMB_COUNT rows"

cat > "$HTML" <<HTMLEOF
<!doctype html>
<html><head><meta charset="utf-8">
<title>MacBook Workload Baseline Report</title>
<style>
  @page { size: A4 portrait; margin: 1.6cm 1.5cm 1.4cm 1.5cm; }
  html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  body { font-family: -apple-system, "Helvetica Neue", Arial, sans-serif; color: #1a1a1a; margin: 0; line-height: 1.5; }
  h1 { font-size: 15pt; font-weight: 600; margin: 0 0 4px 0; }
  .subtitle { font-size: 10pt; color: #666; margin-bottom: 18px; }
  .chart-wrap img { width: 100%; height: auto; display: block; margin-bottom: 14px; }
  h2 { font-size: 10pt; font-weight: 600; margin: 18px 0 7px 0; color: #333; text-transform: uppercase; letter-spacing: 0.5px; }
  .stats-grid { display: flex; gap: 16px; margin: 8px 0 14px 0; }
  .stat { flex: 1; padding: 8px 10px; background: #f6f6f6; border-radius: 3px; }
  .stat .v { font-size: 13pt; font-weight: 600; color: #1a1a1a; }
  .stat .l { font-size: 8.5pt; color: #666; margin-top: 2px; line-height: 1.3; }
  table { border-collapse: collapse; width: 100%; font-size: 9.5pt; margin-bottom: 14px; }
  th, td { text-align: left; padding: 5px 9px; border-bottom: 1px solid #ddd; }
  th { color: #666; font-weight: 500; font-size: 8.5pt; text-transform: uppercase; letter-spacing: 0.4px; border-bottom: 1.5px solid #333; }
  td:nth-child(2), td:nth-child(3) { text-align: right; font-variant-numeric: tabular-nums; color: #333; width: 75px; }
  .footer { margin-top: 14px; font-size: 8pt; color: #888; line-height: 1.5; }
  .footer p { margin: 2px 0; }
  .pairs { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px 14px; margin-top: 8px; }
  .pair { break-inside: avoid; margin-bottom: 4px; }
  .pair-label { font-size: 8pt; color: #333; margin-bottom: 3px; font-variant-numeric: tabular-nums; font-weight: 500; }
  .pair-imgs { display: grid; gap: 6px; }
  .pair-imgs.cols-1 { grid-template-columns: 1fr; }
  .pair-imgs.cols-2 { grid-template-columns: 1fr 1fr; }
  .pair-imgs > div { display: flex; flex-direction: column; }
  .pair-imgs span.cap { font-size: 7pt; color: #888; text-transform: uppercase; letter-spacing: 0.4px; margin-bottom: 2px; }
  .pair-imgs img { width: 100%; height: auto; display: block; border: 1px solid #ccc; }
</style>
</head><body>

<h1>MacBook Workload Baseline -- ${TITLE_RANGE}</h1>
<div class="subtitle">${CAPTURE_COUNT} captures · Activity Monitor screenshots + ps + vm_stat</div>

<div class="chart-wrap">
  <img src="data:image/png;base64,${CHART_B64}">
</div>

<div class="stats-grid">
  <div class="stat"><div class="v">${COMP_MEDIAN} GB</div><div class="l">median compressor activity (range ${COMP_MIN}–${COMP_MAX} GB)</div></div>
  <div class="stat"><div class="v">${PCT_COMP_8}%</div><div class="l">of captures &gt; 8 GB compressor (workload pressure)</div></div>
  <div class="stat"><div class="v">${PCT_UNUSED_LOW}%</div><div class="l">of captures with &lt; 500 MB free RAM</div></div>
</div>
<div class="stats-grid">
  <div class="stat"><div class="v">${GPU_MEDIAN}%</div><div class="l">median GPU device utilisation (peak ${GPU_MAX}%)</div></div>
  <div class="stat"><div class="v">${PCT_GPU_50}%</div><div class="l">of captures with GPU &gt; 50%</div></div>
  <div class="stat"><div class="v">${PCT_IDLE_LOW}%</div><div class="l">of captures with CPU idle &lt; 5% (load median ${LOAD_MEDIAN}, peak ${LOAD_MAX})</div></div>
</div>

<h2>What was running (live snapshot ${SNAP_TIME})</h2>
<table>
  <thead><tr><th>Category</th><th>RSS</th><th>Share</th></tr></thead>
  <tbody>${COMP_ROWS}</tbody>
</table>

<div class="footer">
  <p>Composition snapshot: ${PROC_COUNT} processes, total RSS ${TOTAL_RSS} GB. Process-level RSS double-counts shared memory; PhysMem (vm_stat) is ground truth.</p>
  <p>Raw evidence: full per-capture Activity Monitor screenshots in the appendix that follows.</p>
</div>

<div style="page-break-before: always;"></div>
<h1 style="margin-top: 0;">Appendix -- ${THUMB_COUNT} Activity Monitor captures</h1>
<div class="subtitle">Chronological. Each row shows the Memory and CPU tabs at that capture time.</div>

<div class="pairs">
${GRID_ITEMS}
</div>

</body></html>
HTMLEOF

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
    echo "ERROR: Google Chrome not found at $CHROME"
    echo "Install Chrome from https://www.google.com/chrome/ or edit this script to point at your browser."
    exit 1
fi

"$CHROME" \
    --headless=new \
    --disable-gpu \
    --no-pdf-header-footer \
    --print-to-pdf="$PDF_OUT" \
    --no-sandbox \
    --allow-file-access-from-files \
    --user-data-dir="$TMPDIR/chrome-profile" \
    --virtual-time-budget=60000 \
    "file://$HTML" 2>/dev/null

SIZE=$(ls -l "$PDF_OUT" | awk '{print $5}')
echo ""
echo "=== PDF built ==="
echo "Output: $PDF_OUT"
echo "Size: $((SIZE / 1024)) KB"
