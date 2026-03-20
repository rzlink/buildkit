# Enable Parallel Integration Test Execution on Windows

> Tracking document for enabling `t.Parallel()` in Windows integration tests.
> Filed as doc because issues are disabled on the fork.
> Upstream tracker: moby/buildkit#4485

## Background

Windows integration tests currently run **sequentially** (no `t.Parallel()`),
while Linux tests run in parallel. This was intentionally disabled in commit
`510428fef` by @profnandaa:

```go
// TODO(profnandaa): to revisit this to allow tests run
// in parallel on Windows in a stable way. Is flaky currently.
if !strings.HasSuffix(fn, "NoParallel") && runtime.GOOS != "windows" {
    t.Parallel()
}
```

## Why This Matters

1. **Sequential + fail-fast = catastrophic**: `require.True(t, ok)` on line 257
   of `run.go` calls `t.FailNow()` when a subtest fails. On Linux this is a
   no-op (parallel `t.Run` returns immediately with `ok=true`). On Windows
   (sequential), one 50-minute sandbox timeout kills all remaining tests in the
   shard — wasting 15-20 other tests.

2. **Slower CI**: Sequential execution means Windows shards take significantly
   longer than Linux equivalents.

3. **Blocks ARM64 progress**: The `windows-11-arm` partner runner (4 vCPU, 16GB
   RAM) already has performance variance. Sequential execution amplifies timeout
   issues.

## HCS Layer Contention Analysis

### Evidence: `ERROR_SHARING_VIOLATION (0x20)`

In CI run #23331967051, two tests failed with the same HCS layer activation error:

- **TestCacheImportExport** and **TestImageManifestCacheImportExport**
- Error: `hcsshim::ActivateLayer failed in Win32: The process cannot access the
  file because it is being used by another process. (0x20)`
- These tests were running **sequentially** (parallel is disabled), so even serial
  execution can trigger file contention

This error occurs when the HCS (Host Compute Service) tries to mount a container
layer filesystem but another process still holds a file handle on it.

### How Test Sandboxes Are Isolated

Each subtest gets its own sandbox with unique resources:

| Resource | Isolation | How |
|----------|-----------|-----|
| Temp root dir | ✅ Unique per sandbox | `os.MkdirTemp("", "bktest_containerd")` |
| containerd instance | ✅ Separate process | Unique `--root`, `--state` paths |
| buildkitd instance | ✅ Separate process | Unique `--root`, `--addr` |
| Named pipes | ✅ Unique names | Derived from temp dir basename |
| HCS layer operations | ❌ **Shared kernel** | All go through `vmcompute.dll` |

The test framework already avoids direct path collisions between sandboxes. The
contention occurs at the **Windows kernel/HCS level**, not from sandboxes sharing
the same directories.

### Why `ActivateLayer` Is Vulnerable

The vendored `hcsshim` library has different serialization approaches for layer
operations:

```
PrepareLayer  → has a process-local mutex (workaround for a known Windows bug)
ActivateLayer → NO retry, NO serialization
```

From `vendor/github.com/Microsoft/hcsshim/internal/wclayer/preparelayer.go`:
```go
// This lock is a temporary workaround for a Windows bug. Only allowing one
// call to prepareLayer at a time vastly reduces the chance of a timeout.
prepareLayerLock.Lock()
defer prepareLayerLock.Unlock()
```

But `ActivateLayer` (in `activatelayer.go`) is a direct syscall to
`vmcompute.ActivateLayer` with no such protection. Since each test sandbox runs
its own containerd process, even PrepareLayer's mutex provides no cross-process
serialization.

### Impact of Parallel Execution on Layer Contention

**Sequential (current):** Low but nonzero risk. One sandbox's cleanup
(`DeactivateLayer`, `RemoveAll`) can still race with the next sandbox's
`ActivateLayer` if kernel file handles haven't fully released. This is what we
saw in run #23331967051.

**Parallel (proposed):** **Significantly higher risk.** Multiple sandboxes would
concurrently call `ActivateLayer`/`DeactivateLayer`, creating more opportunities
for file handle contention at the HCS kernel level. The more concurrent HCS
operations, the more likely `ERROR_SHARING_VIOLATION`.

**Persistent runners amplify the problem:** Accumulated container layer state from
previous CI runs (orphaned snapshots, unreleased handles) increases the chance of
contention. Ephemeral runners would provide a clean baseline.

## Suspected Root Causes for Parallel Flakiness

1. **HCS layer contention**: `ActivateLayer`/`DeactivateLayer` compete for kernel
   file handles across sandboxes. No retry or serialization in hcsshim. Confirmed
   by `ERROR_SHARING_VIOLATION (0x20)` in sequential execution — parallel would
   make it worse.

2. **Named pipe contention**: BuildKit uses named pipes on Windows instead of
   Unix sockets. Parallel test sandboxes may have pipe cleanup/reuse issues.

3. **File locking**: Windows has stricter file locking semantics. Parallel tests
   cleaning up temp dirs, snapshots, and container state can hit sharing violation
   errors.

4. **Resource exhaustion**: Each sandbox starts a buildkitd process + containerd
   operations. On constrained runners (4 vCPU), parallel sandboxes may exhaust
   CPU/memory/handle limits.

## Current Mitigations

- `sandboxLimiter = semaphore.NewWeighted(int64(runtime.GOMAXPROCS(0)))` already
  limits concurrent sandboxes (commit `adb68c276`)
- Changed `require.True(t, ok)` to `assert.True` on Windows so one failure does
  not kill remaining tests in the shard

## Proposed Investigation Plan

### Phase A: Conservative Parallel (sandboxLimiter = 1)

Enable `t.Parallel()` on Windows but set `sandboxLimiter` to 1. This gives Go's
test scheduler flexibility for ordering but avoids actual concurrency. Benefits:
- Go can start the next test's setup while the previous test is tearing down
- No concurrent HCS layer operations
- Establishes baseline: does just enabling `t.Parallel()` cause any issues?

### Phase B: Limited Concurrency (sandboxLimiter = 2)

Increase to 2 concurrent sandboxes. Monitor for:
- `ERROR_SHARING_VIOLATION (0x20)` on `ActivateLayer`
- Named pipe errors
- Sandbox timeout increases (resource contention)
- Even `sandboxLimiter=2` would roughly halve wall-clock time

### Phase C: Platform-Specific Limiter

Set `sandboxLimiter` based on OS:
```go
limit := runtime.GOMAXPROCS(0)
if runtime.GOOS == "windows" {
    limit = 2 // conservative: HCS layer contention
}
sandboxLimiter = semaphore.NewWeighted(int64(limit))
```

### Phase D: Full Parallel

If Phases A-C are stable over multiple CI runs, consider increasing the Windows
limiter or removing the platform-specific cap.

### Prerequisites

- **Ephemeral runners** (roadmap Phase 1) should be in place first to eliminate
  accumulated state as a confounding variable
- Verify unique per-sandbox identifiers: named pipes, temp dirs, containerd
  namespaces
- Profile HCS overhead: measure container create/start/stop times under parallel
  vs sequential load

## Expected Impact

| Scenario | sandboxLimiter | Est. Speedup | HCS Contention Risk |
|----------|---------------|--------------|---------------------|
| Current (sequential) | N/A | 1× | Low (still possible) |
| Phase A (parallel, limit=1) | 1 | ~1.1× | Low |
| Phase B (parallel, limit=2) | 2 | ~1.5-2× | Medium |
| Full parallel (limit=GOMAXPROCS) | 4-8 | ~2-4× | High |

Conservative recommendation: **Start at Phase B (limit=2)** after ephemeral
runners are stable. This halves execution time while keeping HCS contention
manageable.

## References

- Original disable commit: `510428fef` ("test: enabling integration tests on windows")
- Sandbox limiter commit: `adb68c276` ("integration: add concurrent sandbox limit")
- Upstream tracker: moby/buildkit#4485 (Windows skipped tests)
- Location: `util/testutil/integration/run.go` lines 230-231
- HCS vendor code: `vendor/github.com/Microsoft/hcsshim/internal/wclayer/`
- CI evidence: Run #23331967051 — `ActivateLayer ERROR_SHARING_VIOLATION (0x20)`
- Roadmap: [`windows-arm64-ci-roadmap.md`](windows-arm64-ci-roadmap.md)
