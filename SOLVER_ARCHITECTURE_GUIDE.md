# BuildKit Solver Architecture Deep Dive

This guide explains how the BuildKit solver works - how build graphs are constructed, how caching works, and how operations are scheduled and executed.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Core Components](#core-components)
- [Graph Building Process](#graph-building-process)
- [Cache System](#cache-system)
- [Operation Scheduling](#operation-scheduling)
- [Execution Flow](#execution-flow)
- [Key Data Structures](#key-data-structures)

---

## Architecture Overview

The BuildKit solver is responsible for:

1. **Resolving dependencies** between build operations
2. **Managing cache** to avoid redundant work
3. **Scheduling execution** of operations
4. **Coordinating parallel work** across multiple workers

### High-Level Flow

```text
Frontend (Dockerfile) → LLB Graph → Solver → Scheduler → Worker → Result
                          ↓
                      Cache Manager
                          ↓
                    Cache Storage
```

### Key Insight: The Solver is Lazy

The solver doesn't execute operations immediately. Instead, it:

- Builds a **dependency graph** of operations (edges and vertices)
- Uses **cache keys** to determine what needs execution
- Only executes operations when **results are actually needed**
- Merges identical operations to avoid duplication

---

## Core Components

### 1. Solver (`solver/llbsolver/solver.go`)

The main entry point that coordinates the entire solve process.

**Key Responsibilities:**

- Accepts solve requests from clients
- Creates jobs to track progress
- Coordinates cache resolution
- Manages exporters (for outputting results)
- Records build history and provenance

**Main Method: `Solve()`**

```go
func (s *Solver) Solve(ctx context.Context, id string, sessionID string, 
    req frontend.SolveRequest, exp ExporterRequest, ...) (*client.SolveResponse, error)
```

**What it does:**

1. Creates a new job
2. Validates entitlements and source policies
3. Resolves the frontend (Dockerfile parser, etc.)
4. Builds the LLB graph through the bridge
5. Waits for all results to complete
6. Runs exporters to output the build
7. Exports cache for future builds
8. Records build history

### 2. Job (`solver/jobs.go`)

Represents a single build job with tracking and state management.

**Responsibilities:**

- Progress tracking
- Session management
- Status reporting
- Value storage (entitlements, policies, etc.)

**Key Methods:**

```go
func (s *Solver) NewJob(id string) (*Job, error)
func (j *Job) Status(ctx context.Context, ch chan *client.SolveStatus) error
```

### 3. Edge (`solver/edge.go`)

Represents a **single operation** in the build graph with its dependencies.

**Key Concept:** An "edge" connects a vertex (operation definition) to its execution state.

**Structure:**

```go
type edge struct {
    edge Edge                    // The operation definition
    op   activeOp               // The executable operation
    
    edgeState                   // Current state (initial, cache-fast, cache-slow, complete)
    deps        []*dep          // Dependencies (inputs)
    depRequests map[pipeReceiver]*dep
    
    cacheMapReq    pipeReceiver // Request for cache key computation
    execReq        pipeReceiver // Request for execution
    
    cacheRecords   map[string]*CacheRecord  // Available cache matches
    result         *SharedCachedResult      // Final result
}
```

**Edge States (Lifecycle):**

```text
Initial → Cache-Fast → Cache-Slow → Complete
   ↓          ↓           ↓            ↓
 [Deps]   [Check     [Compute     [Execute
         Static     Content-      or Use
         Cache]     Based Cache]  Cache]
```

**State Transitions:**

1. **Initial**: Edge just created, dependencies not resolved
2. **Cache-Fast**: Dependencies have cache keys, checking definition-based cache
3. **Cache-Slow**: Computing content-based cache keys (slow cache)
4. **Complete**: Execution finished or cache hit found

### 4. Scheduler (`solver/scheduler.go`)

Manages concurrent execution of edges using a **reactive scheduling model**.

**Key Insight:** The scheduler uses a **push-based** model where edges signal when they need processing.

**Architecture:**

```text
Scheduler Loop
    ↓
Wait for Signal
    ↓
Dispatch Edge
    ↓
Edge.unpark()
    ↓
Process Incoming Requests
    ↓
Update State
    ↓
Create New Outgoing Requests
    ↓
Signal Dependent Edges
    ↓
(Back to Wait)
```

**Key Methods:**

```go
// Main loop that processes edge events
func (s *scheduler) loop()

// Schedules an edge for processing
func (s *scheduler) signal(e *edge)

// Processes an edge (calls edge.unpark)
func (s *scheduler) dispatch(e *edge)

// Builds an edge (external entry point)
func (s *scheduler) build(ctx context.Context, edge Edge) (CachedResult, error)
```

**How Scheduling Works:**

1. **Signal**: An edge signals it needs processing (via `signal()`)
2. **Queue**: Edge added to wait queue (FIFO)
3. **Dispatch**: Scheduler calls `dispatch()` on edge
4. **Unpark**: Edge processes requests in `unpark()`
5. **Dependencies**: Edge creates requests for dependencies
6. **Callbacks**: When requests complete, they signal the edge again
7. **Repeat**: Process continues until edge completes

**Concurrency Model:**

- Scheduler runs in a **single goroutine** (the loop)
- Edges are processed **sequentially** by scheduler
- Actual work (ops) run in **separate goroutines**
- **Pipes** communicate between edges asynchronously

### 5. Cache Manager (`solver/cachemanager.go`)

Manages cache keys and records, determining which operations can be skipped.

**Two-Level Cache System:**

```text
Cache Manager
    ├── Cache Key Storage (metadata)
    │   ├── Cache Keys (operation + dependencies)
    │   ├── Links (relationships)
    │   └── Results (IDs)
    │
    └── Cache Result Storage (actual data)
        └── Results (filesystem snapshots, etc.)
```

**Key Methods:**

```go
// Query cache for matching keys based on dependencies
func (c *cacheManager) Query(deps []CacheKeyWithSelector, input Index, 
    dgst digest.Digest, output Index) ([]*CacheKey, error)

// Get cache records for a cache key
func (c *cacheManager) Records(ctx context.Context, ck *CacheKey) ([]*CacheRecord, error)

// Load actual result from cache
func (c *cacheManager) Load(ctx context.Context, rec *CacheRecord) (Result, error)
```

---

## Graph Building Process

### Step-by-Step: How a Build Graph is Created

#### 1. Frontend Parsing

```go
// Frontend (e.g., Dockerfile parser) converts Dockerfile to LLB
Frontend.Solve(ctx, llbBridge, opts) → frontend.Result
```

**Example Dockerfile:**

```dockerfile
FROM alpine:latest
RUN echo "hello" > /file.txt
RUN cat /file.txt
```

**Becomes LLB Graph:**

```text
Vertex 1: Source(alpine:latest)
    ↓
Vertex 2: Exec(echo "hello" > /file.txt)
    ↓ (depends on Vertex 1)
Vertex 3: Exec(cat /file.txt)
    ↓ (depends on Vertex 2)
```

#### 2. LLB Bridge Request

```go
// llbBridge.Solve() is called by frontend
func (s *llbBridge) Solve(ctx context.Context, req frontend.SolveRequest, 
    sid string) (*frontend.Result, error)
```

**What happens:**

1. Converts `frontend.SolveRequest` to solver request
2. Calls worker's `ResolveOp()` for each vertex
3. Worker creates actual `Op` implementations (ExecOp, SourceOp, etc.)

#### 3. Edge Creation

For each vertex in LLB:

```go
// Scheduler creates edge for vertex
edge := newEdge(Edge{Vertex: v, Index: idx}, op, index)
```

**Edge connects:**

- **Vertex**: Definition (what to do)
- **Op**: Implementation (how to do it)
- **Dependencies**: Input edges

#### 4. Dependency Resolution

```go
// Edge requests its dependencies
for i, dep := range vertex.Inputs {
    depEdge := getEdge(dep)
    pipe := scheduler.newPipe(depEdge, currentEdge, request)
}
```

**Dependency Types:**

- **Build dependencies**: Previous build steps
- **Source dependencies**: Base images, git repos
- **Mount dependencies**: Cache mounts, bind mounts

#### 5. Graph Structure

**Resulting Graph:**

```text
       ┌─────────────┐
       │ Source Op   │
       │ (alpine)    │
       └──────┬──────┘
              │ depends on
       ┌──────▼──────┐
       │  Exec Op    │
       │  (echo)     │
       └──────┬──────┘
              │ depends on
       ┌──────▼──────┐
       │  Exec Op    │
       │  (cat)      │
       └─────────────┘
```

---

## Cache System

### Cache Architecture

BuildKit uses a **content-addressable** cache system with two cache strategies:

#### 1. Definition-Based Cache (Fast Cache)

**Based on:** Operation definition + dependency cache keys

**Cache Key Composition:**

```text
CacheKey = Hash(
    OperationDigest,      // e.g., "RUN echo hello"
    DependencyCacheKeys   // Cache keys of inputs
)
```

**Example:**

```text
Vertex: RUN echo "hello" > /file.txt
Depends on: alpine:latest (cache key: abc123)

Fast Cache Key = Hash(
    "exec echo hello", 
    "abc123"
)
```

**When to use:**

- Operation definition hasn't changed
- Dependencies have known cache keys
- Very fast to compute

#### 2. Content-Based Cache (Slow Cache)

**Based on:** Actual content of inputs

**When to use:**

- Need to verify content hasn't changed
- Definition-based cache miss
- For operations like `COPY` that depend on file content

**Slow Cache Key Computation:**

```go
type ResultBasedCacheFunc func(ctx context.Context, res Result, 
    g session.Group) (digest.Digest, error)
```

**Example for COPY:**

```text
COPY . /app

Slow Cache = Hash(
    ActualFileContents  // Read and hash all files
)
```

### Cache Lookup Process

**Step-by-step:**

```text
1. Edge State: Initial
   └→ Request dependencies

2. Dependencies Complete → Cache-Fast
   └→ Query cache with dependency keys
   └→ Check definition-based cache
   
3. If no match → Cache-Slow
   └→ Compute content-based cache key
   └→ Query cache with slow key
   
4. If cache hit found
   └→ Load result from cache
   └→ Complete (skip execution)
   
5. If no cache hit
   └→ Execute operation
   └→ Save result to cache
   └→ Complete
```

**Code Flow:**

```go
// In edge.unpark()

// 1. Check if we can query cache
if e.cacheMap != nil && !e.noCacheMatchPossible {
    // 2. Query cache with dependency keys
    keys := e.op.Cache().Query(depKeys, ...)
    
    // 3. Load cache records
    records := e.op.Cache().Records(ctx, key)
    
    // 4. If found, load result
    if len(records) > 0 {
        result := e.op.Cache().Load(ctx, records[0])
        e.result = result
        e.state = edgeStatusComplete
        return
    }
}

// 5. No cache hit - need to execute
if desiredState == edgeStatusComplete {
    e.execIfPossible(f)
}
```

### Cache Storage

**Storage Backends:**

1. **In-Memory** (`solver/memorycachestorage.go`)
   - Fast, for testing
   - Lost on restart

2. **BoltDB** (`solver/bboltcachestorage/`)
   - Persistent
   - Default for buildkitd

**Storage Structure:**

```text
Cache Key Storage (BoltDB)
├── Keys
│   ├── key-abc123
│   │   ├── Results: [result-1, result-2]
│   │   └── Links: {dep-key-xyz → result-1}
│   └── key-def456
│       └── Results: [result-3]
│
Cache Result Storage (Containerd)
└── Results (snapshots)
    ├── result-1 → snapshot-sha256:...
    ├── result-2 → snapshot-sha256:...
    └── result-3 → snapshot-sha256:...
```

### Cache Invalidation

**When cache is invalidated:**

1. **Dependency changed**: If input changed, downstream invalidated
2. **Definition changed**: Different command = different cache key
3. **External change**: File content changed (for COPY)
4. **Manual**: `--no-cache` flag

**Cache Key Dependencies:**

```text
Key C depends on Key B depends on Key A

If A changes:
  → B is invalidated
  → C is invalidated

Cache is TRANSITIVE!
```

---

## Operation Scheduling

### Scheduling Model: Reactive Push-Based

Unlike traditional schedulers that pull work from a queue, BuildKit uses a **reactive** model where edges push state changes.

### Pipe System

**Key Abstraction:** Edges communicate via **pipes**.

```go
type Pipe[Req, Resp] struct {
    Sender   pipeSender      // Sends requests
    Receiver pipeReceiver    // Receives responses
}
```

**Pipe Types:**

1. **Input Pipe**: Request from dependent edge

   ```text
   Edge A needs result from Edge B
   A creates pipe: A (sender) → B (receiver)
   ```

2. **Output Pipe**: Response to requesting edge

   ```text
   Edge B completes, sends result back
   B (sender) → A (receiver)
   ```

3. **Function Pipe**: Async operation (exec, cache load)

   ```text
   Edge creates pipe to goroutine
   Edge (sender) → Goroutine (receiver)
   ```

### Scheduling Algorithm

**High-Level Overview:**

```text
While build not complete:
    1. Wait for signal (edge needs processing)
    2. Pop edge from queue
    3. Dispatch edge:
        a. Collect incoming requests
        b. Collect completed updates
        c. Call edge.unpark()
        d. Edge processes requests
        e. Edge creates new outgoing requests
        f. New requests signal their targets
    4. Repeat
```

**Detailed Dispatch:**

```go
func (s *scheduler) dispatch(e *edge) {
    // 1. Gather all incoming requests
    incoming := s.incoming[e]  // Pipes where e is target
    
    // 2. Gather all outgoing responses
    outgoing := s.outgoing[e]  // Pipes where e is source
    
    // 3. Check which pipes have updates
    updates := []pipeReceiver{}
    for _, p := range outgoing {
        if p.Receive() {  // New data available
            updates = append(updates, p)
        }
    }
    
    // 4. Let edge process
    e.unpark(incoming, updates, outgoing, pipeFactory)
    
    // 5. Clean up completed pipes
    // Remove pipes that are done
    
    // 6. Check for merge opportunity
    if e.keysDidChange {
        // Try to merge with identical edge
        origEdge := e.index.LoadOrStore(key, e)
        if origEdge != nil {
            s.mergeTo(dest, src)
        }
    }
}
```

### Edge Processing (unpark)

**Critical Function:** `edge.unpark()`

```go
func (e *edge) unpark(incoming []pipeSender, updates []pipeReceiver, 
    allPipes []pipeReceiver, f *pipeFactory) {
    
    // 1. Process all updates (completed requests)
    e.processUpdates(updates)
    
    // 2. Respond to incoming requests
    desiredState, done := e.respondToIncoming(incoming, allPipes)
    if done {
        return
    }
    
    // 3. Request cache map if needed
    if e.cacheMapReq == nil && e.cacheMap == nil {
        e.cacheMapReq = f.NewFuncRequest(func(ctx) {
            return e.op.CacheMap(ctx, index)
        })
    }
    
    // 4. Try to execute if complete state desired
    if e.execReq == nil && desiredState == edgeStatusComplete {
        e.execIfPossible(f)
        return
    }
    
    // 5. Request dependencies if not executing
    if e.execReq == nil {
        e.createInputRequests(desiredState, f)
    }
}
```

**State Machine:**

```text
unpark() called
    ↓
Process updates (step 1)
    ↓
Have all deps? ──No──→ Request deps (step 5)
    │ Yes                    ↓
    ↓                    Signal deps
Check cache                  ↓
    │                    Wait for completion
Cache hit? ──Yes──→ Load result
    │ No                     ↓
    ↓                    Deps complete
Execute op (step 4)          ↓
    ↓                    Back to unpark()
Save result
    ↓
Complete
```

### Parallel Execution

**How operations run in parallel:**

```text
    Scheduler (single thread)
         │
    ┌────┼────┬────┬────┐
    │    │    │    │    │
  Edge1 Edge2 Edge3 Edge4 Edge5
    │    │    │    │    │
    └────┼────┴────┴────┘
         │
    Operations (goroutines)
         │
    ┌────┼────┬────┬────┐
    │    │    │    │    │
   Op1  Op2  Op3  Op4  Op5
  (run) (run)(run)(run)(run)
```

**Key Points:**

1. **Scheduler is single-threaded**: No race conditions
2. **Operations run in goroutines**: True parallelism
3. **Pipes are thread-safe**: Enable async communication
4. **Edges signal scheduler**: When state changes

**Example Timeline:**

```text
Time  Scheduler Thread           Op Goroutines
----  -------------------------  ----------------------
T0    Dispatch Edge1             
T1    Edge1.unpark()            
T2      → Create execReq         Op1 starts
T3    Dispatch Edge2            
T4    Edge2.unpark()             Op1 running
T5      → Create execReq         Op2 starts
T6    Wait for signal            Op1 running, Op2 running
T7                                Op1 completes → signal
T8    Dispatch Edge1            
T9    Edge1.unpark()             Op2 running
T10     → Process exec result   
T11   Dispatch Edge3 (dep Edge1)
T12                               Op2 completes → signal
```

### Edge Merging

**Optimization:** Identical edges are merged to avoid duplicate work.

**When merging happens:**

```go
// After edge keys change
if e.keysDidChange {
    key := e.currentIndexKey()
    origEdge := e.index.LoadOrStore(key, e)
    
    if origEdge != nil && !isDep(origEdge, e) {
        // Merge e into origEdge
        s.mergeTo(origEdge, e)
    }
}
```

**Example:**

```text
Build Graph:
    Base → RUN echo "hello" → Export as tar
           RUN echo "hello" → Export as image

Two edges for "RUN echo hello" with same dependencies
    ↓
After cache keys computed, edges have identical keys
    ↓
Scheduler merges them
    ↓
Only one execution, both consumers get result
```

**What merging does:**

1. Redirect all incoming requests to target edge
2. Redirect all outgoing requests to target edge
3. Transfer secondary exporters
4. Signal target edge to process new requests
5. Discard source edge

---

## Execution Flow

### Complete Build Flow Example

Let's trace building this Dockerfile:

```dockerfile
FROM alpine:latest
RUN echo "hello" > /file.txt
```

#### Phase 1: Graph Building

**Step 1: Frontend parses Dockerfile**

```text
Frontend.Solve()
  └→ Convert to LLB
      ├→ Vertex 1: SourceOp(image://alpine:latest)
      └→ Vertex 2: ExecOp(exec echo "hello" > /file.txt)
                    depends on Vertex 1
```

**Step 2: Solver creates edges**

```text
job = solver.NewJob("build-123")
edge1 = newEdge(Vertex 1, SourceOp, index)
edge2 = newEdge(Vertex 2, ExecOp, index)
```

**Step 3: Client requests result**

```text
scheduler.build(ctx, edge2)
  └→ Creates pipe: client → edge2
  └→ Signals edge2
```

#### Phase 2: Edge 2 Processing

**Step 1: Edge 2 dispatched**

```text
scheduler.dispatch(edge2)
  └→ edge2.unpark(incoming=[clientRequest], updates=[], ...)
```

**Step 2: Edge 2 needs dependencies**

```text
edge2.unpark():
  1. Process updates: (none)
  2. Respond to incoming: desiredState = Complete
  3. Request cache map:
      cacheMapReq = NewFuncRequest(LoadCacheMap)
  4. Can't execute yet (no deps)
  5. Create input requests:
      depReq = NewInputRequest(edge1, needComplete)
      └→ Creates pipe: edge2 → edge1
      └→ Signals edge1
```

#### Phase 3: Edge 1 Processing

**Step 1: Edge 1 dispatched**

```text
scheduler.dispatch(edge1)
  └→ edge1.unpark(incoming=[edge2Request], ...)
```

**Step 2: Edge 1 resolves source**

```text
edge1.unpark():
  1. No dependencies (it's a source)
  2. Request cache map:
      cacheMapReq = NewFuncRequest(LoadCacheMap)
  3. Cache map loaded:
      cacheMap = {digest: "sha256:abc...", deps: []}
  4. Query cache:
      keys = cacheManager.Query([], "sha256:abc...")
  5. Cache miss (first time)
  6. Execute:
      execReq = NewFuncRequest(PullImage("alpine:latest"))
      └→ Worker pulls image
```

**Step 3: Edge 1 completes**

```text
execReq completes:
  └→ result = ImageSnapshot(alpine)
  └→ Signals edge1

edge1.unpark():
  └→ Process updates: [execReq completed]
  └→ edge1.result = ImageSnapshot
  └→ edge1.state = Complete
  └→ Respond to incoming: [edge2Request]
      └→ Send result to edge2
      └→ Signals edge2
```

#### Phase 4: Edge 2 Execution

**Step 1: Edge 2 dispatched (deps ready)**

```text
scheduler.dispatch(edge2)
  └→ edge2.unpark(incoming=[clientRequest], 
                  updates=[depReq, cacheMapReq], ...)
```

**Step 2: Edge 2 has dependencies**

```text
edge2.unpark():
  1. Process updates:
      - depReq: edge1 complete, result available
      - cacheMapReq: cache map loaded
  2. dep[0].result = ImageSnapshot
  3. Query cache:
      depKeys = [edge1.cacheKey]
      cacheKeys = cacheManager.Query(depKeys, "exec echo...")
  4. Cache miss (first time)
  5. Execute:
      execReq = NewFuncRequest(ExecInContainer(
          base: ImageSnapshot,
          cmd: ["sh", "-c", "echo hello > /file.txt"]
      ))
      └→ Worker creates container
      └→ Worker runs command
      └→ Worker commits snapshot
```

**Step 3: Edge 2 completes**

```text
execReq completes:
  └→ result = NewSnapshot(with /file.txt)
  └→ Signals edge2

edge2.unpark():
  └→ Process updates: [execReq completed]
  └→ edge2.result = NewSnapshot
  └→ edge2.state = Complete
  └→ Save to cache:
      cacheKey = CacheKey(
          digest: "exec echo...",
          deps: [edge1.cacheKey]
      )
      cacheManager.Save(cacheKey, result)
  └→ Respond to incoming: [clientRequest]
      └→ Send result to client
      └→ Complete!
```

#### Phase 5: Second Build (Cache Hit)

**Same Dockerfile, rebuilding:**

```text
Edge 2 processing:
  1. Request dependencies
  2. Edge 1 completes (may hit cache)
  3. Edge 2 query cache:
      depKeys = [edge1.cacheKey]  // Same as before!
      cacheKeys = cacheManager.Query(depKeys, "exec echo...")
      └→ Returns [cacheKey-456]
  4. Load from cache:
      records = cacheManager.Records(cacheKey-456)
      result = cacheManager.Load(records[0])
      └→ result = CachedSnapshot (no execution!)
  5. Edge 2 complete (cache hit!)
      └→ Return cached result
```

**Performance Difference:**

| Build | Edge 1 Time | Edge 2 Time | Total |
|-------|-------------|-------------|-------|
| First | 5s (pull)   | 2s (exec)   | 7s    |
| Second| 0.1s (cache)| 0.1s (cache)| 0.2s  |

**35x faster with cache!**

---

## Key Data Structures

### Cache Key

**Purpose:** Uniquely identifies an operation and its inputs

```go
type CacheKey struct {
    digest  digest.Digest      // Operation digest
    output  Index               // Output index
    ids     []string            // Alternative IDs
    deps    [][]CacheKeyWithSelector  // Dependency keys
    vtx     digest.Digest       // Vertex digest
}
```

**Example:**

```text
Operation: RUN echo "hello"
Dependencies: [alpine:latest-key]

CacheKey {
    digest: "sha256:abc123...",  // Hash of "RUN echo hello"
    output: 0,
    deps: [[{CacheKey: alpine-key}]],
    vtx: "sha256:vertex123..."
}
```

### Cache Record

**Purpose:** Points to a cached result

```go
type CacheRecord struct {
    ID           string         // Result ID
    cacheManager *cacheManager
    key          *CacheKey
    CreatedAt    time.Time
}
```

### Result

**Purpose:** Actual build output (filesystem snapshot, etc.)

```go
type Result interface {
    ID() string
    Release(context.Context) error
    Sys() interface{}  // e.g., *worker.WorkerRef
}
```

### Edge State

**Purpose:** Current state of an edge

```go
type edgeState struct {
    state    edgeStatusType         // Initial, CacheFast, CacheSlow, Complete
    result   *SharedCachedResult    // Final result
    cacheMap *CacheMap              // Cache key definition
    keys     []ExportableCacheKey   // Available cache keys
}
```

### Cache Map

**Purpose:** Defines how to compute cache keys

```go
type CacheMap struct {
    Digest digest.Digest           // Content digest
    Deps   []struct {
        Selector          CacheSelector
        ComputeDigestFunc ResultBasedCacheFunc  // Slow cache
        PreprocessFunc    PreprocessFunc
    }
}
```

---

## Advanced Topics

### Slow Cache (Content-Based)

**When is slow cache used?**

Operations that depend on file content, not just definitions:

```dockerfile
COPY . /app
```

**Why slow?**

- Must read and hash all files
- Can be GB of data
- Computed after dependency completes

**Example:**

```text
COPY . /app (100 files, 10MB)

Fast Cache:
  Key = Hash("COPY . /app", parent-key)
  Problem: Doesn't detect if files changed!
  
Slow Cache:
  Key = Hash(
    "COPY . /app",
    parent-key,
    Hash(file1-content),
    Hash(file2-content),
    ...
    Hash(file100-content)
  )
  Solution: Detects ANY file change
  Cost: Must hash 10MB of data
```

**Implementation:**

```go
type ResultBasedCacheFunc func(ctx context.Context, res Result, 
    g session.Group) (digest.Digest, error)

// Example: Compute digest of all files
func computeFileDigests(ctx context.Context, res Result, 
    g session.Group) (digest.Digest, error) {
    
    ref := res.Sys().(*worker.WorkerRef).ImmutableRef
    
    // Mount the snapshot
    mounts, err := ref.Mount(ctx, readonly)
    
    // Walk all files
    var digests []digest.Digest
    filepath.Walk(mountPath, func(path string, info os.FileInfo, err error) error {
        if info.IsDir() {
            return nil
        }
        // Hash file content
        data, _ := os.ReadFile(path)
        digests = append(digests, digest.FromBytes(data))
        return nil
    })
    
    // Combine all digests
    return digest.FromBytes(combineDigests(digests)), nil
}
```

### Preprocessors

**Purpose:** Transform results before computing slow cache

**Example:** Remove timestamps before hashing (for reproducibility)

```go
type PreprocessFunc func(ctx context.Context, res Result, 
    g session.Group) error

func removeTimestamps(ctx context.Context, res Result, 
    g session.Group) error {
    
    // Modify result to remove timestamp metadata
    // so it doesn't affect cache key
    return nil
}
```

### Cache Export/Import

**Export Cache:**

```text
Local Build → Cache Export → Registry
                  ↓
             Cache Manifest
                  ↓
        [Layer Digests + Keys]
```

**Import Cache:**

```text
Registry → Cache Import → Solver
    ↓
Cache Records Available
    ↓
Build can hit cache without re-executing
```

**Usage:**

```bash
# Export
buildctl build \
  --export-cache type=registry,ref=myregistry/buildcache

# Import
buildctl build \
  --import-cache type=registry,ref=myregistry/buildcache
```

---

## Debugging the Solver

### Enable Debug Logging

```bash
export BUILDKIT_SCHEDULER_DEBUG=1
```

This enables detailed logging of:

- Edge state transitions
- Pipe creation/completion
- Merge operations
- Scheduling decisions

### Key Log Messages

**Edge Creation:**

```text
SCHEDULER: edge created: edge[sha256:abc] vertex="RUN echo hello"
```

**State Transitions:**

```text
SCHEDULER: edge[sha256:abc] state: initial → cache-fast
SCHEDULER: edge[sha256:abc] state: cache-fast → complete (cache hit!)
```

**Merge Operations:**

```text
SCHEDULER: merging edge[sha256:def] into edge[sha256:abc]
```

**Pipe Operations:**

```text
SCHEDULER: new pipe: edge[sha256:abc] → edge[sha256:def]
SCHEDULER: pipe completed: edge[sha256:abc] → edge[sha256:def]
```

### Common Issues

**1. Deadlock (edges waiting forever)**

**Symptom:** Build hangs

**Debug:**

```text
SCHEDULER: edge[X] leaving incoming open (no outgoing)
```

**Cause:** Algorithm bug in `unpark()` - edge didn't create needed requests

**2. Cache Miss (expected hit)**

**Debug:** Check cache key computation

```go
// Add logging to CacheManager.Query
log.Debugf("Query: deps=%v, digest=%v", deps, dgst)
log.Debugf("Found keys: %v", keys)
```

**Common causes:**

- Dependency changed
- Definition changed
- Cache cleared

**3. Performance Issues**

**Debug:** Look for:

- Too many slow cache computations
- Unnecessary re-executions
- Sequential execution (missing parallelism)

**Tools:**

```bash
# Trace with bklog
export BUILDKIT_DEBUG=1

# Profile with pprof
buildkitd --debug --debugaddr=0.0.0.0:6060
go tool pprof http://localhost:6060/debug/pprof/profile
```

---

## Summary

### Key Takeaways

1. **Graph Building**:
   - Frontend parses input → LLB graph
   - Solver creates edges for each vertex
   - Edges represent operations + state

2. **Cache System**:
   - Two-level: Fast (definition) + Slow (content)
   - Content-addressable storage
   - Transitive invalidation

3. **Scheduling**:
   - Reactive push-based model
   - Single-threaded scheduler
   - Parallel operation execution
   - Pipe-based communication

4. **Execution**:
   - Lazy evaluation
   - Cache-first strategy
   - Concurrent operations
   - Edge merging optimization

### Critical Files to Study

1. **solver/llbsolver/solver.go** - Main entry point
2. **solver/scheduler.go** - Scheduling algorithm
3. **solver/edge.go** - Edge state machine
4. **solver/cachemanager.go** - Cache management
5. **solver/jobs.go** - Job tracking

### Next Steps

1. **Experiment**: Enable debug logging and trace a build
2. **Read Code**: Follow execution through `Solve()` → `build()` → `unpark()`
3. **Modify**: Try adding custom cache logic or scheduler operations
4. **Profile**: Use pprof to understand performance

---

## Additional Resources

- **BuildKit Architecture**: [docs/dev/architecture.md](docs/dev/architecture.md)
- **Cache Design**: [docs/dev/cache.md](docs/dev/cache.md)
- **LLB Spec**: [https://github.com/moby/buildkit/blob/master/README.md](https://github.com/moby/buildkit/blob/master/README.md)

---

**Questions? Issues?**

Open a discussion in the BuildKit repository: [github.com/moby/buildkit/discussions](https://github.com/moby/buildkit/discussions)
