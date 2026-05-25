#!/usr/bin/env pwsh
# test-wcow-cross-platform.ps1 - Validates WCOW cross-platform layer support
#
# This script must be run as Administrator on a Windows host with Docker in
# Windows container mode. It tests the bidirectional cross-platform layer
# support from issue #4537.
#
# Prerequisites:
#   1. Docker Desktop switched to Windows containers
#   2. containerd running (the script will start it if not)
#   3. Run from an elevated (Administrator) PowerShell prompt
#
# Usage:
#   # From an elevated PowerShell prompt:
#   cd C:\github\buildkit
#   .\hack\test-wcow-cross-platform.ps1

$ErrorActionPreference = "Stop"
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

# Check prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor White

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

$dockerOS = docker info --format '{{.OSType}}' 2>$null
if ($dockerOS -ne "windows") {
    Write-Host "ERROR: Docker must be in Windows container mode. Current: $dockerOS" -ForegroundColor Red
    Write-Host "Switch with: & 'C:\Program Files\Docker\Docker\DockerCli.exe' -SwitchDaemon" -ForegroundColor Yellow
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

# Ensure containerd is running
$ctrd = Get-Process containerd -ErrorAction SilentlyContinue
if (-not $ctrd) {
    Write-Host "Starting containerd..." -ForegroundColor White
    $ctrdBin = Get-Command containerd -ErrorAction SilentlyContinue
    if (-not $ctrdBin) {
        Write-Host "ERROR: containerd not found in PATH" -ForegroundColor Red
        exit 1
    }
    Start-Process -FilePath $ctrdBin.Source -NoNewWindow
    Start-Sleep -Seconds 5
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

# ============================================================
# Test 1: Pull a Linux image on a Windows host
# ============================================================
Write-TestHeader "Pull Linux image on Windows host"

@"
FROM --platform=linux/amd64 alpine:3.20
RUN echo hello-from-linux > /test.txt
"@ | Set-Content -Path "$tmpDir\Dockerfile" -Encoding UTF8

$output = & $buildctl build `
    --progress=plain `
    --frontend dockerfile.v0 `
    --local context=$tmpDir `
    --local dockerfile=$tmpDir `
    --opt platform=linux/amd64 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Pass "Linux image pull and build succeeded on Windows host"
    # Check if output mentions layer transformation
    $layerLines = $output | Select-String -Pattern "layer|cross|platform|linux" -SimpleMatch
    if ($layerLines) {
        Write-Host "  Layer-related output:" -ForegroundColor Gray
        $layerLines | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
} else {
    Write-Fail "Linux image pull failed: $($output | Select-Object -Last 5)"
}

# ============================================================
# Test 2: Cross-platform COPY from Linux stage to Windows stage
# ============================================================
Write-TestHeader "Cross-platform COPY: Linux stage -> Windows stage"

@"
FROM --platform=linux/amd64 alpine:3.20 AS linux-stage
RUN echo linux-layer-data > /data.txt

FROM mcr.microsoft.com/windows/nanoserver:ltsc2022
COPY --from=linux-stage /data.txt /data.txt
"@ | Set-Content -Path "$tmpDir\Dockerfile" -Encoding UTF8

$destDir = Join-Path $tmpDir "output-cross"
New-Item -ItemType Directory -Force -Path $destDir | Out-Null

$output = & $buildctl build `
    --progress=plain `
    --frontend dockerfile.v0 `
    --local context=$tmpDir `
    --local dockerfile=$tmpDir `
    --output type=local,dest=$destDir 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Pass "Cross-platform COPY build succeeded"
    if (Test-Path "$destDir\data.txt") {
        $content = Get-Content "$destDir\data.txt" -Raw
        if ($content -match "linux-layer-data") {
            Write-Pass "Copied file contains expected content: '$($content.Trim())'"
        } else {
            Write-Fail "Copied file has unexpected content: '$($content.Trim())'"
        }
    } else {
        Write-Fail "Expected output file data.txt not found in $destDir"
    }
} else {
    Write-Fail "Cross-platform COPY build failed: $($output | Select-Object -Last 10)"
}

# ============================================================
# Test 3: Cross-platform multi-stage with multiple files
# ============================================================
Write-TestHeader "Cross-platform multi-stage: multiple files and symlinks"

@"
FROM --platform=linux/amd64 alpine:3.20 AS linux-build
RUN mkdir -p /app/bin && \
    echo '#!/bin/sh' > /app/bin/start.sh && \
    echo 'config-value' > /app/config.txt && \
    ln -s /app/bin/start.sh /app/entrypoint

FROM mcr.microsoft.com/windows/nanoserver:ltsc2022
COPY --from=linux-build /app /app
"@ | Set-Content -Path "$tmpDir\Dockerfile" -Encoding UTF8

$destDir2 = Join-Path $tmpDir "output-multi"
New-Item -ItemType Directory -Force -Path $destDir2 | Out-Null

$output = & $buildctl build `
    --progress=plain `
    --frontend dockerfile.v0 `
    --local context=$tmpDir `
    --local dockerfile=$tmpDir `
    --output type=local,dest=$destDir2 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Pass "Multi-file cross-platform COPY build succeeded"

    $binSh = Test-Path "$destDir2\app\bin\start.sh"
    $config = Test-Path "$destDir2\app\config.txt"
    if ($binSh) { Write-Pass "app/bin/start.sh exists" } else { Write-Fail "app/bin/start.sh missing" }
    if ($config) { Write-Pass "app/config.txt exists" } else { Write-Fail "app/config.txt missing" }
} else {
    Write-Fail "Multi-file cross-platform build failed: $($output | Select-Object -Last 10)"
}

# ============================================================
# Test 4: Different Linux base images
# ============================================================
foreach ($image in @("alpine:3.20", "ubuntu:22.04", "debian:bookworm-slim")) {
    Write-TestHeader "Linux image variant: $image"

    @"
FROM --platform=linux/amd64 $image AS src
RUN echo "from-$image" > /marker.txt

FROM mcr.microsoft.com/windows/nanoserver:ltsc2022
COPY --from=src /marker.txt /marker.txt
"@ | Set-Content -Path "$tmpDir\Dockerfile" -Encoding UTF8

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

# Cleanup
Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

Pop-Location

if ($script:failed -gt 0) {
    Write-Host "Some tests FAILED." -ForegroundColor Red
    exit 1
} else {
    Write-Host "All tests PASSED." -ForegroundColor Green
    exit 0
}
