# install.ps1 -- install the `baseline` command on Windows.
#
# Two ways to use this:
#
#   1. One-liner (no clone needed -- this script downloads the toolkit):
#      iwr -useb https://raw.githubusercontent.com/Quattio/macbook-baseline/main/windows/install.ps1 | iex
#
#   2. Manual (after cloning or downloading the repo):
#      cd macbook-baseline\windows
#      powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# Result: a `baseline` command in your PATH (via $env:USERPROFILE\.local\bin).

#requires -Version 5.0
[CmdletBinding()]
param(
    [string]$BinDir = "$env:USERPROFILE\.local\bin"
)

$ErrorActionPreference = 'Stop'

$RepoUrl     = 'https://github.com/Quattio/macbook-baseline.git'
$TarballUrl  = 'https://github.com/Quattio/macbook-baseline/archive/refs/heads/main.zip'
$BundleHome  = if ($env:BUNDLE_HOME) { $env:BUNDLE_HOME } else { "$env:LOCALAPPDATA\Quattio\macbook-baseline" }

# --- Detect mode: running from inside the cloned bundle, or piped via iex? ---
$source = $MyInvocation.MyCommand.Path
if ($source -and (Test-Path $source) -and (Test-Path (Join-Path (Split-Path -Parent $source) 'bin'))) {
    # Running from inside an existing windows/ folder
    $WindowsDir = Split-Path -Parent $source
    Write-Host "Installing from local bundle at $WindowsDir"
} else {
    # Piped via iex -- need to download
    $WindowsDir = Join-Path $BundleHome 'windows'
    $repoRoot   = $BundleHome

    if (Get-Command git -ErrorAction SilentlyContinue) {
        if (Test-Path (Join-Path $repoRoot '.git')) {
            Write-Host "Updating existing toolkit at $repoRoot..."
            git -C $repoRoot pull --quiet
        } else {
            Write-Host "Cloning toolkit -> $repoRoot"
            if (Test-Path $repoRoot) { Remove-Item -Recurse -Force $repoRoot }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $repoRoot) | Out-Null
            git clone --quiet $RepoUrl $repoRoot
        }
    } else {
        Write-Host "git not installed -- downloading zip -> $repoRoot"
        if (Test-Path $repoRoot) { Remove-Item -Recurse -Force $repoRoot }
        New-Item -ItemType Directory -Force -Path $repoRoot | Out-Null
        $zipPath = Join-Path $env:TEMP "macbook-baseline-main.zip"
        Invoke-WebRequest -Uri $TarballUrl -OutFile $zipPath -UseBasicParsing
        $extractTmp = Join-Path $env:TEMP "macbook-baseline-extract-$([guid]::NewGuid())"
        Expand-Archive -Path $zipPath -DestinationPath $extractTmp -Force
        # The zip extracts to macbook-baseline-main/ -- move its contents up
        $inner = Get-ChildItem -Path $extractTmp -Directory | Select-Object -First 1
        Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $repoRoot -Recurse -Force
        Remove-Item -Recurse -Force $extractTmp
        Remove-Item $zipPath
    }
}

if (-not (Test-Path (Join-Path $WindowsDir 'bin\baseline.cmd'))) {
    Write-Error "baseline.cmd not found at $WindowsDir\bin -- bundle layout looks broken."
    exit 1
}

# --- Install: create $BinDir, drop shim ---
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

$shim = Join-Path $BinDir 'baseline.cmd'
$shimContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WindowsDir\bin\baseline.ps1" %*
"@
Set-Content -Path $shim -Value $shimContent -Encoding ascii

Write-Host ""
Write-Host "Installed: $shim"
Write-Host "Points at: $WindowsDir\bin\baseline.ps1"
Write-Host ""

# --- Add $BinDir to user PATH if not already there ---
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if (-not ($userPath -split ';' | Where-Object { $_ -ieq $BinDir })) {
    Write-Host "Adding $BinDir to your user PATH..."
    $newPath = if ($userPath) { "$userPath;$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    Write-Host "PATH updated. Open a new terminal for the change to take effect."
} else {
    Write-Host "$BinDir is already in your user PATH."
}

Write-Host ""
Write-Host "Try (in a new terminal window):"
Write-Host "  baseline help"
Write-Host ""
Write-Host "Quick start:"
Write-Host "  baseline start    # day 0  -- begin scheduled captures"
Write-Host "  baseline build    # day 14 -- assemble the PDF report"
