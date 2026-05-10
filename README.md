# Workload Baseline Toolkit

Capture 1-2 weeks of CPU + GPU + memory snapshots on a Mac or Windows machine, then assemble a single PDF report. Designed for IT teams answering **"is this person's hardware sized correctly?"** with quantified evidence instead of vibes.

## Pick your OS

|  | macOS | Windows |
|---|---|---|
| **Install command** (run in Terminal / PowerShell on the machine you want to measure) | `curl -fsSL https://raw.githubusercontent.com/Quattio/workload-baseline/main/macos/install.sh \| bash` | `iwr -useb https://raw.githubusercontent.com/Quattio/workload-baseline/main/windows/install.ps1 \| iex` |
| **Full docs** | [macos/README.md](macos/README.md) | [windows/README.md](windows/README.md) |
| **Captures land in** | `~/MacBook-Baseline/` | `%USERPROFILE%\Workload-Baseline\` |
| **PDF lands on** | `~/Desktop/` | `%USERPROFILE%\Desktop\` |
| **Activity Monitor / Task Manager screenshots** | Yes (Quartz window capture, never full-screen) | No (per-capture chart PNG as visual evidence) |
| **Tested end-to-end** | Yes (12/12 stress tests pass) | Code-reviewed, not yet validated on a real Windows machine |

## The lifecycle (same on both OSes)

After running the install command above:

```bash
baseline start     # day 0    -- begin scheduled captures (every 30 min while awake)
baseline status    # any day  -- check it's running, see capture count
baseline build     # day 14   -- assemble the PDF, auto-opens on Desktop
baseline stop      # day 14   -- stop further captures (data preserved)
baseline uninstall # cleanup  -- remove the scheduled job (data preserved)
```

That's the whole tool.

## What the PDF contains

1. **Time-series chart** -- memory pressure (top), GPU + CPU pressure (bottom). Threshold lines make sustained pressure obvious at a glance.
2. **Headline stat tiles** -- median pressure values, % of captures over key thresholds.
3. **Composition snapshot** -- live `ps` / `Get-Process` bucketed into Browsers+automation / Communication+media / system.
4. **Appendix** -- every per-capture screenshot or chart in chronological order, two captures per row.

A typical 14-day campaign produces a 5-15 MB PDF (macOS, with screenshots) or 2-8 MB (Windows, chart-only).

## Manual install (if you can't pipe curl/iwr into a shell)

```bash
git clone https://github.com/Quattio/workload-baseline.git
cd workload-baseline/macos    # or workload-baseline/windows
./install.sh                  # or: powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Or grab the ZIP via the green "Code" button -> "Download ZIP", extract, then `cd` into the right OS subfolder.

## Repo layout

```
workload-baseline/
├── README.md          (this file -- OS picker)
├── LICENSE            (MIT)
├── macos/             (everything macOS)
│   ├── README.md
│   ├── bin/baseline
│   ├── scripts/...
│   ├── launchd/...
│   └── install.sh
└── windows/           (everything Windows)
    ├── README.md
    ├── bin/baseline.{ps1,cmd}
    ├── scripts/...
    └── install.ps1
```

## License

MIT. See [LICENSE](LICENSE).
