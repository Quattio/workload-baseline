# Install -- multi-week scheduled capture

For a one-off snapshot, see README.md. This file covers installing the launchd job for a 1-2 week campaign.

## 1. Pick a home for the bundle

```bash
mkdir -p ~/tools
mv ~/Downloads/macbook-baseline-bundle ~/tools/
cd ~/tools/macbook-baseline-bundle
chmod +x scripts/*.sh
```

## 2. Install Python dependencies

```bash
pip3 install matplotlib pyobjc-framework-Quartz
```

If `pip3` is the system Python, you may need `pip3 install --user ...` or a venv. The launchd plist runs with the standard PATH, so whichever interpreter `which python3` resolves to must be the one with the packages.

## 3. Grant Screen Recording permission

System Settings -> Privacy & Security -> Screen Recording -> add your shell (Terminal / iTerm) AND `bash` (it may prompt the first launchd run -- approve when it does).

Without this, the Activity Monitor screenshots are silently skipped (the rest of the capture still works -- you just lose the visual proof).

## 4. Edit the launchd plist

Open `launchd/com.macbook-baseline.snapshot.plist` and replace every `CHANGE_ME` with your username:

```bash
USERNAME=$(whoami)
sed -i '' "s|CHANGE_ME|$USERNAME|g" launchd/com.macbook-baseline.snapshot.plist
```

Verify the script path inside the plist points at where you actually put the bundle:

```bash
grep '<string>/Users' launchd/com.macbook-baseline.snapshot.plist
```

## 5. Install + load

```bash
cp launchd/com.macbook-baseline.snapshot.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.macbook-baseline.snapshot.plist
```

The job runs immediately on load (`RunAtLoad=true`) and then every 30 min while the machine is awake.

## 6. Verify

```bash
# Should appear in launchctl
launchctl list | grep macbook-baseline

# After a few minutes, captures should appear
ls ~/MacBook-Baseline/$(date +%F)/

# Tail the log
tail -f ~/MacBook-Baseline/snapshot.log
```

If captures aren't appearing:
- Check `~/MacBook-Baseline/snapshot-launchd.log` for stdout/stderr
- Try a manual run: `bash scripts/memory-snapshot.sh` and see what fails
- The most common failure mode is missing Python packages -- the JSON + chart steps will silently fail

## 7. Build the PDF after the campaign

```bash
cd ~/tools/macbook-baseline-bundle
scripts/build-baseline-pdf.sh
# -> ~/Desktop/MacBook-Baseline-Report-YYYY-MM-DD.pdf
```

If you want to drop captures before a certain timestamp (e.g. the first few were buggy):

```bash
MIN_CAPTURE_TS=2026-05-04_13-34 scripts/build-baseline-pdf.sh
```

## 8. Stop the scheduled captures

```bash
launchctl unload ~/Library/LaunchAgents/com.macbook-baseline.snapshot.plist
rm ~/Library/LaunchAgents/com.macbook-baseline.snapshot.plist
```

Captures in `$SNAPSHOT_DIR` stay where they are -- delete by hand if you don't need them.

## Sanity checks

```bash
# What does one capture look like?
ls ~/MacBook-Baseline/$(date +%F)/ | head

# Approximate disk usage
du -sh ~/MacBook-Baseline/

# Activity Monitor screenshots present?
find ~/MacBook-Baseline -name '*-AM-memory.png' | wc -l
```

A typical 14-day campaign at 30-min intervals on an active machine produces ~250-350 captures, ~150-300 MB on disk (most of it the Activity Monitor screenshots).
