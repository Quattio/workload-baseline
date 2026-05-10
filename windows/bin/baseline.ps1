# baseline.ps1 -- single-command CLI for the Windows workload baseline toolkit.
#
# Subcommands:
#   baseline start              Install deps + register scheduled task (start captures)
#   baseline status             Show campaign state, capture count, last log line
#   baseline build [-MinTs T]   Build the PDF report from collected captures
#   baseline stop               Unregister the scheduled task (stop capturing)
#   baseline uninstall          Stop + remove the scheduled task (preserves captures)
#   baseline help               Show this help

#requires -Version 5.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Subcommand = 'help',

    [string]$MinTs = ""
)

$ErrorActionPreference = 'Stop'

# --- Locate the bundle root (regardless of how this was invoked) ---
$BundleRoot = (Get-Item -LiteralPath (Split-Path -Parent $MyInvocation.MyCommand.Path)).Parent.FullName
$ScriptsDir = Join-Path $BundleRoot 'scripts'
$CaptureScript = Join-Path $ScriptsDir 'Capture-Snapshot.ps1'
$BuildPyScript = Join-Path $ScriptsDir 'build_pdf.py'

$SnapshotDir = if ($env:SNAPSHOT_DIR) { $env:SNAPSHOT_DIR } else { "$env:USERPROFILE\Workload-Baseline" }
$TaskName = 'WorkloadBaselineSnapshot'

function Say  { param([string]$m) Write-Host $m }
function Warn { param([string]$m) Write-Host "!! $m" -ForegroundColor Yellow }
function Die  { param([string]$m) Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

function Test-Python {
    foreach ($name in @('python3','python','py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Ensure-PythonDeps {
    $py = Test-Python
    if (-not $py) {
        Die "python is not installed. Install Python 3 from https://www.python.org/downloads/windows/ then re-run."
    }
    & $py -c "import matplotlib" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Say "Installing matplotlib via pip..."
        & $py -m pip install --user --quiet matplotlib
        if ($LASTEXITCODE -ne 0) {
            Die "pip install matplotlib failed. Run manually: py -m pip install --user matplotlib"
        }
    }
}

function Cmd-Start {
    if (-not (Test-Path $CaptureScript)) { Die "Capture-Snapshot.ps1 missing at $CaptureScript" }
    Ensure-PythonDeps
    New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null

    Say "Registering scheduled task '$TaskName'..."

    # Build the action that the task will run every 30 min
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -SnapshotDir "{1}" -DailyCap 200' -f $CaptureScript, $SnapshotDir)

    # Trigger: starting now, repeat every 30 minutes, indefinitely
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(60) `
        -RepetitionInterval (New-TimeSpan -Minutes 30)

    # Settings: don't wake to run, stop on battery (mirrors macOS launchd-while-awake behavior)
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries:$false `
        -DontStopIfGoingOnBatteries:$false `
        -StartWhenAvailable:$true `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    # Unregister first if it exists (idempotent re-register)
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal `
        -Description 'Captures CPU/Memory/GPU snapshots every 30 min for the workload baseline toolkit.' | Out-Null

    # Kick off the first capture immediately so the user can verify
    Say "Triggering first capture..."
    Start-ScheduledTask -TaskName $TaskName

    Say ""
    Say "Campaign started. Captures land in: $SnapshotDir"
    Say "Schedule: every 30 minutes while the machine is awake (no wake-to-run, stops on battery)."
    Say ""
    Say "Next steps:"
    Say "  baseline status    # check it's running"
    Say "  baseline build     # after 1-2 weeks, generate the PDF"
}

function Cmd-Status {
    Say "Bundle:     $BundleRoot"
    Say "Snapshots:  $SnapshotDir"

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo
        Say "Task:       $($task.State) (last run: $($info.LastRunTime), last result: $($info.LastTaskResult))"
    } else {
        Say "Task:       not registered (run 'baseline start')"
    }

    if (Test-Path $SnapshotDir) {
        $reports = @(Get-ChildItem -Path $SnapshotDir -Recurse -Filter '*-report.txt' -ErrorAction SilentlyContinue)
        $dayDirs = @(Get-ChildItem -Path $SnapshotDir -Directory -Filter '20*' -ErrorAction SilentlyContinue)
        Say "Captures:   $($reports.Count) across $($dayDirs.Count) day(s)"
        $logFile = Join-Path $SnapshotDir 'snapshot.log'
        if (Test-Path $logFile) {
            $lastLine = Get-Content -Path $logFile -Tail 1 -ErrorAction SilentlyContinue
            if ($lastLine) { Say "Last log:   $lastLine" }
        }
    } else {
        Say "Captures:   none yet"
    }
}

function Cmd-Build {
    param([string]$MinTs)

    if (-not (Test-Path $SnapshotDir)) {
        Die "$SnapshotDir not found -- run 'baseline start' first"
    }
    $reports = @(Get-ChildItem -Path $SnapshotDir -Recurse -Filter '*-report.txt' -ErrorAction SilentlyContinue)
    if ($reports.Count -eq 0) {
        Die "no captures yet in $SnapshotDir"
    }

    Ensure-PythonDeps

    if (-not (Test-Path $BuildPyScript)) {
        Die "build_pdf.py missing at $BuildPyScript"
    }

    $env:SNAPSHOT_DIR = $SnapshotDir
    if (-not $env:OUTPUT_DIR) { $env:OUTPUT_DIR = "$env:USERPROFILE\Desktop" }
    if ($MinTs) { $env:MIN_CAPTURE_TS = $MinTs } else { $env:MIN_CAPTURE_TS = "" }

    $py = Test-Python
    & $py $BuildPyScript
    if ($LASTEXITCODE -ne 0) {
        Die "build_pdf.py exited with code $LASTEXITCODE"
    }

    $pdf = Join-Path $env:OUTPUT_DIR ("Workload-Baseline-Report-{0:yyyy-MM-dd}.pdf" -f (Get-Date))
    if (Test-Path $pdf) {
        Say ""
        Say "Opening $pdf"
        Start-Process $pdf
    }
}

function Cmd-Stop {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Say "Nothing to stop -- task '$TaskName' is not registered."
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Say "Stopped. Captures preserved in $SnapshotDir."
}

function Cmd-Uninstall {
    Cmd-Stop
    Say ""
    Say "Captures NOT deleted. Remove manually if desired:"
    Say "  Remove-Item -Recurse -Force '$SnapshotDir'"
}

function Cmd-Help {
@'
baseline -- Windows Workload Baseline Toolkit

Usage:
  baseline start                Install deps + start scheduled captures
  baseline status               Show current state, capture count, last log
  baseline build [-MinTs T]     Generate PDF from collected captures, open it
                                T format: YYYY-MM-DD_HH-MM (filter early captures)
  baseline stop                 Stop scheduled captures (preserves data)
  baseline uninstall            Stop + remove scheduled task (preserves data)
  baseline help                 This screen

Typical workflow:
  baseline start                # day 0 -- begin campaign
  baseline status               # any time -- sanity check
  baseline build                # day 14 -- generate PDF report
  baseline stop                 # day 14 -- stop further captures

Environment overrides:
  SNAPSHOT_DIR  Where captures live (default: %USERPROFILE%\Workload-Baseline)
  OUTPUT_DIR    Where the PDF lands  (default: %USERPROFILE%\Desktop)

Captures land in %SNAPSHOT_DIR%; PDF lands in %OUTPUT_DIR%.
'@ | Write-Host
}

switch ($Subcommand.ToLower()) {
    'start'     { Cmd-Start }
    'status'    { Cmd-Status }
    'build'     { Cmd-Build -MinTs $MinTs }
    'stop'      { Cmd-Stop }
    'uninstall' { Cmd-Uninstall }
    'help'      { Cmd-Help }
    '-h'        { Cmd-Help }
    '--help'    { Cmd-Help }
    default     { Cmd-Help; exit 1 }
}
