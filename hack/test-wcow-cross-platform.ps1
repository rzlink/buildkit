#!/usr/bin/env pwsh
# test-wcow-cross-platform.ps1 - Validates WCOW cross-platform layer support
#
# This script must be run as Administrator on a Windows host with the
# Containers feature enabled (vmcompute service). It tests the
# bidirectional cross-platform layer support from issue #4537.
#
# It does NOT require Docker or Docker Desktop; buildkit drives
# containerd's windows snapshotter directly.
#
# Prerequisites:
#   1. Run from an elevated (Administrator) PowerShell prompt
#   2. The 'Containers' Windows feature is enabled (vmcompute service exists)
#   3. containerd.exe is on PATH (the script will start it if not running)
#   4. On Win11 with Defender Controlled Folder Access enabled, the
#      containerd/buildkit binaries must be on the CFA allow list
#      (see docs/wcow-cross-platform-setup.md §0 and §5)
#
# Usage:
#   # From an elevated PowerShell prompt:
#   cd C:\github\buildkit
#   .\hack\test-wcow-cross-platform.ps1

$ErrorActionPreference = "Continue"
$script:passed = 0
$script:failed = 0
$script:skipped = 0

function Write-TestHeader($name) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "TEST: $name" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Pass($msg) {
    $script:passed++
    Write-Host "  PASS: $msg" -ForegroundColor Green
}

function Write-Fail($msg) {
    $script:failed++
    Write-Host "  FAIL: $msg" -ForegroundColor Red
}

function Write-Skip($msg) {
    $script:skipped++
    Write-Host "  SKIP: $msg" -ForegroundColor Yellow
}

# Write a UTF-8 file with no BOM. PowerShell 5.1's Set-Content -Encoding UTF8
# emits a BOM, which the Dockerfile parser rejects.
function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}

# Check prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor White

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

$vmcompute = Get-Service vmcompute -ErrorAction SilentlyContinue
if (-not $vmcompute) {
    Write-Host "ERROR: vmcompute service missing. Enable the 'Containers' Windows feature and reboot:" -ForegroundColor Red
    Write-Host "  Enable-WindowsOptionalFeature -Online -FeatureName Containers -All" -ForegroundColor Yellow
    exit 1
}
if (-not (Get-Command containerd -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: containerd.exe not found in PATH." -ForegroundColor Red
    Write-Host "  Install from https://github.com/containerd/containerd/releases and add to PATH." -ForegroundColor Yellow
    exit 1
}

# Build from source
Write-Host "`nBuilding buildkitd and buildctl from source..." -ForegroundColor White
$repoRoot = $PSScriptRoot | Split-Path -Parent
Push-Location $repoRoot

go build -o "$repoRoot\bin\buildkitd.exe" ./cmd/buildkitd 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "Failed to build buildkitd"; exit 1 }

go build -o "$repoRoot\bin\buildctl.exe" ./cmd/buildctl 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "Failed to build buildctl"; exit 1 }

$buildctl = "$repoRoot\bin\buildctl.exe"
$buildkitd = "$repoRoot\bin\buildkitd.exe"

Write-Host "Built successfully." -ForegroundColor Green

# If Defender Controlled Folder Access is in a blocking state, allow-list
# our three binaries. Idempotent and a no-op when CFA is off.
try {
    $cfaState = (Get-MpPreference).EnableControlledFolderAccess
    if ($cfaState -eq 1 -or $cfaState -eq 3) {
        $ctrdBin = (Get-Command containerd -ErrorAction SilentlyContinue).Source
        $exes = @($buildctl, $buildkitd)
        if ($ctrdBin) { $exes += $ctrdBin }
        foreach ($exe in $exes) {
            try {
                Add-MpPreference -ControlledFolderAccessAllowedApplications $exe -ErrorAction Stop
                Write-Host "  CFA allow-listed: $exe" -ForegroundColor DarkGray
            } catch {}
        }
    }
} catch {}

# Ensure containerd is running. We launch it with a script-managed minimal
# config to avoid loading any system-level config.toml that may be incompatible
# with the containerd binary on PATH (e.g., a config written by a different
# containerd version with a newer schema).
$ctrd = Get-Process containerd -ErrorAction SilentlyContinue
if (-not $ctrd) {
    Write-Host "Starting containerd..." -ForegroundColor White
    $ctrdBin = Get-Command containerd -ErrorAction SilentlyContinue
    $ctrdCfgDir = Join-Path $env:TEMP "wcow-cross-platform-test-ctrd-cfg"
    New-Item -ItemType Directory -Force -Path $ctrdCfgDir | Out-Null
    $ctrdCfg = Join-Path $ctrdCfgDir "config.toml"
    @'
version = 3
root = "C:\\ProgramData\\containerd\\root"
state = "C:\\ProgramData\\containerd\\state"

[grpc]
  address = "\\\\.\\pipe\\containerd-containerd"

[debug]
  level = "info"
'@ | Set-Content -Path $ctrdCfg -Encoding ASCII
    Start-Process -FilePath $ctrdBin.Source -ArgumentList "--config",$ctrdCfg -NoNewWindow
    Start-Sleep -Seconds 6
    $ctrd = Get-Process containerd -ErrorAction SilentlyContinue
    if (-not $ctrd) {
        Write-Host "ERROR: containerd failed to start. Check %TEMP%\wcow-cross-platform-test-ctrd-cfg for the config used." -ForegroundColor Red
        exit 1
    }
}

# Ensure buildkitd is running with --group Users for non-elevated access
$bkd = Get-Process buildkitd -ErrorAction SilentlyContinue
if ($bkd) {
    Write-Host "Stopping existing buildkitd (PID $($bkd.Id))..." -ForegroundColor White
    Stop-Process -Id $bkd.Id -Force
    Start-Sleep -Seconds 3
}

Write-Host "Starting buildkitd with --group Users..." -ForegroundColor White
Start-Process -FilePath $buildkitd -ArgumentList "--debug","--group","Users" -NoNewWindow
Start-Sleep -Seconds 5

# Verify buildkitd is responding
$workers = & $buildctl debug workers 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: buildkitd not responding: $workers" -ForegroundColor Red
    exit 1
}
Write-Host "buildkitd running. Workers:`n$workers" -ForegroundColor Green

$tmpDir = Join-Path $env:TEMP "wcow-cross-platform-test"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

# All tests below use RUN-less Linux stages. A Windows-only buildkit worker
# cannot execute Linux containers, so `RUN` in a `--platform=linux/amd64`
# stage will always fail with `hcs::CreateComputeSystem ... The system
# cannot find the file specified.`  COPY --from=<linux-stage> reads files
# straight out of the transformed Linux layer (no execution needed), which
# is exactly the cross-platform code path issue #4537 added.

# ============================================================
# Test 1: COPY a single file from a Linux layer to a Windows layer
# ============================================================
Write-TestHeader "Cross-platform COPY: single file from Linux layer (alpine)"

Write-Utf8NoBom "$tmpDir\Dockerfile" @"
FROM --platform=linux/amd64 docker.io/library/alpine:3.20 AS linuxsource

FROM mcr.microsoft.com/windows/nanoserver:ltsc2022
COPY --from=linuxsource /etc/alpine-release /from-linux/alpine-release
"@

$destDir1 = Join-Path $tmpDir "output-single"
if (Test-Path $destDir1) { Remove-Item -Recurse -Force $destDir1 }
New-Item -ItemType Directory -Force -Path $destDir1 | Out-Null

$output = & $buildctl build `
    --progress=plain `
    --frontend dockerfile.v0 `
    --local context=$tmpDir `
    --local dockerfile=$tmpDir `
    --output "type=local,dest=$destDir1" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Pass "Linux->Windows COPY build succeeded"
    if (Test-Path "$destDir1\from-linux\alpine-release") {
        $v = (Get-Content "$destDir1\from-linux\alpine-release" -Raw).Trim()
        if ($v -match '^\d+\.\d+(\.\d+)?$') {
            Write-Pass "alpine-release content looks valid: '$v'"
        } else {
            Write-Fail "alpine-release content unexpected: '$v'"
        }
    } else {
        Write-Fail "Expected output file from-linux\alpine-release not found in $destDir1"
    }
} else {
    Write-Fail "Linux->Windows COPY build failed: $($output | Select-Object -Last 10)"
}

# ============================================================
# Test 2: Cross-platform COPY: explicit multi-stage with named stage
# ============================================================
Write-TestHeader "Cross-platform COPY: explicit multi-stage (named Linux stage)"

Write-Utf8NoBom "$tmpDir\Dockerfile" @"
FROM --platform=linux/amd64 docker.io/library/alpine:3.20 AS linux-stage

FROM mcr.microsoft.com/windows/nanoserver:ltsc2022
COPY --from=linux-stage /etc/os-release /os-release-from-linux
"@

$destDir = Join-Path $tmpDir "output-cross"
if (Test-Path $destDir) { Remove-Item -Recurse -Force $destDir }
New-Item -ItemType Directory -Force -Path $destDir | Out-Null

$output = & $buildctl build `
    --progress=plain `
    --frontend dockerfile.v0 `
    --local context=$tmpDir `
    --local dockerfile=$tmpDir `
    --output "type=local,dest=$destDir" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Pass "Cross-platform COPY build succeeded"
    if (Test-Path "$destDir\os-release-from-linux") {
        $content = Get-Content "$destDir\os-release-from-linux" -Raw
        if ($content -match 'alpine') {
            Write-Pass "Copied file mentions 'alpine' as expected"
        } else {
            Write-Fail "Copied file content unexpected: '$($content.Trim())'"
        }
    } else {
        Write-Fail "Expected output file os-release-from-linux not found in $destDir"
    }
} else {
    Write-Fail "Cross-platform COPY build failed: $($output | Select-Object -Last 10)"
}

# ============================================================
# Test 3: Cross-platform multi-file directory copy
# ============================================================
Write-TestHeader "Cross-platform multi-file directory copy"

# /etc contains many small files in alpine; copying the whole directory
# exercises the layer-walk + file-extraction path more thoroughly than a
# single-file COPY.
Write-Utf8NoBom "$tmpDir\Dockerfile" @"
FROM --platform=linux/amd64 docker.io/library/alpine:3.20 AS linux-build

FROM mcr.microsoft.com/windows/nanoserver:ltsc2022
COPY --from=linux-build /etc /etc-from-linux
"@

$destDir2 = Join-Path $tmpDir "output-multi"
if (Test-Path $destDir2) { Remove-Item -Recurse -Force $destDir2 }
New-Item -ItemType Directory -Force -Path $destDir2 | Out-Null

$output = & $buildctl build `
    --progress=plain `
    --frontend dockerfile.v0 `
    --local context=$tmpDir `
    --local dockerfile=$tmpDir `
    --output "type=local,dest=$destDir2" 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Pass "Multi-file cross-platform COPY build succeeded"

    $alpineRelease = Test-Path "$destDir2\etc-from-linux\alpine-release"
    $osRelease     = Test-Path "$destDir2\etc-from-linux\os-release"
    if ($alpineRelease) { Write-Pass "etc-from-linux\alpine-release exists" } else { Write-Fail "etc-from-linux\alpine-release missing" }
    if ($osRelease)     { Write-Pass "etc-from-linux\os-release exists" }     else { Write-Fail "etc-from-linux\os-release missing" }
} else {
    Write-Fail "Multi-file cross-platform build failed: $($output | Select-Object -Last 10)"
}

# ============================================================
# Test 4: Different Linux base images
# ============================================================
# All three base images carry /etc/os-release; copying it out is a uniform
# cross-image probe of the Linux-layer extraction path.
foreach ($image in @("docker.io/library/alpine:3.20", "docker.io/library/ubuntu:22.04", "docker.io/library/debian:bookworm-slim")) {
    Write-TestHeader "Linux image variant: $image"

    Write-Utf8NoBom "$tmpDir\Dockerfile" @"
FROM --platform=linux/amd64 $image AS src

FROM mcr.microsoft.com/windows/nanoserver:ltsc2022
COPY --from=src /etc/os-release /os-release
"@

    $output = & $buildctl build `
        --progress=plain `
        --frontend dockerfile.v0 `
        --local context=$tmpDir `
        --local dockerfile=$tmpDir 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Pass "$image cross-platform COPY succeeded"
    } else {
        Write-Fail "$image cross-platform COPY failed: $($output | Select-Object -Last 5)"
    }
}

# ============================================================
# Summary
# ============================================================
Write-Host "`n========================================" -ForegroundColor White
Write-Host "RESULTS" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
Write-Host "  Passed:  $script:passed" -ForegroundColor Green
Write-Host "  Failed:  $script:failed" -ForegroundColor Red
Write-Host "  Skipped: $script:skipped" -ForegroundColor Yellow
Write-Host ""

# Cleanup (preserve $tmpDir on failure for triage)
if ($script:failed -eq 0) {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
} else {
    Write-Host "Leaving $tmpDir intact for triage." -ForegroundColor Yellow
}

Pop-Location

if ($script:failed -gt 0) {
    Write-Host "Some tests FAILED." -ForegroundColor Red
    exit 1
} else {
    Write-Host "All tests PASSED." -ForegroundColor Green
    exit 0
}
