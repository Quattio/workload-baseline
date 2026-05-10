# Capture-Snapshot.ps1 -- take one workload snapshot on Windows.
#
# Equivalent of macOS scripts/memory-snapshot.sh. Collects CPU/Memory/GPU
# counters + top RAM/CPU processes via PowerShell, writes a text report,
# JSON, and a chart PNG (rendered by render_chart.py).
#
# Output (per capture):
#   $SnapshotDir\YYYY-MM-DD\HH-mm-report.txt
#   $SnapshotDir\YYYY-MM-DD\HH-mm-data.json
#   $SnapshotDir\YYYY-MM-DD\HH-mm-chart.png   (if python3 + matplotlib available)
#
# No Task Manager screenshots -- the chart PNG carries the per-capture visual.
#
# Usage:
#   pwsh -File Capture-Snapshot.ps1
#   pwsh -File Capture-Snapshot.ps1 -SnapshotDir C:\tmp\test -DailyCap 200

#requires -Version 5.0
[CmdletBinding()]
param(
    [string]$SnapshotDir = "$env:USERPROFILE\Workload-Baseline",
    [string]$LogFile = "",
    [string]$Reason = "scheduled",
    [int]$DailyCap = 50
)

$ErrorActionPreference = 'Stop'

if (-not $LogFile) { $LogFile = Join-Path $SnapshotDir "snapshot.log" }
New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null

$Today = Get-Date -Format 'yyyy-MM-dd'
$Now   = Get-Date -Format 'HH-mm'
$OutDir = Join-Path $SnapshotDir $Today
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Write-CaptureLog {
    param([string]$Message)
    "[{0}] {1}" -f (Get-Date -Format 'o'), $Message | Out-File -Append -FilePath $LogFile -Encoding utf8
}

# --- 1. Daily cap check ---
$existing = @(Get-ChildItem -Path $OutDir -Filter '*-report.txt' -ErrorAction SilentlyContinue)
if ($existing.Count -ge $DailyCap) {
    Write-CaptureLog "skip: already $($existing.Count) captures today (cap=$DailyCap, reason=$Reason)"
    exit 0
}

# --- 2. CPU + Memory counters ---
function Get-CounterSafe {
    param([string]$Path)
    try {
        $r = Get-Counter -Counter $Path -ErrorAction Stop -MaxSamples 1
        return $r.CounterSamples[0].CookedValue
    } catch {
        return $null
    }
}

$cpuBusy       = Get-CounterSafe '\Processor(_Total)\% Processor Time'
$memAvailMB    = Get-CounterSafe '\Memory\Available MBytes'
$memCommitPct  = Get-CounterSafe '\Memory\% Committed Bytes In Use'
$pagesPerSec   = Get-CounterSafe '\Memory\Pages/sec'

$totalMemMB = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
$memUsedMB  = if ($memAvailMB -ne $null) { $totalMemMB - [int]$memAvailMB } else { $null }

# --- 3. GPU counters (best-effort; some machines lack these) ---
$gpuUtil = 0
try {
    $gpuSamples = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop -MaxSamples 1).CounterSamples
    $gpuUtil = [math]::Min(100, [math]::Round(($gpuSamples | Measure-Object CookedValue -Sum).Sum, 1))
} catch {
    $gpuUtil = 0
}

# --- 4. Top processes ---
$procs = Get-Process | Where-Object { $_.WorkingSet64 -gt 0 }
$topByMem = $procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 20 Name, Id, WorkingSet64, CPU
$topByCpu = $procs | Sort-Object CPU -Descending          | Select-Object -First 20 Name, Id, WorkingSet64, CPU

# --- 5. Process counts (parity with macOS report) ---
$nChrome = (Get-Process -Name 'chrome' -ErrorAction SilentlyContinue).Count
$nEdge   = (Get-Process -Name 'msedge' -ErrorAction SilentlyContinue).Count
$nNode   = (Get-Process -Name 'node' -ErrorAction SilentlyContinue).Count
$nTeams  = (Get-Process -Name 'ms-teams','Teams' -ErrorAction SilentlyContinue).Count
$nSlack  = (Get-Process -Name 'slack' -ErrorAction SilentlyContinue).Count

# --- 6. Write text report ---
$reportFile = Join-Path $OutDir "$Now-report.txt"
$ramTopLines = $topByMem | ForEach-Object {
    "{0,-7} {1,8:N0} MB  {2,7:N1}%  {3}" -f $_.Id, ($_.WorkingSet64 / 1MB), ($_.CPU), $_.Name
}
$cpuTopLines = $topByCpu | ForEach-Object {
    "{0,-7} {1,7:N1}%  {2,8:N0} MB  {3}" -f $_.Id, ($_.CPU), ($_.WorkingSet64 / 1MB), $_.Name
}

$os = Get-CimInstance Win32_OperatingSystem
$report = @"
=== Windows Workload Snapshot $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') reason=$Reason ===

--- Host ---
Computer:    $env:COMPUTERNAME
User:        $env:USERNAME
OS:          $($os.Caption) $($os.Version) (build $($os.BuildNumber))
Total RAM:   $totalMemMB MB

--- CPU + Memory ---
CPU busy:            $([math]::Round([double]$cpuBusy, 1))%
Memory committed:    $([math]::Round([double]$memCommitPct, 1))%
Memory available:    $([int]$memAvailMB) MB
Memory in use:       $memUsedMB MB
Pages/sec:           $([math]::Round([double]$pagesPerSec, 1))

--- GPU ---
GPU 3D utilization:  ${gpuUtil}%

--- Top 20 RAM consumers (PID  RSS  CPU%  Name) ---
$($ramTopLines -join [Environment]::NewLine)

--- Top 20 CPU consumers (PID  CPU%  RSS  Name) ---
$($cpuTopLines -join [Environment]::NewLine)

--- Process counts ---
Chrome:      $nChrome
Edge:        $nEdge
Node:        $nNode
Teams:       $nTeams
Slack:       $nSlack
"@
Set-Content -Path $reportFile -Value $report -Encoding utf8

# --- 7. Write JSON ---
$jsonFile = Join-Path $OutDir "$Now-data.json"
$data = [ordered]@{
    ts     = (Get-Date).ToString('o')
    reason = $Reason
    host   = @{
        computer  = $env:COMPUTERNAME
        user      = $env:USERNAME
        os        = $os.Caption
        os_build  = $os.BuildNumber
    }
    load_1 = $null   # Windows has no 1-min load avg; macOS-shaped null
    cpu    = @{
        busy_pct = [math]::Round([double]$cpuBusy, 2)
        idle_pct = [math]::Round(100 - [double]$cpuBusy, 2)
    }
    gpu    = @{
        device_util_pct = $gpuUtil
    }
    memory_mb = @{
        used         = $memUsedMB
        unused       = [int]$memAvailMB
        total        = $totalMemMB
        committed_pct = [math]::Round([double]$memCommitPct, 2)
        pages_per_sec = [math]::Round([double]$pagesPerSec, 2)
    }
    process_counts = @{
        chrome = $nChrome
        edge   = $nEdge
        node   = $nNode
        teams  = $nTeams
        slack  = $nSlack
    }
}
$data | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonFile -Encoding utf8

# --- 8. Per-capture chart (Python + matplotlib) ---
$chartFile = Join-Path $OutDir "$Now-chart.png"
$renderScript = Join-Path $PSScriptRoot 'render_chart.py'
if (Test-Path $renderScript) {
    $py = $null
    foreach ($name in @('python3','python','py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $py = $cmd.Source; break }
    }
    if ($py) {
        try {
            & $py $renderScript $jsonFile $chartFile 2>$null
            if (-not (Test-Path $chartFile)) {
                Write-CaptureLog "chart skip: render_chart.py produced no file"
            }
        } catch {
            Write-CaptureLog "chart skip: $($_.Exception.Message)"
        }
    } else {
        Write-CaptureLog "chart skip: python not found on PATH"
    }
}

# --- 9. Log success ---
$newCount = $existing.Count + 1
Write-CaptureLog ("captured: {0} reason={1} count={2}/{3} cpu={4}% gpu={5}% mem_avail={6}MB" -f `
    $Now, $Reason, $newCount, $DailyCap, [math]::Round([double]$cpuBusy,1), $gpuUtil, [int]$memAvailMB)
