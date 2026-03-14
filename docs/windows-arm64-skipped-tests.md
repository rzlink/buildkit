# Windows ARM64 Skipped Tests — Status & Fix Plan

This document tracks all tests currently skipped on Windows ARM64 (`windows-11-arm`
partner runner) and outlines a plan to fix or permanently resolve each one.

**Last updated**: 2026-03-15 (CI runs 1–14)
**Total skipped**: 26 tests across 6 files
**Skip mechanism**: `integration.SkipOnPlatformArch(t, "windows", "arm64", "reason")`

---

## Summary by Category

| Category | Count | Root Cause | Fix Difficulty |
|----------|-------|-----------|----------------|
| Sandbox timeout | 19 | ARM64 runner ±15-20min perf variance | Medium — needs investigation |
| ACL Access Denied | 2 | nanoserver:ltsc2025-arm64 restricted dirs | Medium — COPY backend |
| Missing tools | 3 | No ARM64 `wintools` image (fc.exe, whoami.exe) | Easy — build image |
| Registry blob error | 1 | Local cache registry flake | Medium — investigate |
| buildkitd startup | 1 | Named pipe dial failure | Medium — investigate |

---

## Category 1: Sandbox Timeout (19 tests)

### Problem

The `windows-11-arm` partner runner (4 vCPU, 16GB RAM) has significant
performance variance between runs — the same test can take 15–20 minutes
more or less depending on the runner instance. The sandbox timeout is set
to 50 minutes (base 5min × 10× ARM64 multiplier), but heavy tests
intermittently exceed this.

These tests all pass on AMD64 and pass on ARM64 ~70-80% of the time.

### Affected Tests

| Test | File | First Failed |
|------|------|-------------|
| TestDefaultEnvWithArgs | dockerfile_test.go | run 4 |
| TestCopyUnicodePath | dockerfile_test.go | run 4 |
| TestMountRWCache | dockerfile_mount_test.go | run 5 |
| TestDockerfileFromHTTP | dockerfile_test.go | run 6 |
| TestLocalCustomSessionID | dockerfile_test.go | run 6 |
| TestCopyOverrideFiles | dockerfile_test.go | run 7 |
| TestFrontendDeduplicateSources | dockerfile_provenance_test.go | run 3 |
| TestOnBuildCleared | dockerfile_test.go | run 9 |
| TestImageManifestRegistryCacheImportExport | client_test.go | run 9 |
| TestSourcePolicyWithNamedContext | dockerfile_test.go | run 10 |
| TestMultiStageImplicitFrom | dockerfile_test.go | run 11 |
| TestNamedInputContext | dockerfile_test.go | run 11 |
| TestPlatformArgsImplicit | dockerfile_test.go | run 11 |
| TestEnvEmptyFormatting | dockerfile_test.go | run 12 |
| TestCopyThroughSymlinkContext | dockerfile_test.go | run 12 |
| TestMultiStageCaseInsensitive | dockerfile_test.go | run 12 |
| TestCopyWildcardCache | dockerfile_test.go | run 12 |
| TestTargetStageNameArg | dockerfile_test.go | run 12 |
| TestBasicInlineCacheImportExport | client_test.go | run 13 |

### Fix Options

1. **Increase sandbox timeout further** (e.g., 15× or 20× multiplier)
   - Pros: Simple change, one line in `sandbox.go`
   - Cons: Each shard runs longer; 120m Go test timeout may be hit more
     often; doesn't fix the root cause
   - Risk: The shard 1-12 hang pattern (see below) may worsen

2. **Reduce test matrix shards** — fewer tests per shard means less chance
   of hitting the timeout
   - Currently 12 shards for `./frontend/dockerfile`; could increase to 16-20
   - Tradeoff: more parallel jobs, more runner cost

3. **Profile slow operations** — identify what specifically is slow on ARM64
   - Suspect: `nanoserver:ltsc2025-arm64` image pull (263MB layer) + container
     start time + containerd snapshot operations
   - Action: Add timing instrumentation to sandbox setup/teardown
   - Would help identify if it's image pull, container start, or test logic

4. **Pre-pull base images** — add a setup step to pull nanoserver before tests
   - Could save 2-5 minutes per test if image pull is the bottleneck
   - Easy to test: add `ctr images pull` in the CI workflow before test step

5. **Conditional matrix** (long-term) — run smoke subset on PR, full on push
   - Run ~8 representative shards on PR (fast feedback)
   - Run full 21 shards on push/schedule (comprehensive coverage)

**Recommended approach**: Start with option 4 (pre-pull) + option 3 (profiling).
If that doesn't help enough, try option 2 (more shards). Option 1 is a last resort.

---

## Category 2: ACL Access Denied (2 tests)

### Problem

`nanoserver:ltsc2025-arm64` has restrictive ACLs on certain system directories
(e.g., `\Windows\System32\LogFiles\WMI\RtBackup`). The COPY `--parents` feature
traverses the filesystem tree and intermittently encounters "Access is denied"
when it hits these protected directories.

This does NOT happen on AMD64 with `nanoserver:ltsc2022` — the ARM64 image
(`ltsc2025-arm64`) has different/stricter default ACLs.

### Affected Tests

| Test | File | Details |
|------|------|---------|
| TestCopyRelativeParents | dockerfile_parents_test.go | Failed in runs 6, 7, 8 |
| TestCopyParentsMissingDirectory | dockerfile_parents_test.go | Preventive skip (same code path) |

### Fix Options

1. **Fix COPY --parents traversal** to handle Access Denied gracefully
   - Location: `snapshot/` or the copy backend code
   - The traversal should skip or handle restricted system directories
   - This is the correct fix — COPY --parents shouldn't fail on system dirs

2. **Build custom ARM64 nanoserver image** without restricted directories
   - Create `nanoserver:ltsc2025-arm64-clean` with relaxed ACLs
   - Workaround, not a real fix

3. **Report upstream** — this may be a Microsoft bug in the ltsc2025-arm64 image
   - Check if `nanoserver:ltsc2026` (when available) has the same issue
   - Compare ACLs between amd64 and arm64 images

**Recommended approach**: Option 1 — fix the COPY backend to handle restricted
directories. File an issue to track.

---

## Category 3: Missing Tools (3 tests)

### Problem

Some tests require executables (`fc.exe`, `whoami.exe`) that exist in the AMD64
`wintools/nanoserver:ltsc2022` image but have no ARM64 equivalent. The ARM64
test suite uses plain `nanoserver:ltsc2025-arm64` which lacks these tools.

### Affected Tests

| Test | File | Missing Tool | Skip Reason |
|------|------|-------------|-------------|
| TestDockerfileDirs | dockerfile_test.go | `fc.exe` | File comparison tool |
| TestRunCacheWithMounts | client_test.go | `whoami.exe` | User identity check |
| TestExportLocalForcePlatformSplit | client_test.go | N/A | OS version mismatch¹ |

¹ `TestExportLocalForcePlatformSplit` fails because the host OS version
(10.0.26200) doesn't match the container base image version (10.0.26100),
causing platform-split directory names to differ from expected values.

### Fix Options

1. **Build ARM64 wintools image** — `wintools/nanoserver:ltsc2025-arm64`
   - Cross-compile `fc.exe` / `whoami.exe` equivalents for ARM64
   - Or use PowerShell equivalents (`Compare-Object` for fc, `[System.Security.Principal.WindowsIdentity]::GetCurrent()` for whoami)
   - Publish to a registry and update `util_windows.go` mirror map

2. **Rewrite tests to not require external tools**
   - `TestDockerfileDirs`: Replace `fc` with a Go-based file comparison
   - `TestRunCacheWithMounts`: Replace `whoami` with environment variable check
   - This is more portable but requires changing test logic

3. **For TestExportLocalForcePlatformSplit** — update the test to accept
   ARM64 platform directory naming, or skip on version mismatch

**Recommended approach**: Option 1 for fc.exe/whoami.exe (build a minimal ARM64
wintools image). Option 3 for the platform-split test.

---

## Category 4: Registry Blob Write Error (1 test)

### Problem

`TestMultipleCacheExports` failed with an unexpected HTTP status from a PUT
request to the local test registry when writing a layer blob. This appears to
be a timing/race condition in the local registry under ARM64 performance
constraints.

### Affected Tests

| Test | File | Details |
|------|------|---------|
| TestMultipleCacheExports | client_test.go | Failed in run 12 (131s, not a timeout) |

### Fix Options

1. **Add retry logic** in the cache export path for transient registry errors
2. **Investigate registry logs** — the local test registry may be under-resourced
   on ARM64 runners
3. **May self-resolve** — only seen once in 13 runs; could be a one-off flake

**Recommended approach**: Monitor over the next few runs. If it recurs, investigate
the local test registry behavior on ARM64.

---

## Category 5: buildkitd Startup Failure (1 test)

### Problem

`TestLLBMountPerformance` failed because buildkitd didn't start — the named pipe
connection (`//./pipe/buildkitd-bktest_buildkitd...`) timed out. This is an
infrastructure flake where the buildkitd process fails to initialize on time.

### Affected Tests

| Test | File | Details |
|------|------|---------|
| TestLLBMountPerformance | client_test.go | Failed in run 10 |

### Fix Options

1. **Increase buildkitd startup timeout** for ARM64
   - The startup wait may be too short for ARM64's slower I/O
2. **Add startup retry** — if buildkitd fails to start, retry once
3. **May self-resolve** — only seen once in 13 runs

**Recommended approach**: Monitor. If it recurs, increase the startup timeout
in the sandbox setup code.

---

## Known Issue: Shard 1-12 Hang

### Problem

In CI runs 10 and 11, shard `./frontend/dockerfile#1-12` hung for 120+ minutes
until the Go test timeout killed it. The goroutine dump showed tests stuck in
`sync.Cond.Wait` for 50+ minutes — a test hit the sandbox timeout, then cleanup
got stuck, blocking all remaining tests.

This did NOT happen in runs 12 or 13, so it may be related to which specific
test lands in shard 1-12 during a slow runner instance.

### Impact

When this occurs, all tests in the shard are killed and reported as "unknown" —
typically 5-6 tests are lost. These tests themselves are NOT flaky; they're
victims of the hang.

### Fix Options

1. **Increase Go test timeout** from 120m to 180m
   - Gives more breathing room for the hang to resolve
   - But 3-hour jobs are expensive

2. **Add cleanup timeout** — if sandbox cleanup takes >10 minutes, force-kill
   - Location: `util/testutil/integration/sandbox.go` cleanup code
   - This would prevent one slow cleanup from killing the entire shard

3. **Identify the hanging test** — add logging to sandbox teardown to identify
   which test's cleanup is stuck

**Recommended approach**: Option 2 (cleanup timeout) + option 3 (logging).

---

## Infrastructure Files

| File | Purpose |
|------|---------|
| `util/testutil/integration/run.go` | `SkipOnPlatformArch()` helper function |
| `util/testutil/integration/sandbox.go` | 10× ARM64 timeout multiplier (line 141) |
| `util/testutil/integration/util_windows.go` | ARM64 image auto-detection + mirror map |
| `.github/workflows/test-os.yml` | CI workflow — `test-windows-arm64` job (lines 201-321) |

---

## Priority Order for Fixes

1. **Pre-pull base images** — quick win, may reduce timeout failures significantly
2. **Build ARM64 wintools image** — unblocks 3 tests, straightforward
3. **Fix COPY --parents ACL handling** — unblocks 2 tests, code fix needed
4. **Add sandbox cleanup timeout** — prevents shard 1-12 hang
5. **Profile ARM64 slowness** — data-driven approach to timeout issues
6. **Investigate registry blob error** — only if it recurs
