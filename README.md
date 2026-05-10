# Workload Baseline Toolkit

Capture a 1-2 week resource-usage baseline on a Mac or Windows machine (CPU + GPU + memory + screenshots/charts), then assemble it into a single PDF report. Designed for IT teams answering "is this person's hardware sized correctly?"

> **Windows users:** see [`windows/README.md`](windows/README.md) -- separate one-line PowerShell installer + the same `baseline start/status/build` lifecycle. The rest of this README covers the macOS toolkit.

## Install (macOS)

Pick **one** of the two methods. Both end with a `baseline` command in your PATH.

### Method 1 -- One-line install (recommended)

Open Terminal on the Mac you want to measure and paste this:

```bash
curl -fsSL https://raw.githubusercontent.com/Quattio/macbook-baseline/main/install.sh | bash
```

That's it. The script downloads the toolkit to `~/.local/share/macbook-baseline` and symlinks the `baseline` command into `/usr/local/bin` (will ask for your password to do so).

### Method 2 -- Manual (if you can't pipe curl into bash)

```bash
git clone https://github.com/Quattio/macbook-baseline.git
cd macbook-baseline
./install.sh
```

Or download the ZIP from [the GitHub page](https://github.com/Quattio/macbook-baseline) (green "Code" button -> "Download ZIP"), unzip it, then `cd` into the folder and run `./install.sh`.

### Verify the install worked

```bash
baseline help
```

If you see the help screen, you're done. If `command not found`, see [Troubleshooting](#troubleshooting) below.

## Use

Three commands cover the whole lifecycle:

```bash
baseline start     # day 0  -- begin scheduled captures (every 30 min while awake)
baseline status    # any day -- check it's running, see capture count
baseline build     # day 14 -- assemble the PDF (lands on Desktop, auto-opens)
```

Then to clean up:

```bash
baseline stop        # stop further captures (data preserved)
baseline uninstall   # remove the launchd job (data preserved)
rm -rf ~/MacBook-Baseline   # only if you want to delete the captured data
```

## What gets captured

Every 30 minutes while the Mac is awake (configurable):

- `top -l 1` -- CPU%, load average, PhysMem
- `vm_stat` -- pages free/active/inactive/wired/**compressed** (the kernel's "running out of RAM" signal)
- `ps -axo` -- top RAM and top CPU consumers
- `ioreg IOAccelerator` -- GPU device utilisation % (no sudo needed, Apple Silicon)
- `iostat`, `netstat -ib`
- `powermetrics` -- CPU/GPU watts (only if passwordless sudo is configured; harmlessly skipped otherwise)
- **Activity Monitor screenshots** -- Memory tab + CPU tab, captured by Quartz window ID. Will **never** fall back to a full-screen capture, so no desktop content can leak.

## What the PDF contains

1. **Time-series chart** -- compressor activity + PhysMem-in-use (top), GPU% + CPU-busy (bottom). Threshold lines make sustained pressure obvious at a glance.
2. **Headline stat tiles** -- median compressor, % of captures > 8 GB compressor, % with < 500 MB free RAM, GPU median/peak, CPU idle distribution.
3. **Composition snapshot** -- live `ps` output bucketed into Browsers+automation / Communication+media / macOS+system.
4. **Appendix** -- every Memory + CPU Activity Monitor screenshot in chronological order, two captures per row.

A typical 14-day campaign produces ~250-350 captures, ~150-300 MB on disk, and a 5-15 MB PDF.

## First-capture permission prompt

The very first time `baseline start` triggers a capture, macOS will pop a Screen Recording permission dialog. **Click Allow.** Without it, the Activity Monitor screenshots are silently skipped (the rest of the data still captures, but the visual proof in the PDF is missing).

You may need to grant the permission to `bash` (or whichever process launchd uses to run the script).

## Commands reference

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

## Environment overrides

| Variable | Default | Purpose |
|---|---|---|
| `SNAPSHOT_DIR` | `$HOME/MacBook-Baseline` | Where captures are written / read |
| `OUTPUT_DIR` | `$HOME/Desktop` | Where the PDF lands |
| `MIN_CAPTURE_TS` | empty | Filter captures earlier than `YYYY-MM-DD_HH-MM` |

## Troubleshooting

**`baseline: command not found`**
`/usr/local/bin` may not be in your PATH. Either add it (`echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.zshrc`), or run with the full path: `~/.local/share/macbook-baseline/bin/baseline help` (Method 1 install) or `<repo-dir>/bin/baseline help` (Method 2 install).

**`AM-skip: no window id` in the log**
Activity Monitor was minimised or off-screen when the capture ran. Re-open it; subsequent captures will pick it up.

**Empty PDF / "no captures"**
Run `baseline status` to verify captures landed. If `Job: not loaded`, run `baseline start`.

**Chart says `Parsed 0 captures`**
`MIN_CAPTURE_TS` may be set too far in the future, or layout is non-standard. Captures must live at `$SNAPSHOT_DIR/YYYY-MM-DD/HH-MM-report.txt`.

**`baseline build` hangs**
Should not happen any more (Chrome is killed once the PDF lands). If it does, `Ctrl-C` and check `pgrep -fl 'Google Chrome.*--headless'` -- those are leftover headless Chrome processes you can `kill`.

## File layout

```
macbook-baseline/
├── bin/
│   └── baseline                              # CLI entry point
├── scripts/
│   ├── memory-snapshot.sh                    # one capture
│   └── build-baseline-pdf.sh                 # assemble PDF
├── launchd/
│   └── com.macbook-baseline.snapshot.plist   # scheduled-capture template
├── install.sh                                # symlinks `baseline` into PATH
└── README.md
```

## License

MIT. See [LICENSE](LICENSE).
