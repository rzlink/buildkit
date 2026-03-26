# Windows ARM64 CI — Status & Roadmap

This document tracks the Windows ARM64 CI test status, infrastructure decisions,
and roadmap for achieving full test parity with x64. Use this for planning and
manager discussions.

**Last updated**: 2026-03-27
**Branch**: `ci/windows-arm64-azure-testing`
**CI Workflow**: `.github/workflows/test-os.yml` → `test-windows-arm64` job

---

## Current State

### Infrastructure
- **Azure VMSS** (`arm64-runner-ss`) with scale-to-zero ephemeral runners
  - SKU: Standard_D4pds_v6 (4 vCPU, 16GB, Cobalt 100 ARM64) with automatic failover
  - Failover SKUs: D4ps_v6 (16GB) → D4pds_v5 (16GB) → D4plds_v6 (8GB)
  - Golden image: `bkarm64gallery/bk-arm64-runner/1.0.0` (Windows Server 2025 ARM64)
  - Region: eastus2, Resource group: `buildkit-arm64-runner-rg`
  - Runners labeled `windows-arm64-selfhosted`, register via `--ephemeral` flag
  - Re-registration loop: after each job completes, runner re-configures and picks up the next job
  - Cost: **$0 at idle** (scale to 0 between runs); ~$2/hr when running 12 instances
- **Automation**: `infra/vmss/run-ci.sh` — local CLI wrapper that scales up VMSS, dispatches
  workflow, polls completion, sends Teams notification, and scales back to 0.
  - SKU failover: `SkuNotAvailable` triggers immediate fallback (no retry); transient errors retry 3×
  - Signal trap guarantees scale-down on Ctrl+C/errors
  - Per-platform test result parsing from artifacts
  - Teams Adaptive Card notification with per-platform breakdown
- **Cron automation**:
  - Weekdays 15:45 UTC: `run-ci.sh --arm64-only` (daily CI)
  - Sundays 06:00 UTC: `patch-golden-image.sh` (weekly security patching)
- **Blob storage** (`bkarm64scripts`): `startup.ps1` (CSE entry point) + `runner-loop.ps1`
  (ephemeral re-registration loop). VMSS Custom Script Extension downloads and executes on boot.

### Test Results

| Metric | x64 (windows-2022) | ARM64 (self-hosted) |
|--------|---------------------|---------------------|
| Runner | GitHub-hosted, 8+ vCPU | Self-hosted, VMSS ephemeral, Cobalt 100 |
| Wall clock | **~17 min** | **~42 min** (with 12 runners) |
| Pass rate | 100% | **100%** (Run #23631236436) |
| Skipped tests | 0 | **0** |
| Parallel tests | No (sequential) | No (sequential) |
| Sandbox timeout | 5 min | 15 min (5 min × 3× ARM64 multiplier) |

### Skip Summary

All 3 previously-skipped ARM64 tests have been fixed (0 remaining):

| Test | Root Cause | Fix Applied |
|------|-----------|-------------|
| TestDockerfileDirs | `fc.exe` missing in nanoserver ARM64 | Use `findstr` instead of `fc /b` for content verification |
| TestRunCacheWithMounts | `whoami.exe` missing in nanoserver ARM64; `nanoserver:plus` maps to same image as `nanoserver:latest` on ARM64 | Create marker file via build step instead of checking pre-existing binary |
| TestExportLocalForcePlatformSplit | `platforms.Normalize()` adds `v8` variant on ARM64, causing directory name mismatch | Add `Normalize()` to expected platform string to match exporter behavior |

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

### Phase 1: Ephemeral Runner Support ✅ Done

**Deployed:** Azure VMSS with scale-to-zero ephemeral runners.

**Architecture:**
- **VMSS** (`arm64-runner-ss`): Scale Set with golden image, boots fresh instances per run
- **`--ephemeral` + re-registration loop**: Each runner exits after one job, then
  `runner-loop.ps1` re-configures and picks up the next job from the queue. This means
  N runners can handle M>N jobs without needing M instances.
- **Custom Script Extension**: On boot, `startup.ps1` downloads `runner-loop.ps1` from
  blob storage and starts it as a background process
- **`run-ci.sh` wrapper**: Automates the full cycle — scale up → wait for runners →
  dispatch → poll → scale down. Signal trap guarantees scale-down on Ctrl+C/errors.
- **Key Vault** (`bk-arm64-kv`): Stores GitHub PAT for runner registration tokens

**Key learnings during deployment:**
- PowerShell here-string encoding: Non-ASCII characters (em dashes, arrows) get garbled
  through the UTF-8 → BOM → CSE pipeline. Solution: keep all scripts ASCII-only and
  download from blob storage instead of embedding in here-strings.
- CSE caching: When blob content changes but URI stays the same, some instances use
  cached scripts. Fix: `az vmss extension set --force-update`.
- VNET dependency: VMSS references VNET by resource ID. If VNET is deleted, scale
  operations fail. Recreate with exact same name before scaling.

**Constraint:** Azure subscription is Microsoft-internal — `azure/login` from non-MS
GitHub org won't work. Automation runs locally via `az` CLI + `gh` CLI. Future option:
Azure Function with managed identity for fully automated webhook-driven scaling.

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

### Phase 3: Fix 3 Deterministic ARM64 Failures ✅ Done

**All 3 tests fixed** — zero skipped ARM64 tests. Fixes are in the `ci: add Windows
ARM64 test support` commit, validated in run #23631236436 (763 passed, 0 failed).

**3a: TestDockerfileDirs** — replaced `fc /b` with `findstr /M` for content verification.
`fc.exe` is not included in nanoserver (only available in Server Core / full Windows).
`findstr` is available in all Windows editions including nanoserver.

**3b: TestRunCacheWithMounts** — on ARM64, `nanoserver:plus` maps to the same image as
`nanoserver:latest` (no ARM64 wintools image exists), and neither contains `whoami.exe`.
Fix: create a marker file via an LLB build step on the mounted image, then check for
that marker instead of relying on pre-existing binary differences. Also switched to
forward slashes in paths (`C:/m1/marker`) for `llb.Shlex()` compatibility.

**3c: TestExportLocalForcePlatformSplit** — the local exporter runs platform through
`platforms.Normalize()` which adds the `v8` variant on ARM64 (`windows/arm64` →
`windows/arm64/v8`). The test was comparing against the un-normalized platform string.
Fix: add `Normalize()` to the expected value.

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
| ~~Self-hosted~~ | 10 Azure Cobalt 100 runners | 3 | 100% | ~40 min | 10 | Done |
| ~~Phase 1~~ | VMSS ephemeral runners + run-ci.sh | 3 | 100% | ~40 min | 9–12 (VMSS) | ✅ Done |
| Phase 2 | Enable t.Parallel() | 0 | 100% | ~20 min | 4-5 | Planned |
| ~~Phase 3~~ | Fix deterministic failures | 0 | 100% | ~42 min | 12 (VMSS) | ✅ Done |
| Phase 4 | Official GitHub ARM64 runner | 0 | 100% | ~17-20 min | 0 (GitHub-hosted) | Future |

---

## Infrastructure Files

| File | Purpose |
|------|---------|
| `.github/workflows/test-os.yml` | CI workflow — `test-windows-arm64` job, `arm64_only` + `arm64_test_filter` inputs |
| `infra/vmss/run-ci.sh` | Automated CI: sync → scale VMSS → dispatch → poll → parse results → Teams notify → scale down. SKU failover, `set -e` safe |
| `infra/vmss/patch-golden-image.sh` | Weekly golden image security patching: boot temp VM, Windows Update, update toolchain, sysprep, capture, cleanup |
| `infra/vmss/startup.ps1` | VMSS Custom Script Extension entry point. Downloads runner-loop.ps1 from blob, starts loop |
| `infra/vmss/runner-loop.ps1` | Ephemeral runner re-registration loop: config → run → repeat. Also in blob storage |
| `infra/vmss/deploy-vmss.sh` | Reference script for VMSS + Key Vault deployment |
| `infra/vmss/create-golden-image.sh` | Script to build golden VM image (Win Server 2025 ARM64 + toolchain) |
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
| #23447461738 | 2026-03-22 | **26/27 ✅** | First VMSS run (12 instances). 1 infra failure (runner transition). Runner loop deployed mid-run |
| #23453914389 | 2026-03-22 | **27/27 ✅** | Full VMSS validation via `run-ci.sh`. 9 runners handled all 21 ARM64 shards via re-registration |
| #23573978181 | 2026-03-26 | **27/27 ✅** | D4pds_v6 (16GB). All tests pass including cache import/export |
| #23623604620 | 2026-03-26 | 27/27, 3 failed | D4plds_v6 (8GB fallback). 2 test failures + 1 infra (Go setup). Memory-related |
| #23631236436 | 2026-03-27 | **27/27 ✅** | D4ps_v6 (16GB fallback). **0 skipped, 763 pass, 0 fail**. Full E2E with Teams notification |
| #23654934513 | 2026-03-27 | Build failed | Cron run. GitHub Actions infra issue ("Set up Docker Buildx"). Not code-related |
