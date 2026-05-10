# MacBook Workload Baseline Toolkit

Capture a 1-2 week resource-usage baseline on any Mac (CPU + GPU + memory + Activity Monitor screenshots), then assemble it into a single PDF report. Designed for IT teams answering "is this person's hardware sized correctly?"

## Quick start

```bash
# 1. Install
./install.sh                    # puts `baseline` into /usr/local/bin

# 2. Start the campaign on the user's Mac
baseline start

# 3. Wait 1-2 weeks. Sanity-check any time:
baseline status

# 4. Build the PDF
baseline build                  # opens the PDF on your Desktop
```

That's it. Three commands.

## What it captures

Every 30 minutes while the Mac is awake (configurable):

- `top -l 1` -- CPU%, load average, PhysMem
- `vm_stat` -- pages free / active / inactive / wired / **compressed** (the kernel's "running out of RAM" signal)
- `ps -axo` -- top RAM and top CPU consumers
- `ioreg IOAccelerator` -- GPU device utilisation % (no sudo needed, Apple Silicon)
- `iostat`, `netstat -ib`
- `powermetrics` -- CPU/GPU watts (only if passwordless sudo is configured; harmlessly skipped otherwise)
- **Activity Monitor screenshots** -- Memory tab + CPU tab, captured by Quartz window ID. The script will **never** fall back to a full-screen capture, so no desktop content can leak.

## What the PDF contains

1. **Time-series chart** -- compressor activity + PhysMem-in-use (top), GPU% + CPU-busy (bottom). Threshold lines make sustained pressure obvious at a glance.
2. **Headline stat tiles** -- median compressor, % of captures > 8 GB compressor, % with < 500 MB free RAM, GPU median/peak, CPU idle distribution.
3. **Composition snapshot** -- live `ps` output bucketed into Browsers+automation / Communication+media / macOS+system.
4. **Appendix** -- every Memory + CPU Activity Monitor screenshot in chronological order, two captures per row.

A typical 14-day campaign produces ~250-350 captures, ~150-300 MB on disk, and a 5-15 MB PDF.

## Commands

```
baseline start              Install deps + start scheduled captures (every 30 min while awake)
baseline status             Show running state, capture count, last log line
baseline build              Build PDF from captures, save to ~/Desktop/, open it
baseline build --min-ts T   Skip captures earlier than T (format YYYY-MM-DD_HH-MM)
baseline stop               Stop further captures (data preserved)
baseline uninstall          Stop + remove launchd plist (data preserved)
baseline help
```

## Dependencies

`baseline start` installs these automatically (via `pip3 install --user`):

- Python 3 (must already be present -- `xcode-select --install` if missing)
- `matplotlib`
- `pyobjc-framework-Quartz`

Plus:

- Google Chrome (used headlessly to render the HTML report into PDF). If Chrome lives somewhere other than `/Applications/Google Chrome.app/`, edit the path inside `scripts/build-baseline-pdf.sh`.

## macOS permissions

The Activity Monitor screenshots use `screencapture -l<window-id>`. macOS will prompt the **first time** the script tries to capture for Screen Recording permission -- approve it. Without that permission, the rest of the capture still runs; only the AM screenshots are skipped (logged as `AM-skip`).

You may need to grant the permission to `bash` (or whichever process launchd uses to run the script).

## Manual install (without `install.sh`)

```bash
chmod +x bin/baseline scripts/*.sh
ln -sf "$(pwd)/bin/baseline" /usr/local/bin/baseline
baseline start
```

## File layout

```
macbook-baseline-bundle/
├── bin/
│   └── baseline                              # CLI entry point
├── scripts/
│   ├── memory-snapshot.sh                    # one capture
│   └── build-baseline-pdf.sh                 # assemble PDF
├── launchd/
│   └── com.macbook-baseline.snapshot.plist   # scheduled-capture template
├── install.sh                                # symlinks `baseline` into PATH
├── INSTALL.md                                # manual install (advanced)
└── README.md
```

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `SNAPSHOT_DIR` | `$HOME/MacBook-Baseline` | Where captures are written / read |
| `OUTPUT_DIR` | `$HOME/Desktop` | Where the PDF lands |
| `MIN_CAPTURE_TS` | empty | Filter captures earlier than `YYYY-MM-DD_HH-MM` |

## Troubleshooting

- **`baseline: command not found`** -- `/usr/local/bin` may not be in your PATH. Run with the full path: `~/macbook-baseline-bundle/bin/baseline status`.
- **`AM-skip: no window id` in the log** -- Activity Monitor was minimised when the capture ran. Re-open it; subsequent captures will pick it up.
- **Empty PDF / "no captures"** -- run `baseline status` to verify captures landed. If `Job: not loaded`, run `baseline start`.
- **Chart says `Parsed 0 captures`** -- `MIN_CAPTURE_TS` may be set too far in the future, or the layout is non-standard. Captures must live at `$SNAPSHOT_DIR/YYYY-MM-DD/HH-MM-report.txt`.

## License

MIT-equivalent. Use freely.
