# BuildKit Windows Development Environment Setup

This document provides step-by-step instructions for setting up a complete BuildKit development environment on Windows Server 2022.

## Prerequisites

- Windows Server 2022
- Administrator privileges
- Internet connection

## Step 1: Provision Windows Server 2022 VM

Set up a Windows Server 2022 virtual machine with:
- Minimum 8GB RAM
- At least 100GB disk space
- Network connectivity enabled

## Step 2: Enable Container Features

Enable the required Windows container features and Hyper-V. Run this command in an **elevated PowerShell session**:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V, Containers -All
```

**⚠️ Important**: Restart the machine after installing these features.

```powershell
Restart-Computer
```

## Step 3: Install Chocolatey Package Manager

Install Chocolatey to simplify software installation. Run this in an **elevated PowerShell session**:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
```

## Step 4: Install Development Tools

Install essential development tools using Chocolatey in an **elevated PowerShell session**:

```powershell
# Install Go programming language
choco install go -y

# Install Git version control
choco install git.install -y

# Install Visual Studio Code
choco install vscode -y
```

## Step 5: Verify Tool Installation

Open a **new PowerShell session** (to refresh PATH) and verify all tools are installed correctly:

```powershell
# Verify Go installation
where.exe go
go version

# Verify Git installation
where.exe git
git --version

# Verify VS Code installation
where.exe code
```

Expected output should show the installation paths for each tool.

## Step 6: Install Testing Tools

You have two options for installing the required testing tools:

### Option A: Direct Installation (Go Install)

Install the required Go testing utilities directly:

#### Install gotestsum
```powershell
# Install gotestsum test runner
go install gotest.tools/gotestsum@latest

# Verify installation
where.exe gotestsum
```

#### Install Docker Registry (v2.8.3)
**⚠️ Important**: BuildKit tests require registry v2.8.3, not the latest v3.x versions.

```powershell
# Install registry v2.8.3 (compatible with BuildKit)
go install github.com/distribution/distribution/v2/cmd/registry@v2.8.3

# Verify installation
where.exe registry
```

### Option B: Using WSL and Cross-Compilation

This approach uses WSL to cross-compile all required binaries, similar to the BuildKit CI process.

#### Install WSL
```powershell
# Install WSL (requires restart)
wsl.exe --install

# Update WSL to latest version
wsl --update --web-download

# Install Ubuntu 24.04
wsl --install -d Ubuntu-24.04
```

#### Install Docker Desktop
```powershell
# Install Docker Desktop with WSL2 backend
choco install docker-desktop
```

> **Note**: After installation, configure Docker Desktop to use WSL2 backend in Settings → General → Use the WSL 2 based engine.

#### Cross-compile binaries in WSL
Open your WSL Ubuntu environment and run:

```bash
# Clone BuildKit repository in WSL
git clone https://github.com/<your_github_account>/buildkit.git
cd buildkit

# Cross-compile Windows binaries using Docker Buildx
docker buildx bake binaries-for-test --set="*.platform=windows/amd64"

# Create shared directory accessible from Windows
mkdir -p /mnt/c/buildkit-windows-bins

# Copy Windows binaries to Windows-accessible location
cp ./bin/build/*.exe /mnt/c/buildkit-windows-bins/
```

#### Add binaries to Windows PATH
Back in Windows PowerShell, add the binaries to your PATH:

```powershell
# Add the shared directory to user PATH
$WSLBinPath = "C:\buildkit-windows-bins"
$CurrentUserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if (-not ($CurrentUserPath -split ";" | Where-Object { $_ -eq $WSLBinPath })) {
    [Environment]::SetEnvironmentVariable("PATH", $CurrentUserPath + ";" + $WSLBinPath, "User")
    $env:Path = $env:Path + ";" + $WSLBinPath
    Write-Host "✅ Added WSL-built binaries to PATH"
}

# Verify binaries are available
gotestsum --version
registry --version
```

## Step 7: Install containerd

### Option A: Manual Installation

Install containerd container runtime using this PowerShell script:

```powershell
# Configuration
$Version = "1.7.13"
$Arch = "amd64"
$Temp = $env:TEMP
$DownloadUrl = "https://github.com/containerd/containerd/releases/download/v$Version/containerd-$Version-windows-$Arch.tar.gz"
$ArchivePath = Join-Path $Temp "containerd-$Version-windows-$Arch.tar.gz"
$InstallDir = Join-Path $env:ProgramFiles "containerd"

# Download containerd archive to TEMP
Write-Host "📥 Downloading containerd $Version..."
Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath

# Extract in-place in TEMP
Write-Host "📦 Extracting archive..."
tar.exe -xvf $ArchivePath -C $Temp

# Copy binaries to Program Files
Write-Host "📂 Installing to $InstallDir..."
Copy-Item -Path (Join-Path $Temp "bin") -Destination $InstallDir -Recurse -Force

# Add install directory to system PATH (if not already present)
$CurrentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if (-not ($CurrentPath -split ";" | Where-Object { $_ -eq $InstallDir })) {
    $NewPath = $CurrentPath + ";" + $InstallDir
    [Environment]::SetEnvironmentVariable("PATH", $NewPath, "Machine")
    Write-Host "🔧 Added $InstallDir to system PATH"
}

# Update current session PATH so you don't need to restart shell
$env:Path = $NewPath + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

Write-Host "✅ containerd installed to $InstallDir and added to PATH."

# Verify installation
Write-Host "🔍 Verifying installation..."
containerd --version
```

### Option B: Using WSL-built binaries

If you chose Option B in Step 6 (WSL approach), containerd.exe is already included in the cross-compiled binaries and available in your PATH at `C:\buildkit-windows-bins\containerd.exe`.

Verify containerd is available:

```powershell
# Check containerd version
containerd --version
```

## Step 8: Clone BuildKit Repository

Clone your BuildKit repository:

```powershell
# Create directory structure
New-Item -ItemType Directory -Path "C:\github" -Force

# Clone BuildKit repository
git clone https://github.com/<your_github_account>/buildkit.git C:\github\buildkit

# Navigate to repository
cd C:\github\buildkit
```

## Step 9: Build BuildKit Binaries

You have two options depending on your previous choices:

### Option A: Build Natively in Windows

If you installed tools directly (Option A in Steps 6-7), build the binaries natively:

```powershell
# Navigate to BuildKit directory
cd C:\github\buildkit

# Create bin directory
New-Item -ItemType Directory -Path "bin" -Force

# Build buildctl client
Write-Host "🔨 Building buildctl..."
go build -o bin\buildctl.exe .\cmd\buildctl

# Build buildkitd daemon
Write-Host "🔨 Building buildkitd..."
go build -o bin\buildkitd.exe .\cmd\buildkitd

# Add BuildKit bin directory to user PATH
$BuildKitBinPath = "C:\github\buildkit\bin"
$CurrentUserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if (-not ($CurrentUserPath -split ";" | Where-Object { $_ -eq $BuildKitBinPath })) {
    [Environment]::SetEnvironmentVariable("PATH", $CurrentUserPath + ";" + $BuildKitBinPath, "User")
    $env:Path = $env:Path + ";" + $BuildKitBinPath
    Write-Host "✅ Added BuildKit binaries to PATH"
}

# Verify builds
Write-Host "🔍 Verifying BuildKit binaries..."
buildctl --help | Select-Object -First 3
buildkitd --help | Select-Object -First 3
```

### Option B: Use WSL Cross-Compiled Binaries

If you used the WSL approach (Option B in Steps 6-7), the buildctl.exe and buildkitd.exe binaries are already available in `C:\buildkit-windows-bins\` and added to your PATH.

Verify the binaries are working:

```powershell
# Verify builds
Write-Host "🔍 Verifying BuildKit binaries..."
buildctl --help | Select-Object -First 3
buildkitd --help | Select-Object -First 3
```

## Step 10: Verify Environment

Run a simple integration test to verify your environment is set up correctly:

```powershell
# Navigate to BuildKit directory
cd C:\github\buildkit

# Run a specific integration test
Write-Host "🧪 Running verification test..."
gotestsum --format=testname --packages "./client" -- -v -run "TestIntegration/.*TestFrontendMetadataReturn.*" -timeout=20m
```

If the test passes, your Windows BuildKit development environment is ready!

## Development Approaches Summary

This guide provides two approaches for setting up BuildKit Windows development:

### **Approach A: Native Windows Development**
- Install tools directly on Windows using Go and Chocolatey
- Build binaries natively using Windows Go toolchain
- **Pros**: Simpler setup, all tools native to Windows
- **Cons**: May encounter version compatibility issues (especially with registry)

### **Approach B: WSL-Assisted Development**
- Use WSL2 + Docker to cross-compile binaries (same as BuildKit CI)
- Install Docker Desktop for container support
- **Pros**: Identical to CI environment, no version compatibility issues, access to latest toolchain
- **Cons**: Requires WSL2 setup, slightly more complex

**Recommendation**: Use Approach B (WSL) if you encounter issues with registry or containerd versions, or if you want to match the exact CI environment.

## Environment Summary

After completing these steps, you'll have:

- ✅ Windows container features enabled
- ✅ Go development environment
- ✅ Git version control
- ✅ Visual Studio Code editor
- ✅ gotestsum test runner
- ✅ Docker registry v2.8.3
- ✅ containerd runtime
- ✅ BuildKit source code
- ✅ buildctl and buildkitd binaries

## Troubleshooting

### Registry Installation Issues
If `go install` fails for registry v2.8.3, build the Windows registry binary using the WSL cross-build (see Step 6, Option B):

1. Follow Step 6 Option B to install WSL and Docker Desktop and clone the repository inside WSL.
2. In your WSL Ubuntu session run:

```bash
# produce all Windows test binaries (including registry.exe)
docker buildx bake binaries-for-test --set="*.platform=windows/amd64"
# prepare a Windows-accessible folder and copy registry
mkdir -p /mnt/c/buildkit-windows-bins
cp ./bin/build/registry.exe /mnt/c/buildkit-windows-bins/
```

3. Back in Windows, add `C:\buildkit-windows-bins` to your PATH or copy `registry.exe` into a folder already on PATH.

Verify the registry binary with:

```powershell
registry --version
```

This approach matches the BuildKit CI and avoids compatibility problems with v3.x releases.

### PATH Not Updated

If commands aren't found after installation:
1. Close and reopen PowerShell
2. Or restart your session
3. Verify PATH with: `$env:PATH -split ';'`

### Container Feature Issues

If container features fail to enable:
1. Ensure you're running PowerShell as Administrator
2. Check Windows version compatibility
3. Restart after feature installation

## Next Steps

With your environment set up, you can:
- Run BuildKit integration tests
- Develop and test BuildKit features
- Debug BuildKit issues on Windows
- Contribute to BuildKit Windows support

For more information on BuildKit development, see the [main README](../README.md) and [development documentation](dev/).

## Windows Test Skips Analysis

This section provides a comprehensive analysis of BuildKit tests that are currently skipped on Windows, categorized by the underlying technical reasons. Understanding these categories helps prioritize which tests can be fixed versus those that should remain skipped due to platform limitations.

### Categories (with representative tests)

#### 1) POSIX ownership/mode bits (UID/GID, chmod/chown)

**Why skipped**: Windows doesn't use Unix UID/GID or the same chmod semantics; tests expect POSIX behavior. Some can be ported by validating SIDs/ACLs instead of UID/GID; others are Linux-only.

**Tests**:
- `testChmodNonOctal`
- `testCopyChown*` (ExistingDir, CreateDest, generic) ← comment in code even notes SIDs on Windows
- `testCopyChmod`, `testCopyInvalidChmod`, `testAddURLChmod`, `testAddInvalidChmod`
- `testUser`, `testUserAdditionalGids`

**Triage**: Partially fixable. Replace UID/GID assertions with SID/ACL checks; limit chmod expectations to what WCOW supports (or gate on exporter/FS type).

**Context**: BuildKit's `--chmod`/`--chown` flags are POSIX-centric; Windows support is incomplete/experimental.

#### 2) Special files & FS semantics (symlinks, sockets, tmpfs, read-only rootfs, /dev/shm)

**Why skipped**: WCOW lacks Unix domain sockets as regular files, `/dev/shm`, tmpfs for RUN-mounts, and symlink behavior differs (privileges, reparse points).

**Tests**:
- `testCopySocket`, `testRmSymlink`, `testSymlinkDestination`
- `testMountTmpfs`, `testMountTmpfsSize`
- `testReadonlyRootFS`, `testShmSize`

**Triage**: Mixed. Symlink tests might be adapted with Windows reparse-point semantics; tmpfs/`/dev/shm` are currently not supported → keep skipped until feature exists.

**Context**: RUN `--mount` types like tmpfs are Linux-specific today.

#### 3) Build secrets & SSH mounts

**Why skipped**: Secret mounts and SSH agent/socket semantics rely on Unix FD passing and sockets; WCOW plumbing is not parity yet.

**Tests**:
- `dockerfile_secrets_*` (SecretFileParams, SecretAsEnviron*, SecretRequiredWithoutValue)
- `dockerfile_ssh_*` (SSHSocketParams, SSHFileDescriptorsClosed)
- `client_test.go` (testSecretMounts, testSecretEnv)
- Outline tests that exercise secrets: `testOutlineSecrets`

**Triage**: Mostly blocked by platform support.

**Context**: Secrets/SSH are BuildKit features; Windows support is incomplete.

#### 4) Linux-only kernel features (ulimit, cgroups, sysfs, security modes)

**Why skipped**: WCOW lacks Linux ulimit, cgroupParent, sysfs and associated "security mode" behaviors.

**Tests**:
- `testUlimit`, `testCgroupParent`, `testSecurityMode*` (Sysfs, Errors, etc.)

**Triage**: Keep skipped. Linux-only by design.

**Context**: These features are tied to the Linux kernel and cgroups.

#### 5) Networking modes & low-level net features

**Why skipped**: Network mode/bridge/DNS/extra-hosts behaviors differ in WCOW and/or in BuildKit's Windows worker.

**Tests**:
- `testBridgeNetworkingDNSNoRootless`, `testNetworkMode`, `testExtraHosts`, `testRawSocketMount`

**Triage**: Some may be adaptable, but raw socket mount is Linux-only; bridge/DNS parity depends on container runtime on Windows.

#### 6) RUN-mount features (cache mounts, user, parallel)

**Why skipped**: RUN `--mount` (cache/tmpfs/ssh/secret) support is incomplete on WCOW; user mappings interact with POSIX ownership. Some called out as flaky on WS2025.

**Tests**:
- `testCacheMountUser`, `testCacheMountParallel` (commented "flaky on WS2025")
- Many Dockerfile tests that rely on `--mount` cache and modes

**Triage**: Blocked/Flaky. Wait for WCOW RUN `--mount` design/impl; investigate WS2025 flakiness.

#### 7) OCI/Docker image layout exporters & "FROM scratch"

**Why skipped**: Exporting to OCI layout and some multi-arch behaviors differ/are fragile on Windows; FROM scratch WCOW layers are special (no Windows base metadata; different layer format).

**Tests**:
- `testTarExporterMulti`, `testOCILayoutProvenance`, `testOCILayoutMultiname`
- `testPullScratch`, `testDockerfileScratchConfig`
- `testPlatformWithOSVersion` (explicit inline note says FROM scratch not supported on Windows)

**Triage**: Partially fixable. OCI layout bugs are being worked on; FROM scratch WCOW remains unsupported → keep skipped.

#### 8) Provenance / SBOM / attestation

**Why skipped**: Attestations and SBOM scanners may depend on tooling that's Linux-centric or not wired in WCOW exporters.

**Tests**:
- `dockerfile_provenance_*` (e.g., GitProvenanceAttestation, MultiPlatformProvenance, ProvenanceExportLocal*, CommandSourceMapping, DuplicateLayersProvenance)
- `testSBOMScannerImage`, `testSBOMScannerArgs`

**Triage**: Investigate per test. Some may pass if run with Linux builder only; Windows builds may not generate identical attestations.

#### 9) Multi-platform / base image platform logic

**Why skipped**: WCOW builds can't also execute Linux work or mix platforms in the same way; some tests require multi-arch workers.

**Tests**:
- `testExportMultiPlatform`, `testCacheMultiPlatformImportExport`, `testImageManifestCacheImportExport`, `testNamedMultiplatformInputContext`, `testPlatformArgsExplicit`, `testMaintainBaseOSVersion`, `testPlatformWithOSVersion`

**Triage**: Keep skipped for WCOW workers; enable when the test can target a Linux worker (or re-scope test to Windows platform selection semantics).

#### 10) Git-based ADD/contexts

**Why skipped**: Git ADD requires consistent filemode bits, symlinks, path separators, and SSH auth; these differ on Windows.

**Tests**:
- `dockerfile_addgit_*` (AddGit, AddGitChecksumCache, GitQueryString), `testDockerfileFromGit`

**Triage**: Likely fixable with guardrails. Ensure Git client, core.autocrlf/filemode settings; avoid assuming POSIX filemodes; use HTTPS creds instead of agent sockets on WCOW.

#### 11) Heredoc / shell semantics (RUN <<EOF, shebang)

**Why skipped**: Many heredoc tests assume `/bin/sh` semantics and Unix shebang handling; WCOW defaults to cmd/PowerShell with different quoting/newline rules.

**Tests**:
- `dockerfile_heredoc_*` (CopyHeredoc*, Run*Heredoc, HeredocIndent, HeredocVarSubstitution)

**Triage**: Mixed. Could pass if tests explicitly force `SHELL ["pwsh","-Command"]` variants; otherwise keep Linux-only.

#### 12) CDI / device tests

**Why skipped**: CDI (Common Device Interface) targets Linux runtime/device plugins.

**Tests**:
- `client_cdi_test.go` (testCDI* group), `dockerfile_rundevice_test.go`

**Triage**: Linux-only. Keep skipped on WCOW.

#### 13) Registry/cache import-export, compression (zstd), cloud caches

**Why skipped**: Some cache exporters/importers (zstd layers, registry/S3/AzBlob local/remote caches) rely on image/layer mechanics not uniformly supported for WCOW layers yet.

**Tests**:
- `testBuildExportZstd`, `testPullZstdImage`
- `testZstdLocalCache*`, `testZstdRegistryCache*`, `testBasicRegistryCache*`, `testMultipleRegistryCache*`, `testBasicS3Cache*`, `testBasicAzblobCache*`, `testCacheImportExport`, `testNoCache`

**Triage**: Investigate per exporter. Zstd and registry cache for WCOW often lag parity; some AzBlob/S3 cases are infra-dependent.

#### 14) Frontend ref/file APIs & source-map/targets

**Why skipped**: Tests exercise the gateway/frontend ref read/stat/eval & source-map plumbing; differences in path separators/newlines and platform-specific source mapping can cause failures.

**Tests**:
- `frontend_test.go` (testRefReadFile/Dir/StatFile/Evaluate)
- `errors_test.go` (testErrorsSourceMap), `dockerfile_targets_test.go`

**Triage**: Likely fixable. Normalize path separators (`` vs `/`), CRLF vs LF, stat info differences.

#### 15) Named contexts, timestamps, EPOCH reproducibility, exported history

**Why skipped**: These rely on consistent timestamp normalization, path separators, and tar creation; Windows time resolution and tar/ACL metadata differ.

**Tests**:
- `testNamedImageContext*`, `testNamedInputContext*`, `testNamedFilteredContext`
- `testNamedImageContextTimestamps`, `testWorkdirSourceDateEpochReproducible`, `testReproSourceDateEpoch`, `testExportedHistory*`

**Triage**: Often fixable. Use deterministic timestamping and platform-agnostic tar creation.

#### 16) CLI/buildctl + prune/diskusage

**Why skipped**: These tests assert outputs/paths or daemon behaviors with containerd exporter that differ on Windows (path quoting, drive letters, perms).

**Tests**:
- `cmd/buildctl/*` (testUsage, testPrune, testDiskUsage, testBuild*)

**Triage**: Likely fixable. Gate path assertions on `runtime.GOOS == "windows"`; normalize output.

#### 17) Performance / flakiness

**Why skipped**: Known flakes on WS2025 / perf instability.

**Tests**:
- `testCacheMountParallel` (comment says flaky on WS2025)
- `testLLBMountPerformance` (flaky on WS2025 and moby/moby)

**Triage**: Stabilize first. Add timeouts/backoffs; measure perf counters; consider quarantined lane.

### What to enable first (low-effort wins)

#### Path/timestamp normalization (Categories 14 & 15)
- Convert `/↔` in assertions; use filepath helpers; force LF for golden files; normalize mtime to EPOCH.

#### Git ADD tests (Category 10)
- Ensure git present; set `core.filemode=false`, `core.autocrlf=input`; prefer HTTPS creds; skip socket expectations.

#### CLI/buildctl output tests (Category 16)
- Normalize path quoting/drive letters.

#### Symlink tests (Category 2, subset)
- Use reparse-point APIs; require developer mode or symlink privilege; adapt assertions.

### Likely to stay skipped (for now)

#### Linux kernel features: ulimit, cgroups, sysfs, security modes (Category 4)

#### tmpfs, /dev/shm, raw socket mounts on WCOW (Categories 2 & 5) until feature work lands

#### CDI/device (Category 12)

#### FROM scratch for WCOW and some multi-arch mixes (Categories 7 & 9)

### Tracking map (how to tag PRs/Issues)

Use labels like:
- `windows:posix-perms` (Category 1)
- `windows:fs-special` (Category 2)
- `windows:secrets-ssh` (Category 3)
- `windows:linux-kernel-only` (Category 4)
- `windows:networking` (Category 5)
- `windows:run-mount` (Category 6)
- `windows:oci-layout/scratch` (Category 7)
- `windows:provenance-sbom` (Category 8)
- `windows:multi-platform` (Category 9)
- `windows:git-add` (Category 10)
- `windows:heredoc/shell` (Category 11)
- `windows:cdi-device` (Category 12)
- `windows:cache-exporters` (Category 13)
- `windows:frontend-ref/sourcemap` (Category 14)
- `windows:timestamps/repro` (Category 15)
- `windows:cli-output` (Category 16)
- `windows:flaky` (Category 17)

### 

1. **Windows support is still experimental in BuildKit**; not all features are implemented or parity with Linux.
   - [Docker Documentation](https://docs.docker.com/)
   - [Docker](https://docker.com/)
   - [Microsoft Tech Community](https://techcommunity.microsoft.com/)

2. **RUN-mount types like tmpfs are Linux-specific today** (blocking several mount/secret/ssh tests).
   - [GitHub](https://github.com/)

3. **OCI layout & exporters, provenance/SBOM have known cross-platform wrinkles**.
   - [Docker Documentation](https://docs.docker.com/)

This analysis provides a roadmap for systematically addressing Windows test compatibility issues in BuildKit, prioritizing fixes that provide the most value with the least effort while acknowledging platform-specific limitations that may require longer-term architectural changes.
