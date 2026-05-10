#!/bin/bash
# memory-snapshot.sh -- capture CPU/GPU/memory/disk/network usage for a
# MacBook workload baseline. Pulls metrics directly via CLI tools, then
# captures the Activity Monitor Memory + CPU tab screenshots for proof.
#
# Output (per capture):
#   $SNAPSHOT_DIR/YYYY-MM-DD/HH-MM-report.txt
#   $SNAPSHOT_DIR/YYYY-MM-DD/HH-MM-data.json
#   $SNAPSHOT_DIR/YYYY-MM-DD/HH-MM-chart.png
#   $SNAPSHOT_DIR/YYYY-MM-DD/HH-MM-AM-memory.png
#   $SNAPSHOT_DIR/YYYY-MM-DD/HH-MM-AM-cpu.png
#
# Sources:
#   top -l 1                -- CPU%, load, PhysMem
#   vm_stat                 -- pages free/active/inactive/wired/compressed
#   ps -axo                 -- top RAM + top CPU consumers
#   ioreg IOAccelerator     -- GPU Device Utilization % (no sudo)
#   iostat                  -- disk I/O
#   netstat -ib             -- per-interface bytes
#   powermetrics            -- CPU/GPU watts (only if passwordless sudo)
#   screencapture -l<winid> -- Activity Monitor window screenshots (Quartz)
#
# Environment variables:
#   SNAPSHOT_DIR  Output base dir (default: $HOME/MacBook-Baseline)
#   LOG_FILE      Log file path  (default: $SNAPSHOT_DIR/snapshot.log)
#   REASON        Tag for this capture (default: scheduled)
#   DAILY_CAP     Max captures per day (default: 50)
#
# Usage:
#   ./memory-snapshot.sh                        # one-shot, default location
#   SNAPSHOT_DIR=/tmp/test ./memory-snapshot.sh # override location
#   DAILY_CAP=200 ./memory-snapshot.sh          # raise cap (for launchd)

set -u

SNAPSHOT_DIR="${SNAPSHOT_DIR:-$HOME/MacBook-Baseline}"
LOG="${LOG_FILE:-$SNAPSHOT_DIR/snapshot.log}"
mkdir -p "$SNAPSHOT_DIR" "$(dirname "$LOG")"

REASON="${REASON:-scheduled}"
DAILY_CAP="${DAILY_CAP:-50}"

TODAY=$(date '+%Y-%m-%d')
NOW=$(date '+%H-%M')
OUT_DIR="$SNAPSHOT_DIR/$TODAY"
mkdir -p "$OUT_DIR"

log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" >> "$LOG"
}

# -------- 1. Cap check (count text reports, not PNGs) --------
COUNT=$(ls -1 "$OUT_DIR"/*-report.txt 2>/dev/null | wc -l | tr -d ' ')
if [ "$COUNT" -ge "$DAILY_CAP" ]; then
    log "skip: already $COUNT captures today (cap=$DAILY_CAP, reason=$REASON)"
    exit 0
fi

# -------- 2. Respect Focus/DnD --------
DND=$(defaults -currentHost read ~/Library/Preferences/ByHost/com.apple.notificationcenterui 2>/dev/null | grep -c doNotDisturb)
if [ "$DND" -gt 0 ]; then
    log "skip: DnD/Focus active (reason=$REASON)"
    exit 0
fi

# -------- 3. GPU utilization via ioreg (no sudo) --------
# IOAccelerator's PerformanceStatistics dict has Device Utilization % +
# Renderer/Tiler %. Available on Apple Silicon without elevated privileges.
GPU_RAW=$(ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null | grep PerformanceStatistics | head -1)
GPU_UTIL=$(echo "$GPU_RAW" | sed -n 's/.*"Device Utilization %"=\([0-9]*\).*/\1/p')
GPU_RENDERER=$(echo "$GPU_RAW" | sed -n 's/.*"Renderer Utilization %"=\([0-9]*\).*/\1/p')
GPU_TILER=$(echo "$GPU_RAW" | sed -n 's/.*"Tiler Utilization %"=\([0-9]*\).*/\1/p')
GPU_INUSE_BYTES=$(echo "$GPU_RAW" | sed -n 's/.*"In use system memory"=\([0-9]*\).*/\1/p')

# -------- 4. Build text report --------
TEXT_FILE="$OUT_DIR/${NOW}-report.txt"
{
    echo "=== MacBook Snapshot $(date '+%Y-%m-%d %H:%M:%S') reason=$REASON ==="
    echo ""
    echo "--- Load ---"
    uptime
    echo ""
    echo "--- CPU + PhysMem (top -l 1) ---"
    top -l 1 -n 0 -s 0 | grep -E "PhysMem|Load Avg|CPU usage|VM:|Swap"
    echo ""
    echo "--- GPU (ioreg, no sudo) ---"
    if [ -n "$GPU_UTIL" ]; then
        echo "Device Utilization:    ${GPU_UTIL}%"
        echo "Renderer Utilization:  ${GPU_RENDERER}%"
        echo "Tiler Utilization:     ${GPU_TILER}%"
        if [ -n "$GPU_INUSE_BYTES" ]; then
            GPU_INUSE_MB=$((GPU_INUSE_BYTES / 1024 / 1024))
            echo "GPU In-Use Memory:     ${GPU_INUSE_MB} MB"
        fi
    else
        echo "(ioreg returned no IOAccelerator stats)"
    fi
    echo ""
    echo "--- vm_stat ---"
    vm_stat
    echo ""
    echo "--- Disk I/O (iostat 1 sample) ---"
    iostat -d -c 2 -w 1 2>/dev/null | tail -5
    echo ""
    echo "--- Network bytes per interface (netstat -ib) ---"
    netstat -ib 2>/dev/null | awk 'NR==1 || $1=="en0" || $1=="en1" || $1=="lo0" || $1=="utun0" {print}' | head -10
    echo ""
    echo "--- Top 20 RAM consumers ---"
    ps -axo pid,rss,pcpu,comm | sort -k2 -n -r | head -21 | awk 'NR==1 {print; next} {rss_mb=$2/1024; printf "%-7s %6.0fMB  %5s%%  %s\n", $1, rss_mb, $3, $4}'
    echo ""
    echo "--- Top 20 CPU consumers ---"
    ps -axo pid,pcpu,rss,comm | sort -k2 -n -r | head -21 | awk 'NR==1 {print; next} {rss_mb=$3/1024; printf "%-7s %5s%%  %6.0fMB  %s\n", $1, $2, rss_mb, $4}'
    echo ""
    echo "--- powermetrics (CPU + GPU watts, 1s sample) ---"
    if sudo -n true 2>/dev/null; then
        sudo -n powermetrics --samplers cpu_power,gpu_power -i 1000 -n 1 2>/dev/null \
            | grep -E "^(GPU|CPU|Package|E-Cluster|P-Cluster|GPU HW|GPU SW|GPU active)" \
            | head -40
    else
        echo "(skipped: passwordless sudo for powermetrics not configured)"
    fi
} > "$TEXT_FILE"

# -------- 5. Build JSON via python (robust parsing of locale + G/M units) --------
JSON_FILE="$OUT_DIR/${NOW}-data.json"

TOP_OUT=$(top -l 1 -n 0 -s 0)
UPTIME_OUT=$(uptime)
CLAUDE_N=$(pgrep -x claude | wc -l | tr -d ' ')
NODE_N=$(pgrep -x node | wc -l | tr -d ' ')
CHROME_N=$(pgrep -f 'Google Chrome' | wc -l | tr -d ' ')

python3 - "$JSON_FILE" <<PYEOF
import json, os, re, sys, datetime

top_out = """$TOP_OUT"""
uptime_out = """$UPTIME_OUT"""

def f(s):
    """Parse a number that may use comma or dot decimal separator."""
    if s is None: return None
    s = s.replace(',', '.')
    try: return float(s)
    except: return None

def to_mb(num_str, unit):
    """Convert e.g. ('31','G') -> 31744; ('512','M') -> 512."""
    n = f(num_str)
    if n is None: return None
    if unit == 'G': return int(n * 1024)
    if unit == 'M': return int(n)
    if unit == 'K': return int(n / 1024)
    return int(n)

# Load average
m = re.search(r'load averages?: ([\d,\.]+)', uptime_out)
load_1 = f(m.group(1)) if m else None

# CPU usage line
m = re.search(r'CPU usage: ([\d,\.]+)% user, ([\d,\.]+)% sys, ([\d,\.]+)% idle', top_out)
cpu_user = f(m.group(1)) if m else None
cpu_sys  = f(m.group(2)) if m else None
cpu_idle = f(m.group(3)) if m else None

# PhysMem: "31G used (9051M wired, 13G compressor), 144M unused."
mem_used = mem_wired = mem_comp = mem_unused = None
m = re.search(r'PhysMem: ([\d\.]+)([GMK]) used \(([\d\.]+)([GMK]) wired, ([\d\.]+)([GMK]) compressor\), ([\d\.]+)([GMK]) unused', top_out)
if m:
    mem_used   = to_mb(m.group(1), m.group(2))
    mem_wired  = to_mb(m.group(3), m.group(4))
    mem_comp   = to_mb(m.group(5), m.group(6))
    mem_unused = to_mb(m.group(7), m.group(8))

swap_used = None
m = re.search(r'^Swap: ([\d\.]+)([GMK])', top_out, re.MULTILINE)
if m:
    swap_used = to_mb(m.group(1), m.group(2))

gpu_util      = ${GPU_UTIL:-0} or None
gpu_renderer  = ${GPU_RENDERER:-0} or None
gpu_tiler     = ${GPU_TILER:-0} or None
gpu_inuse_mb  = int(${GPU_INUSE_BYTES:-0}) // (1024 * 1024)

data = {
    "ts": datetime.datetime.now().astimezone().isoformat(),
    "reason": "$REASON",
    "load_1": load_1,
    "cpu": {"user_pct": cpu_user, "sys_pct": cpu_sys, "idle_pct": cpu_idle},
    "gpu": {
        "device_util_pct": gpu_util,
        "renderer_util_pct": gpu_renderer,
        "tiler_util_pct": gpu_tiler,
        "in_use_mb": gpu_inuse_mb,
    },
    "memory_mb": {
        "used": mem_used, "wired": mem_wired, "compressed": mem_comp,
        "unused": mem_unused, "swap_used": swap_used,
    },
    "process_counts": {
        "claude": $CLAUDE_N, "node": $NODE_N, "chrome": $CHROME_N,
    },
}

with open(sys.argv[1], 'w') as fh:
    json.dump(data, fh, indent=2)
PYEOF

# -------- 6. Render chart PNG (proof image, no desktop content) --------
CHART_FILE="$OUT_DIR/${NOW}-chart.png"
TOP_CPU_RAW=$(ps -axo pcpu,rss,comm | sort -k1 -n -r | head -8)
TOP_RAM_RAW=$(ps -axo rss,pcpu,comm | sort -k1 -n -r | head -8)
ALL_PROCS_RAW=$(ps -axo pcpu,rss,comm | tail -n +2)

python3 - "$JSON_FILE" "$CHART_FILE" <<PYEOF
import json, sys, os
os.environ['MPLBACKEND'] = 'Agg'
import matplotlib.pyplot as plt

with open(sys.argv[1]) as fh:
    d = json.load(fh)

top_cpu_raw = """$TOP_CPU_RAW""".strip().split('\n')
top_ram_raw = """$TOP_RAM_RAW""".strip().split('\n')

def parse_top(lines, val_idx, comm_idx):
    out = []
    for ln in lines:
        parts = ln.split(None, 2)
        if len(parts) < 3: continue
        try:
            val = float(parts[val_idx].replace(',', '.'))
        except:
            continue
        comm = parts[comm_idx].split('/')[-1][:24]
        out.append((val, comm))
    return out

cpu_top = parse_top(top_cpu_raw, 0, 2)
ram_top = parse_top(top_ram_raw, 0, 2)

fig = plt.figure(figsize=(14, 8), dpi=120)
fig.suptitle(f"MacBook Snapshot -- {d['ts'][:19]} ({d['reason']})",
             fontsize=14, fontweight='bold', y=0.99)

ax1 = plt.subplot2grid((2, 3), (0, 0))
cpu_busy = 100 - (d['cpu']['idle_pct'] or 0)
gpu_util = d['gpu']['device_util_pct'] or 0
mem_total = (d['memory_mb']['used'] or 0) + (d['memory_mb']['unused'] or 0)
mem_used_pct = 100 * (d['memory_mb']['used'] or 0) / mem_total if mem_total else 0
labels = ['CPU', 'GPU', 'Memory']
vals = [cpu_busy, gpu_util, mem_used_pct]
colors = ['#cc3300' if v > 80 else '#ff9933' if v > 50 else '#339966' for v in vals]
bars = ax1.barh(labels, vals, color=colors, edgecolor='#222')
ax1.set_xlim(0, 100)
ax1.set_xlabel('% utilized')
ax1.set_title('Headline', fontsize=11)
for b, v in zip(bars, vals):
    ax1.text(min(v + 2, 95), b.get_y() + b.get_height()/2, f'{v:.0f}%',
             va='center', fontsize=10, fontweight='bold')

ax2 = plt.subplot2grid((2, 3), (0, 1))
mem = d['memory_mb']
mem_parts = [
    ('Wired', mem['wired'] or 0, '#cc3300'),
    ('Compressed', mem['compressed'] or 0, '#ff9933'),
    ('Other', max(0, (mem['used'] or 0) - (mem['wired'] or 0) - (mem['compressed'] or 0)), '#a8d5ba'),
    ('Free', mem['unused'] or 0, '#e5e7eb'),
]
sizes = [p[1] for p in mem_parts]
mlabels = [f"{p[0]}\n{p[1]/1024:.1f} GB" for p in mem_parts]
mcolors = [p[2] for p in mem_parts]
if sum(sizes) > 0:
    ax2.pie(sizes, labels=mlabels, colors=mcolors, startangle=90,
            textprops={'fontsize': 9})
ax2.set_title(f'Memory ({mem_total/1024:.0f} GB total)', fontsize=11)

ax3 = plt.subplot2grid((2, 3), (0, 2))
pc = d['process_counts']
ax3.bar(list(pc.keys()), list(pc.values()), color='#222', edgecolor='#cc3300')
ax3.set_title('Process counts', fontsize=11)
ax3.tick_params(axis='x', rotation=30)

ax4 = plt.subplot2grid((2, 3), (1, 0), colspan=1)
if cpu_top:
    names = [c[1] for c in cpu_top][::-1]
    vals = [c[0] for c in cpu_top][::-1]
    ax4.barh(names, vals, color='#cc3300')
    ax4.set_xlabel('% CPU')
    ax4.set_title('Top CPU consumers', fontsize=11)

ax5 = plt.subplot2grid((2, 3), (1, 1), colspan=1)
if ram_top:
    names = [c[1] for c in ram_top][::-1]
    vals_mb = [c[0] / 1024 for c in ram_top][::-1]
    ax5.barh(names, vals_mb, color='#222')
    ax5.set_xlabel('RAM (MB)')
    ax5.set_title('Top RAM consumers', fontsize=11)

ax6 = plt.subplot2grid((2, 3), (1, 2))
ax6.axis('off')
swap_str = f"{d['memory_mb']['swap_used']:.0f} MB" if d['memory_mb']['swap_used'] else 'none'
stats_text = (
    f"Load avg:  {d['load_1']}\n"
    f"CPU user:  {d['cpu']['user_pct']:.1f}%\n"
    f"CPU sys:   {d['cpu']['sys_pct']:.1f}%\n"
    f"CPU idle:  {d['cpu']['idle_pct']:.1f}%\n\n"
    f"GPU dev:   {gpu_util}%\n"
    f"GPU mem:   {d['gpu']['in_use_mb']} MB\n\n"
    f"Swap used: {swap_str}\n"
)
ax6.text(0.05, 0.95, stats_text, family='monospace', fontsize=10,
         verticalalignment='top', transform=ax6.transAxes)

plt.tight_layout(rect=[0, 0, 1, 0.95])
plt.savefig(sys.argv[2], dpi=120, bbox_inches='tight', facecolor='white')
plt.close()
PYEOF

# -------- 7. Activity Monitor screenshots --------
# Captures: AM-cpu.png, AM-memory.png. If window capture fails -> skip.
# NEVER falls back to fullscreen (would leak desktop content).
am_capture() {
    local tab_name="$1"
    local out_file="$2"
    local win_id

    osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "System Events"
    tell process "Activity Monitor"
        try
            click menu item "$tab_name" of menu "View" of menu bar 1
        end try
    end tell
end tell
APPLESCRIPT
    sleep 1

    win_id=$(/usr/bin/python3 - 2>/dev/null <<'PYEOF'
from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionAll, kCGNullWindowID
wins = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID)
candidates = []
for w in wins:
    if w.get('kCGWindowOwnerName') != 'Activity Monitor': continue
    if w.get('kCGWindowLayer') != 0: continue
    b = w.get('kCGWindowBounds') or {}
    h, wd = b.get('Height', 0), b.get('Width', 0)
    if h < 300 or wd < 600: continue
    name = w.get('kCGWindowName') or ''
    if name not in ('Activity Monitor', 'Memory', 'CPU', 'Energy', 'Disk', 'Network', 'GPU'):
        continue
    candidates.append((w.get('kCGWindowNumber'), h * wd))
if candidates:
    candidates.sort(key=lambda c: -c[1])
    print(candidates[0][0])
PYEOF
)
    if [ -z "$win_id" ]; then
        log "AM-skip: no window id for $tab_name"
        return 1
    fi

    if ! screencapture -l"$win_id" -o -x "$out_file" 2>/dev/null; then
        log "AM-skip: screencapture failed for $tab_name (win=$win_id)"
        return 1
    fi
    if [ ! -s "$out_file" ]; then
        log "AM-skip: $out_file empty/missing for $tab_name"
        rm -f "$out_file"
        return 1
    fi
    return 0
}

AM_MEM_FILE="$OUT_DIR/${NOW}-AM-memory.png"
AM_CPU_FILE="$OUT_DIR/${NOW}-AM-cpu.png"
AM_OK=0

FRONTMOST=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)

WAS_RUNNING=1
if ! pgrep -x "Activity Monitor" > /dev/null; then
    WAS_RUNNING=0
fi

open -a "Activity Monitor" 2>/dev/null
sleep 2

am_capture "Memory" "$AM_MEM_FILE" && AM_OK=$((AM_OK + 1))
am_capture "CPU"    "$AM_CPU_FILE" && AM_OK=$((AM_OK + 1))

if [ -n "$FRONTMOST" ] && [ "$FRONTMOST" != "Activity Monitor" ]; then
    osascript -e "tell application \"$FRONTMOST\" to activate" >/dev/null 2>&1 &
fi

if [ "$WAS_RUNNING" = "0" ]; then
    osascript -e 'tell application "Activity Monitor" to quit' >/dev/null 2>&1 &
fi

NEW_COUNT=$((COUNT + 1))
log "captured: ${NOW} reason=${REASON} count=${NEW_COUNT}/${DAILY_CAP} gpu=${GPU_UTIL:-?}% AM=${AM_OK}/2"
