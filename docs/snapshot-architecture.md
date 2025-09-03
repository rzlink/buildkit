# Snapshot Architecture in BuildKit

## Overview

Snapshots are the fundamental building blocks of BuildKit's filesystem management. They represent immutable, point-in-time captures of filesystem state.

## Architecture Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    BuildKit (High Level)                    │
│  - Build instructions (Dockerfile)                          │
│  - LLB (Low-Level Build) operations                         │
│  - Cache management                                         │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              Cache Manager (cache/manager.go)               │
│  - ImmutableRef: Read-only snapshot references              │
│  - MutableRef: Read-write snapshot references               │
│  - Lazy pulling, compression, metadata                      │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│          Snapshot Manager (snapshot/snapshotter.go)         │
│  - Prepare(): Create writable snapshot                      │
│  - View(): Create read-only snapshot                        │
│  - Commit(): Make snapshot immutable                        │
│  - Mount(): Get mountable reference                         │
└────────────────────────┬───────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│         External Snapshotter (Containerd/others)            │
│  - overlayfs (Linux)                                        │
│  - native (all platforms)                                   │
│  - windowsfs (Windows)                                      │
│  - stargz (lazy pulling)                                    │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                   Host Filesystem                           │
│  /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs │
│  or C:\ProgramData\containerd\root\io.containerd.windowsfs  │
└─────────────────────────────────────────────────────────────┘
```

## Key Operations

### 1. Prepare (Create Mutable Snapshot)

Creates a **read-write** snapshot that can be modified:

```go
// BuildKit creates a working snapshot based on a parent
err := snapshotter.Prepare(ctx, "build-step-123", "parent-layer-sha256:abc...")
```

**Use case**: Running RUN commands, COPY operations

```
Parent Layer (read-only)
    ↓ fork
Active Snapshot "build-step-123" (read-write)
```

### 2. View (Create Read-Only Snapshot)

Creates a **read-only** view of a parent snapshot:

```go
// BuildKit creates a read-only view for inspection
mountable, err := snapshotter.View(ctx, "view-123", "layer-sha256:abc...")
```

**Use case**: Inspecting image contents, COPY --from operations

### 3. Mount (Access Filesystem)

Gets a `Mountable` that can be mounted to the host filesystem:

```go
// Get mountable reference
mountable, err := ref.Mount(ctx, readonly, sessionGroup)

// Mount to temporary directory
mounter := snapshot.LocalMounter(mountable)
mountPath, err := mounter.Mount()
// mountPath = "/tmp/buildkit-mount123"

// Now you can access files at mountPath
files, err := os.ReadDir(mountPath)

// Unmount when done
err = mounter.Unmount()
```

**This is when protected Windows files become visible!**

### 4. Commit (Make Immutable)

Converts an active (mutable) snapshot into an immutable layer:

```go
// After RUN command completes, commit the changes
err := snapshotter.Commit(ctx, "layer-sha256:new...", "build-step-123")
```

```
Active Snapshot "build-step-123" (read-write, temporary)
    ↓ commit
Committed Layer "sha256:new..." (read-only, permanent, cached)
```

## How COPY Operations Use Snapshots

### When you run: `COPY --from=base /test/a/b/c /out/`

1. **Source Snapshot Preparation**
   ```go
   // BuildKit gets the "base" stage snapshot
   sourceRef := cache.GetImmutableRef("base-stage-id")
   sourceMountable, _ := sourceRef.Mount(ctx, true, session)
   ```

2. **Mount to Host Filesystem**
   ```go
   // Mount the container filesystem to host
   sourceMounter := snapshot.LocalMounter(sourceMountable)
   sourcePath, _ := sourceMounter.Mount()
   // sourcePath might be: "C:\mount\containerd\snapshots\123"
   ```

3. **Windows Issue: Protected Files Appear**
   At this mount point, Windows container filesystem includes:
   ```
   C:\mount\containerd\snapshots\123\
   ├── test/           (your files)
   ├── Windows/        (container OS)
   ├── Program Files/  (container OS)
   ├── System Volume Information/  ⚠️ PROTECTED
   └── WcSandboxState/            ⚠️ PROTECTED
   ```

4. **Copy Operation**
   ```go
   // BuildKit tries to copy from mounted path
   srcFullPath := filepath.Join(sourcePath, "/test/a/b/c")
   
   // But if copying from root, it encounters protected files:
   srcFullPath := sourcePath  // Root of mount
   // ERROR: "Access denied" on protected files
   ```

5. **Destination Snapshot Preparation**
   ```go
   // Prepare writable destination snapshot
   destRef := cache.NewMutableRef()
   destMountable, _ := destRef.Mount(ctx, false, session)
   destMounter := snapshot.LocalMounter(destMountable)
   destPath, _ := destMounter.Mount()
   ```

6. **Perform Copy**
   ```go
   // Copy files from source mount to dest mount
   copy.Copy(ctx, sourcePath, "/test/a/b/c", destPath, "/out/")
   ```

7. **Commit Changes**
   ```go
   destMounter.Unmount()
   sourceMounter.Unmount()
   
   // Commit the destination as new layer
   destRef.Commit(ctx)
   ```

## Snapshot Lifecycle Example

### Building: `FROM alpine RUN apk add curl`

```
1. Pull alpine image
   └─> Snapshot: sha256:alpine-base (immutable)

2. Prepare() for RUN command
   └─> Active snapshot: "run-apk-123" (parent: alpine-base)
       
3. Mount() the active snapshot
   └─> Mount to: /tmp/buildkit-mount-456
   
4. Execute: apk add curl (inside container, writes to mount)
   └─> Files written to mounted filesystem
   
5. Unmount()

6. Commit() the active snapshot
   └─> New immutable snapshot: sha256:alpine-with-curl
   
7. Remove() active snapshot
   └─> Cleanup "run-apk-123"
   
Final result: New cached layer with curl installed
```

## Delegation to External Snapshotters

BuildKit **delegates** actual snapshot storage to external implementations:

### Linux (Containerd with overlayfs)
```go
// BuildKit calls
snapshotter.Prepare(ctx, key, parent)
    ↓
// Containerd overlayfs driver
// Creates: /var/lib/containerd/.../overlay/
//   - lowerdir (parent layers)
//   - upperdir (new changes)
//   - workdir  (temp)
```

### Windows (Containerd with windowsfs)
```go
// BuildKit calls  
snapshotter.Prepare(ctx, key, parent)
    ↓
// Containerd windowsfs driver
// Creates Windows container layer
// Uses WCIFS (Windows Container Isolation File System)
```

### Why External Snapshotters?

1. **Platform-specific**: Different filesystems (overlayfs, WCIFS, etc.)
2. **Optimization**: Specialized implementations (stargz for lazy pulling)
3. **Flexibility**: Swap implementations without changing BuildKit
4. **Maintenance**: Filesystem logic stays in containerd/specialized projects

## Mount Roots and Protected Files

### The Problem on Windows

When containerd mounts a Windows container snapshot:

```
Container snapshot mounted at: C:\mount\snapshot-123\
├── test\              (your application files)
├── Windows\           (container Windows OS)
├── Program Files\     (container programs)
├── System Volume Information\  ⚠️ Windows protected file
└── WcSandboxState\            ⚠️ Windows container metadata
```

**These protected files**:
- Exist at the **snapshot mount root**
- **Cannot be accessed** even with Administrator privileges
- Cause "Access denied" errors if you try to enumerate/stat them
- Are created by Windows container isolation layer

### Why Our Fix Works

We detect when copying **from a mount root** that contains these files, and:
1. Manually enumerate children (before any stat/access operations)
2. Filter out protected files from the list
3. Copy only the accessible children
4. Respect any include patterns to only copy what's specified

## Important Clarification: Mount Does NOT Copy Files!

### Common Misconception

**WRONG**: Mount copies all files from container to host
**CORRECT**: Mount creates a **view/link** to files, no copying happens

### What Actually Happens on Windows

```
Step 1: Containerd prepares the Windows layer
   - Calls hcsshim.ActivateLayer() - Windows container layer activation
   - Calls hcsshim.PrepareLayer() - Merges parent layers
   - Calls hcsshim.GetLayerMountPath() - Gets the WCIFS volume path
   
Step 2: Mount creates a binding
   - Uses bindfilter.ApplyFileBinding(target, volume, readonly)
   - Creates a DIRECTORY JUNCTION or BIND (not a copy!)
   - Target directory now "points to" the layer volume
   
Example:
   Target:  C:\Temp\buildkit-mount-123\
   Volume:  \\?\Volume{abc-def}\layer-456\Files\
   
   After mount, accessing C:\Temp\buildkit-mount-123\test\foo.txt
   actually reads from \\?\Volume{abc-def}\layer-456\Files\test\foo.txt
```

### Where Do Protected Files Come From?

The **layer volume itself** (created by Windows Container Isolation FS) contains:

```
\\?\Volume{abc-def}\layer-456\Files\
├── test\                          (your application files)
├── Windows\                       (container OS files)
├── Program Files\                 (container programs)
├── System Volume Information\     ⚠️ Windows system metadata
└── WcSandboxState\               ⚠️ Container sandbox state
```

**These files exist in the Windows Container volume**, not copied by mount!

Containerd/hcsshim **creates** the layer volume with these system files. They're part of how Windows containers work (WCIFS - Windows Container Isolation File System).

### When Does Containerd Get Involved?

```
BuildKit Request Flow:
1. BuildKit calls: snapshotter.Prepare(ctx, key, parent)
   ↓
2. BuildKit's snapshotter wrapper forwards to Containerd
   ↓
3. Containerd's windowsfs snapshotter:
   - Creates new layer ID
   - Registers layer with hcsshim
   - Returns mount information
   ↓
4. BuildKit calls: ref.Mount(ctx, readonly, session)
   ↓
5. BuildKit's LocalMounter.Mount():
   - Calls containerd mount.Mount(dir)
   ↓
6. Containerd's mount_windows.go:
   - hcsshim.ActivateLayer()
   - hcsshim.PrepareLayer() 
   - hcsshim.GetLayerMountPath()  ← Protected files are HERE
   - bindfilter.ApplyFileBinding() ← Creates the binding/junction
   ↓
7. Now BuildKit can access files through the mount point
```

### How Does Containerd Handle Protected Files?

**Short answer: It doesn't!**

Containerd just:
1. Activates the Windows layer (tells Windows to make it available)
2. Gets the mount path from hcsshim (Windows returns the volume path)
3. Creates a binding to that path

The protected files **exist in the Windows volume** that hcsshim provides. Containerd never tries to enumerate or access them - it just creates a binding to the volume root.

**The problem occurs later** when BuildKit tries to:
- List files at the mount root (`os.ReadDir`)
- Stat files at the mount root (`os.Lstat`)
- Copy from the mount root (`copy.Copy`)

### Answer to Your Questions

**Q1: What does step 4 'copy operation' do if mount already copied?**

**A**: Mount does NOT copy! Step 4 is where the **actual copying** happens:
- Mount (step 2): Creates a view/binding to container filesystem
- Copy (step 4): Reads files from mounted path, writes to destination
- This is when BuildKit tries to enumerate files and hits protected files

**Q2: When does Containerd get involved? How does it handle protected files?**

**A**: Containerd is involved in steps 1-3 (Prepare/View/Mount):
- It creates the Windows layer volume through hcsshim
- It provides the mount path
- **It does NOT handle protected files** - they just exist in the volume
- The problem happens when **BuildKit** tries to access those files through the mount

### The Real Problem Flow

```
1. BuildKit: "I need to copy from /test/a/b/c"
2. BuildKit: Mount source snapshot → C:\mount\snapshot-123\
3. Containerd/hcsshim: Creates binding to Windows volume
   (Volume contains: test\, Windows\, System Volume Information\, etc.)
4. BuildKit: "Now copy from C:\mount\snapshot-123\..."
5. copy.Copy: Tries to enumerate files at mount root
6. copy.Copy: Calls os.Lstat("C:\mount\snapshot-123\System Volume Information")
7. Windows: "ACCESS DENIED" ❌
8. BuildKit: Copy operation fails!

OUR FIX:
- Detects when source is mount root (C:\mount\snapshot-123\)
- Manually enumerates with os.ReadDir (succeeds, gets list of names)
- Filters out "System Volume Information" and "WcSandboxState"
- Copies only the accessible files/folders
- Never calls os.Lstat on protected files
```

## Summary

- **Snapshot** = Immutable filesystem layer stored by Containerd
- **Prepare/View** = Containerd creates/activates Windows Files** = Appear at mount roots on Windows, require special handling

This architecture enables:
- ✅ Efficient layer caching
- ✅ Parallel builds
- ✅ Content deduplication
- ✅ Platform abstraction
- ⚠️ But requires handling platform-specific quirks (like Windows protected files)
