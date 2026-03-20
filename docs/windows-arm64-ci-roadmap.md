# Windows ARM64 CI — Status & Roadmap

This document tracks the Windows ARM64 CI test status, infrastructure decisions,
and roadmap for achieving full test parity with x64. Use this for planning and
manager discussions.

**Last updated**: 2026-03-20
**Branch**: `ci/windows-arm64-azure-testing`
**CI Workflow**: `.github/workflows/test-os.yml` → `test-windows-arm64` job

---

## Current State

### Infrastructure
- **10 self-hosted Azure Cobalt 100 ARM64 runners** (Dpdsv6-series, NVMe storage)
- Runners: 1× D8pds_v6 (8 vCPU, 32GB) + 9× D4pds_v6 (4 vCPU, 16GB)
- Region: eastus2, Resource group: `buildkit-arm64-runner-rg`
- Runners connect outbound to GitHub; labeled `windows-arm64-selfhosted`
- Cost: ~$2.11/hr total (~$50/day if running 24/7)

### Test Results

| Metric | x64 (windows-2022) | ARM64 (self-hosted) |
|--------|---------------------|---------------------|
| Runner | GitHub-hosted, 8+ vCPU | Self-hosted, 10 VMs, Cobalt 100 |
| Wall clock | **~17 min** | **~40 min** (with 10 runners) |
| Pass rate | 100% | **100%** (Run #23330129616) |
| Skipped tests | 0 | **3** (deterministic ARM64 issues) |
| Parallel tests | No (sequential) | No (sequential) |
| Sandbox timeout | 5 min | 15 min (5 min × 3× ARM64 multiplier) |

### Skip Summary (3 remaining)

| Test | Category | Root Cause | Fix Path |
|------|----------|-----------|----------|
| TestDockerfileDirs | Missing tool | `nanoserver:plus` ARM64 substitute lacks `fc.exe` | Build ARM64 wintools image |
| TestRunCacheWithMounts | Missing tool | `nanoserver:plus` ARM64 substitute lacks `whoami.exe` | Build ARM64 wintools image |
| TestExportLocalForcePlatformSplit | OS version | Host/container OS version mismatch in platform-split directory naming | Test fix |

### What was resolved

- **13 flaky tests unskipped**: Previously skipped for "flaky sandbox timeout on partner
  runner". Validated 100% pass rate on self-hosted runners. The flakiness was caused by
  the GitHub partner runner's poor I/O performance (14GB SSD), not actual ARM64 bugs.
  NVMe storage on the Cobalt 100 VMs eliminated all I/O timeout issues.

- **2 ACL tests unskipped**: TestCopyRelativeParents and TestCopyParentsMissingDirectory
  were initially skipped for "Access is denied" errors on `nanoserver:ltsc2025-arm64`
  system directories. Experiment (run #23331467831) confirmed these **pass consistently
  on self-hosted runners** — the failure was specific to the partner runner environment,
  likely due to different container isolation settings or a different nanoserver build.

### Known Flaky Failure (not skipped)

- **TestCacheImportExport / TestImageManifestCacheImportExport** — intermittent
  `hcsshim::ActivateLayer failed: ERROR_SHARING_VIOLATION (0x20)`. Windows container
  layer file locking race condition during mount. Not ARM64-specific; seen once in run
  #23331967051 on runner `bk-arm64-run-07`. Likely caused by accumulated state on
  persistent runners — supports the case for ephemeral runners (Phase 1).
  See also: [`windows-parallel-tests.md`](windows-parallel-tests.md) for HCS contention
  analysis.

---

## Roadmap

### Phase 1: Ephemeral Runner Support

**Goal:** Clean test environments — destroy/re-provision VM after each job run (like GitHub-hosted runners).

**Why:** Current runners are persistent. State accumulates between jobs (cached container
images, temp files, registry entries). This could cause subtle test pollution. GitHub-hosted
and partner runners destroy the VM after each job for isolation.

**Options (all work with current MS-internal Azure subscription unless noted):**

| Option | Approach | Azure Sub | Complexity | Notes |
|--------|----------|-----------|------------|-------|
| A | **Azure Automation / Logic Apps** — event-driven: watch runner completion, deallocate VM, re-provision from golden image | MS-internal ✅ | Medium | Native Azure solution, no external dependencies |
| B | **VM Scale Sets + golden image** — auto-scaling pool with `--ephemeral` runners | MS-internal ✅ | Medium | Best for scaling up/down with demand |
| C | **GitHub Actions workflow job** — pre/post jobs call Azure API to start/stop VMs via Azure SP + OIDC | Non-MS only ❌ | Low | Simplest code, but MS-internal sub can't expose SP to GitHub Actions |
| D | **Cron script on management VM** — polling script monitors runner state, restarts after each job | MS-internal ✅ | Low | Simplest, but fragile; single point of failure |

**Runner `--ephemeral` flag:** Register runner with `./config.cmd --ephemeral` so it
automatically exits after completing one job. Combined with automation above, the workflow becomes:
1. Job queued → automation starts a fresh VM from golden image
2. Runner registers, picks up job, executes
3. Runner exits → automation deallocates VM
4. Next job → repeat

**Golden image contents:** Windows Server 2025 ARM64, Containers feature enabled, HCS service
running, Developer Mode enabled, Git, Go, Node.js, Python, GitHub Actions runner agent.

### Phase 2: Enable t.Parallel() on Windows

**Goal:** Run test subtests in parallel within each shard to reduce total execution time
and VM count.

**Why:** Currently `t.Parallel()` is disabled on Windows for both x64 AND ARM64
(`util/testutil/integration/run.go:229-232`, disabled by profnandaa in July 2024).
Each shard runs subtests sequentially. Enabling parallelism could halve execution time
and allow reducing from 10 VMs to 4-5.

**Investigation needed:**
1. Why was `t.Parallel()` disabled? Named pipe contention, HCS container overhead
   under parallel load, and Windows file locking/sharing violations during cleanup.
   See [`windows-parallel-tests.md`](windows-parallel-tests.md) for detailed HCS
   contention analysis.
2. Which tests share state? (container images, network ports, temp directories)
3. Can isolation be added? (unique temp dirs, dynamic port allocation, per-test containerd)

**Approach:**
1. Start with `GOMAXPROCS=2` to limit concurrency — minimal change
2. Monitor for flaky failures over several CI runs
3. Increase parallelism gradually as stability is confirmed
4. Reduce VM count once parallel execution is stable

**Expected impact:** ~2× speedup, VM count reduction from 10 to 4-5 (cost savings ~50%)

### Phase 3: Fix 3 Deterministic ARM64 Failures

**Goal:** Zero skipped ARM64 tests.

**3a: Build ARM64 wintools/nanoserver image** (fixes TestDockerfileDirs, TestRunCacheWithMounts)
- On x64, `nanoserver:plus` → `docker.io/wintools/nanoserver:ltsc2022` (custom image with fc.exe, etc.)
- On ARM64, no wintools ARM64 build exists → falls back to plain `nanoserver:ltsc2025-arm64`
- Plain nanoserver is minimal and lacks fc.exe, whoami.exe
- **Host VM has both tools** at `C:\Windows\System32` — the issue is only inside containers
- Upstream PR: https://github.com/microsoft/windows-container-tools/pull/178
- Action: Build ARM64 variant, push to `wintools/nanoserver:ltsc2025-arm64`, update image map

**3b: Fix OS version mismatch** (fixes TestExportLocalForcePlatformSplit)
- Test exports with `platform-split: true`, creating directories named by OS version
- Host is Windows 26100 (ltsc2025), container image has its own version string
- Directory naming expectation doesn't account for ARM64 version differences
- Likely a test fix to accept the ARM64 platform string

### Phase 4: Official GitHub ARM64 Runner Support

**Goal:** Eliminate need for self-hosted runners by getting first-party GitHub ARM64 support.

**Current state of GitHub Windows ARM64 runners:**
- **Partner runner** (`windows-11-arm`) exists but has significant issues:
  - Poor I/O performance (caused our 13 flaky test timeouts)
  - Bash is x86_64 binary under WoW64 ARM64 emulation → intermittent zero-output bug
    (see [partner-runner-images#169](https://github.com/actions/partner-runner-images/issues/169))
  - Images maintained in `actions/partner-runner-images`, separate from main `actions/runner-images`
- **No first-party** Windows ARM64 runner in `actions/runner-images`

**Why we're well-positioned to drive this:**
1. **Windows Container core team** — we own the container runtime that BuildKit tests exercise
2. **BuildKit is high-profile OSS** — moby/buildkit is foundational to Docker/containerd ecosystem
3. **Concrete CI data** — 35+ CI runs proving ARM64 works with proper infrastructure
4. **Documented partner runner bugs** — #169 affects all Windows ARM64 users, not just us
5. **Microsoft + GitHub partnership** — Azure Cobalt is the ARM64 hardware platform

**Recommended engagement path:**
1. **File issue on `actions/runner-images`** requesting first-party Windows ARM64 runner
   - Include our CI pass rate data, performance comparisons, partner runner limitations
   - Reference partner-runner-images#169 (bash WoW64 reliability bug)
2. **Internal engagement** (Microsoft ↔ GitHub relationship)
   - Connect with GitHub Actions team through existing Microsoft channels
   - Propose contributing the runner image definition — we know exactly what's needed
3. **Offer to be a design partner** / early adopter for first-party Windows ARM64 runner
4. **Contribute fixes** to partner-runner-images for immediate bash/I/O issues

---

## Summary Timeline

| Phase | Action | Skipped | Pass Rate | Wall Clock | VMs | Status |
|-------|--------|---------|-----------|-----------|-----|--------|
| ~~Baseline~~ | Partner runner, 18 skipped | 18 | ~87% | ~47 min | 1 (partner) | Done |
| ~~Self-hosted~~ | 10 Azure Cobalt 100 runners | 3 | 100% | ~40 min | 10 | ✅ Done |
| Phase 1 | Ephemeral runners | 3 | 100% | ~40 min | 10 | Planned |
| Phase 2 | Enable t.Parallel() | 3 | 100% | ~20 min | 4-5 | Planned |
| Phase 3 | Fix deterministic failures | 0 | 100% | ~20 min | 4-5 | Planned |
| Phase 4 | Official GitHub ARM64 runner | 0 | 100% | ~17-20 min | 0 (GitHub-hosted) | Future |

---

## Infrastructure Files

| File | Purpose |
|------|---------|
| `.github/workflows/test-os.yml` | CI workflow — `test-windows-arm64` job, `arm64_only` + `arm64_test_filter` inputs |
| `util/testutil/integration/run.go` | `SkipOnPlatformArch()` helper, `t.Parallel()` disabled on Windows (line 229) |
| `util/testutil/integration/sandbox.go` | ARM64 timeout multiplier 3× (line 141) |
| `util/testutil/integration/util_windows.go` | ARM64 image auto-detection, nanoserver:plus → nanoserver:ltsc2025-arm64 fallback |
| `docs/self-hosted-arm64-runner-setup.md` | Complete Azure runner provisioning guide |
| `docs/windows-parallel-tests.md` | Parallel test execution analysis |

## CI Run History

| Run | Date | Result | Notes |
|-----|------|--------|-------|
| 1–23 | 2026-03-14/17 | Various | Infrastructure setup, iterative skip identification |
| 24–30 (#369-374) | 2026-03-17/18 | 17-21/22 | Unskip experiment: confirmed 13 flaky, 5 deterministic |
| 31–35 | 2026-03-18 | — | Re-skipped 13, reduced timeout to 3×/60m |
| #381 | 2026-03-19 | ❌ All failed | First self-hosted run — bash PATH, Containers not enabled |
| #384 | 2026-03-19 | 21/22 ✅ | First successful self-hosted — 1 symlink failure |
| #387 | 2026-03-19 | **22/22 ✅** | 10-runner fleet: first 100% pass, ~55 min wall clock |
| #23329372052 | 2026-03-20 | **24/24 ✅** | Filtered run: all 13 unskipped tests pass on self-hosted |
| #23330129616 | 2026-03-20 | **24/24 ✅** | Full suite after squash+rebase, 5 deterministic skips |
| #23331467831 | 2026-03-20 | **21/24 ❌** | Experiment: unskipped 5 deterministic tests (filtered). 2 passed (ACL), 3 failed (fc.exe, whoami.exe, OS version) |
| #23331967051 | 2026-03-20 | **23/24 ❌** | Full suite, 3 skips. 1 flaky failure: hcsshim ActivateLayer ERROR_SHARING_VIOLATION (0x20) |
