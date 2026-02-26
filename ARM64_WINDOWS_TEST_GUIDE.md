# BuildKit ARM64 Windows Testing Guide

## Overview

This document provides a comprehensive breakdown of BuildKit integration tests and recommendations for validating ARM64 Windows builds.

## Test Environment Setup

Before running tests, set the Windows base image overrides for ARM64:

```powershell
$env:BUILDKIT_TEST_NANOSERVER_IMAGE = 'mcr.microsoft.com/windows/servercore:10.0.26100.32230-arm64'
$env:BUILDKIT_TEST_NANOSERVER_PLUS_IMAGE = 'mcr.microsoft.com/windows/servercore:10.0.26100.32230-arm64'
```

Verify your Go environment is ARM64:
```powershell
go env GOARCH  # Should show: arm64
```

---

## Test Categories

### ✅ Already Tested

- `TestFrontendMetadataReturn` - Gateway metadata handling (no container execution)

---

### 🟢 High Priority - Windows-Compatible Tests

#### Core Build Operations

1. `TestCacheExportCacheKeyLoop` - Cache key loop handling
2. `TestRelativeWorkDir` - Working directory resolution
3. `TestFileOpMkdirMkfile` - File operations (mkdir/mkfile)
4. `TestFileOpCopyRm` - File copy/remove operations
5. `TestFileOpCopyIncludeExclude` - File filtering
6. `TestFileOpCopyAlwaysReplaceExistingDestPaths` - Path replacement
7. `TestFileOpRmWildcard` - Wildcard file removal
8. `TestFileOpCopyChmodText` - Chmod operations (note: limited on Windows)

#### HTTP & Registry Operations

9. `TestBuildHTTPSource` - HTTP source fetching
10. `TestBuildHTTPSourceEtagScope` - ETag caching
11. `TestBuildHTTPSourceAuthHeaderSecret` - HTTP auth with secrets
12. `TestBuildHTTPSourceHostTokenSecret` - Token-based auth
13. `TestBuildHTTPSourceHeader` - Custom HTTP headers
14. `TestBuildPushAndValidate` - Image push validation

#### Export & Import

15. `TestBuildExportWithUncompressed` - Uncompressed exports
16. `TestBuildExportScratch` - Scratch image export
17. `TestOCIExporter` - OCI format export
18. `TestOCIExporterContentStore` - OCI content store
19. `TestBasicRegistryCacheImportExport` - Registry cache round-trip
20. `TestBasicLocalCacheImportExport` - Local cache round-trip
21. `TestBasicS3CacheImportExport` - S3 cache (if credentials available)
22. `TestBasicAzblobCacheImportExport` - Azure Blob cache

#### Container Execution Tests

23. `TestResolveAndHosts` - Hostname resolution
24. `TestUser` - User handling (limited on Windows)
25. `TestProxyEnv` - Proxy environment variables
26. `TestExtraHosts` - Extra hosts configuration
27. `TestHostnameLookup` - Hostname lookup in containers
28. `TestHostnameSpecifying` - Custom hostname setting

#### Secrets & Mounts

29. `TestSecretEnv` - Secret environment variables
30. `TestSecretMounts` - Secret file mounts
31. `TestCachedMounts` - Cache mount functionality
32. `TestSharedCacheMounts` - Shared cache mounts
33. `TestSharedCacheMountsNoScratch` - Cache without scratch
34. `TestLockedCacheMounts` - Lock contention on cache mounts
35. `TestDuplicateCacheMount` - Duplicate cache mount handling
36. `TestRunCacheWithMounts` - Run cache with mounts
37. `TestCacheMountNoCache` - Cache mount without caching

#### Multi-Build & Parallel

38. `TestParallelLocalBuilds` - Parallel build coordination
39. `TestMultipleExporters` - Multiple export targets
40. `TestMultipleCacheExports` - Multiple cache targets

#### Advanced Features

41. `TestFrontendUseSolveResults` - Solve result reuse
42. `TestPushByDigest` - Push by digest
43. `TestPullWithDigestCheck` - Pull with digest verification
44. `TestBasicInlineCacheImportExport` - Inline cache
45. `TestSourceMap` - Source map generation
46. `TestSourceMapFromRef` - Source map from reference
47. `TestValidateDigestOrigin` - Digest origin validation

#### Compression & Layer Handling

48. `TestBuildExportZstd` - Zstd compression export
49. `TestPullZstdImage` - Zstd image pull
50. `TestZstdLocalCacheExport` - Zstd local cache
51. `TestZstdLocalCacheImportExport` - Zstd cache round-trip
52. `TestZstdRegistryCacheImportExport` - Zstd registry cache
53. `TestUncompressedLocalCacheImportExport` - Uncompressed local cache
54. `TestUncompressedRegistryCacheImportExport` - Uncompressed registry cache
55. `TestPullWithLayerLimit` - Layer limit enforcement

#### Metadata & Annotations

56. `TestCallInfo` - Call info metadata
57. `TestExportAnnotations` - Export annotations
58. `TestExportAnnotationsMediaTypes` - Annotation media types
59. `TestExportAttestationsOCIArtifact` - OCI artifact attestations
60. `TestExportAttestationsImageManifest` - Image manifest attestations
61. `TestExportedImageLabels` - Exported image labels
62. `TestAttestationDefaultSubject` - Default attestation subject
63. `TestAttestationBundle` - Attestation bundle
64. `TestSBOMScan` - SBOM scanning
65. `TestSBOMScanSingleRef` - Single-ref SBOM
66. `TestSBOMSupplements` - SBOM supplements

#### Local Exports

67. `TestExportBusyboxLocal` - Local busybox export
68. `TestExportLocalNoPlatformSplit` - No platform splitting
69. `TestExportLocalNoPlatformSplitOverwrite` - Overwrite without split
70. `TestExportLocalForcePlatformSplit` - Force platform split
71. `TestSolverOptLocalDirsStillWorks` - Local dir solver options

#### Timestamps & Reproducibility

72. `TestSourceDateEpochLayerTimestamps` - SOURCE_DATE_EPOCH layer timestamps
73. `TestSourceDateEpochClamp` - Timestamp clamping
74. `TestSourceDateEpochReset` - Timestamp reset
75. `TestSourceDateEpochLocalExporter` - Local exporter timestamps
76. `TestSourceDateEpochTarExporter` - Tar exporter timestamps
77. `TestSourceDateEpochImageExporter` - Image exporter timestamps

---

### 🟡 Medium Priority - Partially Compatible

These tests work on Windows but have limitations or require specific setup:

78. `TestFileOpCopyUIDCache` - UID handling (Windows has different user model)
79. `TestShmSize` - Shared memory (limited on Windows containers)
80. `TestUlimit` - Ulimit (not fully supported on Windows)
81. `TestCgroupParent` - Cgroup parent (job objects on Windows)
82. `TestTarExporterWithSocket` - Socket handling (named pipes vs Unix sockets)
83. `TestTarExporterWithSocketCopy` - Socket copy operations
84. `TestTarExporterSymlink` - Symlink handling (Windows symlinks differ)
85. `TestCallDiskUsage` - Disk usage reporting

---

### ⚠️ Skipped on Windows

These tests are explicitly skipped on Windows in the code via `integration.SkipOnPlatform(t, "windows")`:

- `TestBuildMultiMount` - Complex mount scenarios
- `TestWhiteoutParentDir` - Whiteout handling (overlay-specific)
- `TestDuplicateWhiteouts` - Whiteout operations
- `TestLocalSymlinkEscape` - Symlink escape (security)
- `TestTmpfsMounts` - Tmpfs mounts (Linux-only)
- `TestSSHMount` - SSH agent mounting
- `TestRawSocketMount` - Raw socket mounting
- `TestStdinClosed` - Stdin handling edge case
- `TestBridgeNetworking` - Bridge networking (CNI-specific)
- `TestExporterTargetExists` - Target existence check
- `TestCacheExportIgnoreError` - Cache export error handling
- `TestCacheExportCacheDeletedContent` - Deleted content handling

---

### ❌ Requires Linux

Tests calling `requiresLinux(t)` are designed for Linux-only features and will not run on Windows:

- Security modes (seccomp, AppArmor)
- Host networking modes
- Special mount types (bind, tmpfs)
- UID/GID mapping
- Merge operations
- Overlayfs-specific operations
- Most Gateway tests in `build_test.go`

---

## Recommended Test Suites

### Quick Smoke Test (5-10 minutes)

Tests core functionality without extensive container execution:

```powershell
go test -v -count=1 -timeout=20m -run "TestIntegration/.*(TestFrontendMetadataReturn|TestFileOpMkdirMkfile|TestBuildHTTPSource|TestOCIExporter|TestBasicLocalCacheImportExport).*" ./client
```

### Core Functionality Test (~30 minutes)

Tests file operations, HTTP sources, caching, and exports:

```powershell
go test -v -count=1 -timeout=60m -run "TestIntegration/.*(TestFileOp|TestBuildHTTP|TestBasic|TestOCI|TestCache|TestExport|TestSecret|TestHostname).*" ./client
```

### Full Windows-Compatible Suite (2-3 hours)

Runs all tests and automatically skips Windows-incompatible ones:

```powershell
go test -v -count=1 -timeout=3h ./client
```

**Note:** The integration harness automatically skips Linux-only tests via `integration.SkipOnPlatform(t, "windows")`, so running the full suite is safe—it will skip unsupported tests automatically.

---

## Platform Detection

### Verifying ARM64 Image Usage

The integration test framework logs which images are being mirrored and (for multi-platform indexes) which platform manifest is selected. Look for these log lines in `go test -v` output:

```
mirroring mcr.microsoft.com/... -> localhost:PORT/library/nanoserver:latest (test platform=windows/arm64, mediatype=..., digest=...)
mirror resolve selected platform manifest: windows/arm64 os.version="..." digest=sha256:...
```

### Environment Variable Overrides

When you set image override environment variables, you'll see:

```
buildkit integration: BUILDKIT_TEST_NANOSERVER_IMAGE set, overriding nanoserver:latest ("old" -> "new")
```

---

## Prerequisites for Testing

### Required Binaries

Ensure these are on your PATH:

- `buildkitd.exe` (ARM64)
- `buildctl.exe` (ARM64)
- `containerd.exe` (ARM64)
- `gotestsum.exe` (optional, for better test output)

Verify binary architecture:
```powershell
where.exe buildkitd
where.exe buildctl
where.exe containerd
```

### Windows Container Stack

- Windows Containers feature enabled
- Containerd service running (ARM64 build)
- CNI networking configured (or accept "null network" for limited tests)

### Go Toolchain

- Go 1.25+ for Windows ARM64
- `GOARCH=arm64` confirmed via `go env GOARCH`

---

## Known Limitations

1. **Base Image Availability**: Not all Windows base image tags have ARM64 manifests. The default test images (`mcr.microsoft.com/windows/nanoserver:ltsc2022`) may not have ARM64 support or may be the wrong build for your Windows version.

2. **Third-Party Images**: Images like `docker.io/wintools/nanoserver:ltsc2022` (used for `nanoserver:plus`) almost certainly don't have ARM64 support.

3. **Windows Feature Parity**: Some tests have limited functionality on Windows (e.g., UID/GID, chmod, symlinks) due to platform differences.

4. **Networking**: CNI networking tests require additional setup and may not work out of the box on Windows ARM64.

---

## Troubleshooting

### "No matching manifest for windows/arm64"

The image tag doesn't have an ARM64 manifest. Set override environment variables to an ARM64-compatible image:

```powershell
$env:BUILDKIT_TEST_NANOSERVER_IMAGE = 'mcr.microsoft.com/windows/servercore:10.0.26100.32230-arm64'
```

### "Access Denied" / "Permission Denied"

Run PowerShell as Administrator when running tests that start containerd/buildkitd.

### Tests Hanging During Image Pull

Windows container base images can be very large (multiple GB). The first pull will take time. Monitor progress with:

```powershell
ctr.exe -n buildkit content ls | measure-object
```

### "buildkitd not found" / "containerd not found"

Add your binaries directory to PATH:

```powershell
$env:PATH = 'C:\buildkit-windows-bins;' + $env:PATH
```

---

## Contributing

If you find additional tests that work or don't work on ARM64 Windows, please update this guide or report findings to the BuildKit project.

When reporting issues, include:
- Windows version and build number
- `go env` output
- Binary architecture (`buildkitd.exe` properties)
- Full test output with `-v` flag
