#!/usr/bin/env python3
"""render_chart.py -- generate a per-capture summary chart from data.json.

Usage:
    python3 render_chart.py <data.json> <output.png>

Mirrors the per-capture chart from the macOS toolkit so the appendix in the
final PDF has matching visual evidence across platforms.
"""
import json
import os
import sys

os.environ.setdefault('MPLBACKEND', 'Agg')
import matplotlib.pyplot as plt


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("Usage: render_chart.py <data.json> <output.png>\n")
        return 2

    with open(sys.argv[1], 'r', encoding='utf-8') as fh:
        d = json.load(fh)

    cpu_busy = (d.get('cpu') or {}).get('busy_pct') or 0
    gpu_util = (d.get('gpu') or {}).get('device_util_pct') or 0
    mem = d.get('memory_mb') or {}
    total_mem = mem.get('total') or 0
    used_mem = mem.get('used') or 0
    unused_mem = mem.get('unused') or 0
    mem_used_pct = (100.0 * used_mem / total_mem) if total_mem else 0

    fig = plt.figure(figsize=(12, 6), dpi=120)
    fig.suptitle(
        f"Windows Snapshot -- {d.get('ts','')[:19]} ({d.get('reason','')})",
        fontsize=13, fontweight='bold', y=0.98,
    )

    # Headline gauges
    ax1 = plt.subplot2grid((2, 2), (0, 0))
    labels = ['CPU', 'GPU', 'Memory']
    vals = [cpu_busy, gpu_util, mem_used_pct]
    colors = ['#cc3300' if v > 80 else '#ff9933' if v > 50 else '#339966' for v in vals]
    bars = ax1.barh(labels, vals, color=colors, edgecolor='#222')
    ax1.set_xlim(0, 100)
    ax1.set_xlabel('% utilized')
    ax1.set_title('Headline', fontsize=11)
    for b, v in zip(bars, vals):
        ax1.text(min(v + 2, 95), b.get_y() + b.get_height() / 2,
                 f'{v:.0f}%', va='center', fontsize=10, fontweight='bold')

    # Memory pie
    ax2 = plt.subplot2grid((2, 2), (0, 1))
    if total_mem:
        sizes = [used_mem, unused_mem]
        slabels = [f"In use\n{used_mem/1024:.1f} GB", f"Free\n{unused_mem/1024:.1f} GB"]
        ax2.pie(sizes, labels=slabels, colors=['#cc3300', '#e5e7eb'],
                startangle=90, textprops={'fontsize': 9})
    ax2.set_title(f'Memory ({total_mem/1024:.0f} GB total)', fontsize=11)

    # Process counts
    ax3 = plt.subplot2grid((2, 2), (1, 0), colspan=1)
    pc = d.get('process_counts') or {}
    if pc:
        keys = list(pc.keys())
        vals_p = [pc[k] for k in keys]
        ax3.bar(keys, vals_p, color='#222', edgecolor='#cc3300')
        ax3.set_title('Process counts', fontsize=11)
        ax3.tick_params(axis='x', rotation=30)
        for i, v in enumerate(vals_p):
            ax3.text(i, v + max(vals_p + [1]) * 0.02, str(v), ha='center', fontsize=9)

    # Stats text panel
    ax4 = plt.subplot2grid((2, 2), (1, 1))
    ax4.axis('off')
    host = d.get('host') or {}
    stats_text = (
        f"Computer:  {host.get('computer','?')}\n"
        f"User:      {host.get('user','?')}\n"
        f"OS:        {host.get('os','?')[:48]}\n\n"
        f"CPU busy:  {cpu_busy:.1f}%\n"
        f"GPU 3D:    {gpu_util}%\n"
        f"Mem used:  {used_mem} MB / {total_mem} MB\n"
        f"Mem avail: {unused_mem} MB\n"
        f"Committed: {mem.get('committed_pct', 0):.1f}%\n"
        f"Pages/sec: {mem.get('pages_per_sec', 0):.1f}\n"
    )
    ax4.text(0.05, 0.95, stats_text, family='monospace', fontsize=10,
             verticalalignment='top', transform=ax4.transAxes)

    plt.tight_layout(rect=[0, 0, 1, 0.95])
    plt.savefig(sys.argv[2], dpi=120, bbox_inches='tight', facecolor='white')
    plt.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
