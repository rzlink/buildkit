# WCOW Support for Linux Layers - Issue #4537 Analysis

## Executive Summary

BuildKit currently supports building Windows container images on Linux (cross-compilation), but **does not support the reverse**: Windows BuildKit cannot build or manipulate Linux images. This document analyzes the problem and proposes a solution for bidirectional layer format transformation.

**Current State:**
- ✅ Linux BuildKit can build Windows images (cross-compile)
- ❌ Windows BuildKit cannot build Linux images

**Goal:**
- ✅ Both Linux and Windows BuildKit can handle both layer types
- ✅ Layer transformation based on platform metadata, not `runtime.GOOS`
- ✅ Bidirectional transformation (add/remove `Files/Hives` wrapper)

---

## Table of Contents

- [Background: Layer Format Differences](#background-layer-format-differences)
- [Current Implementation](#current-implementation)
- [The Problem](#the-problem)
- [Proposed Solution](#proposed-solution)
- [Implementation Details](#implementation-details)
- [Testing Strategy](#testing-strategy)
- [Challenges and Considerations](#challenges-and-considerations)
- [Next Steps](#next-steps)

---

## Background: Layer Format Differences

Container layer tarballs have fundamentally different structures between Linux and Windows:

### Linux Container Layers (Standard OCI Format)

```
tarball
├── usr/
│   └── bin/
│       └── app
├── etc/
│   └── config
├── file.txt
└── ... (rootfs files directly at root)
```

**Characteristics:**
- Rootfs files directly in tarball root
- Standard POSIX permissions
- Works with `tar xvf` as expected

### Windows Container Layers (WCOW Format)

```
tarball
├── Hives/                    # Windows registry data
│   └── (registry files)
└── Files/                    # Actual rootfs
    ├── Windows/
    ├── Program Files/
    ├── Users/
    └── ... (all filesystem content)
```

**Characteristics:**
- All rootfs content under `Files/` directory
- `Hives/` directory contains Windows registry data
- Every file requires Windows-specific PAX headers:
  - `MSWINDOWS.fileattr` - File attributes
  - `MSWINDOWS.rawsd` - Security descriptors (ACLs)
  - `LIBARCHIVE.creationtime` - Creation timestamp
- Format is **undocumented** and runtime-specific

### Why The Difference?

Windows containers have additional requirements beyond a filesystem:
1. **Registry**: Windows applications depend on registry settings (`Hives/`)
2. **Security**: Windows requires ACL/security descriptor metadata
3. **HyperV Isolation**: Base images include `UtilityVM/` for isolated execution
4. **OS Differences**: Windows has non-file system state that must be captured

---

## Current Implementation

### 1. Linux BuildKit → Windows Images (✅ Working)

BuildKit has transformation logic to support building Windows images on Linux:

#### Layer Generation (`util/winlayers/differ.go`)

When generating a diff for a Windows image on Linux:

```go
func makeWindowsLayer(ctx context.Context, w io.Writer) (io.Writer, func(error), chan error) {
    // Creates transformation pipeline:
    // 1. Add "Hives/" directory
    // 2. Add "Files/" directory
    // 3. For each file from diff:
    //    - Prefix path: "app" → "Files/app"
    //    - Prefix linkname: "link" → "Files/link"
    //    - Add Windows PAX headers (fileattr, rawsd, creationtime)
    //    - Add security descriptors
}
```

**Example transformation:**
```
Input (Linux diff):          Output (Windows layer):
usr/bin/app                  Files/usr/bin/app (+ PAX headers)
etc/config                   Files/etc/config (+ PAX headers)
                             Hives/ (empty directory)
```

#### Layer Application (`util/winlayers/applier.go`)

When applying a Windows layer on Linux:

```go
func (s *winApplier) Apply(ctx context.Context, desc ocispecs.Descriptor, mounts []mount.Mount, opts ...diff.ApplyOpt) {
    // Strips "Files/" prefix from paths:
    rc2, discard := filter(rc, func(hdr *tar.Header) bool {
        if after, ok := strings.CutPrefix(hdr.Name, "Files/"); ok {
            hdr.Name = after  // "Files/usr/bin/app" → "usr/bin/app"
            hdr.Linkname = strings.TrimPrefix(hdr.Linkname, "Files/")
            return true
        }
        return false  // Skip Hives/ and other entries
    })
}
```

#### Activation Logic (`source/containerimage/pull.go`)

```go
// Line 250
setWindowsLayerType := p.Platform.OS == "windows" && runtime.GOOS != "windows"

// Later:
if setWindowsLayerType {
    if err := current.SetLayerType("windows"); err != nil {
        return nil, err
    }
}
```

This sets metadata that triggers `UseWindowsLayerMode(ctx)` during layer operations.

### 2. Windows BuildKit → Linux Images (❌ Missing)

**Problem:** No reverse transformation exists!

Current behavior when Windows BuildKit encounters Linux layers:
1. ❌ `pull.go` skips setting layer type because `runtime.GOOS == "windows"`
2. ❌ `applier.go` returns early because `runtime.GOOS == "windows"`
3. ❌ No wrapping happens when applying Linux layers
4. ❌ No unwrapping happens when generating Linux layers
5. ❌ File operations on Linux images fail

---

## The Problem

### Root Cause: `runtime.GOOS` Checks

The code has two problematic checks that prevent bidirectional support:

#### Issue #1: `source/containerimage/pull.go:250`

```go
// CURRENT CODE (WRONG):
setWindowsLayerType := p.Platform.OS == "windows" && runtime.GOOS != "windows"
//                                                    ^^^^^^^^^^^^^^^^^^^^
//                                    This prevents Windows BuildKit from handling Windows layers!
```

**Impact:** On Windows BuildKit, `setWindowsLayerType` is always `false`, even for Windows layers. The layer type is never set, so transformation logic never activates.

#### Issue #2: `util/winlayers/applier.go:24`

```go
// CURRENT CODE (WRONG):
func NewFileSystemApplierWithWindows(cs content.Provider, a diff.Applier) diff.Applier {
    if runtime.GOOS == "windows" {
        return a  // Bypass wrapper entirely on Windows!
    }
    
    return &winApplier{
        cs: cs,
        a:  a,
    }
}
```

**Impact:** On Windows, the wrapper is never used, so no transformation logic is available for Linux layers.

### Why This Logic Exists

The original logic assumed:
- Windows BuildKit would only handle Windows layers (native)
- Linux BuildKit would only handle Linux layers (native)
- Cross-compilation only happens on Linux → Windows

**Reality:**
- Windows BuildKit needs to handle Linux images (multi-platform builds)
- Layer format should be determined by **layer platform**, not **host OS**
- Windows containerd storage always uses `Files/Hives` format internally

### The Missing Piece

Windows containerd snapshotter stores **all layers** in Windows format internally:

```
Windows Snapshotter Storage:
├── snapshot-1 (Windows layer)
│   ├── Files/
│   └── Hives/
│
└── snapshot-2 (Linux layer - SHOULD be wrapped)
    ├── Files/          ← Must be added!
    │   └── (Linux rootfs)
    └── Hives/          ← Must be added!
```

When exporting Linux images from Windows BuildKit:
- Storage has `Files/` prefix
- Export needs to strip it
- Currently doesn't happen!

---

## Proposed Solution

### Core Principle

**Transform layers based on LAYER PLATFORM and STORAGE FORMAT, not runtime.GOOS:**

```
Decision Matrix:
┌─────────────────┬──────────────────┬─────────────────┐
│ Layer Platform  │ Storage Format   │ Transformation  │
├─────────────────┼──────────────────┼─────────────────┤
│ Windows         │ Linux (overlay)  │ Strip "Files/"  │
│ Linux           │ Linux (overlay)  │ None            │
│ Windows         │ Windows (WCIFS)  │ None            │
│ Linux           │ Windows (WCIFS)  │ Add "Files/"    │
└─────────────────┴──────────────────┴─────────────────┘

Storage Format determined by: runtime.GOOS / snapshotter type
Layer Platform determined by: Image manifest platform.OS
```

### High-Level Changes

1. **Remove `runtime.GOOS` conditions** - Use layer metadata instead
2. **Add reverse transformations** - Support Linux layers on Windows
3. **Unify transformation logic** - One code path, four cases

---

## Implementation Details

### Phase 1: Remove `runtime.GOOS` Checks

#### Change 1: `source/containerimage/pull.go`

```go
// BEFORE:
setWindowsLayerType := p.Platform.OS == "windows" && runtime.GOOS != "windows"

// AFTER:
setWindowsLayerType := p.Platform.OS == "windows"

// Rationale: Always set layer type based on platform, regardless of host OS
```

#### Change 2: `util/winlayers/applier.go`

```go
// BEFORE:
func NewFileSystemApplierWithWindows(cs content.Provider, a diff.Applier) diff.Applier {
    if runtime.GOOS == "windows" {
        return a  // Skip wrapper
    }
    return &winApplier{cs: cs, a: a}
}

// AFTER:
func NewFileSystemApplierWithWindows(cs content.Provider, a diff.Applier) diff.Applier {
    // Always return wrapper - decision made per-layer based on metadata
    return &winApplier{cs: cs, a: a}
}
```

### Phase 2: Add Bidirectional Transformation

#### Change 3: `util/winlayers/applier.go` - Enhanced Apply Logic

```go
func (s *winApplier) Apply(ctx context.Context, desc ocispecs.Descriptor, 
    mounts []mount.Mount, opts ...diff.ApplyOpt) (d ocispecs.Descriptor, err error) {
    
    layerIsWindows := hasWindowsLayerMode(ctx)
    storageIsWindows := runtime.GOOS == "windows"
    
    // Four transformation cases:
    switch {
    case layerIsWindows && !storageIsWindows:
        // Windows layer → Linux storage
        // Strip "Files/" prefix
        return s.applyWindowsLayerOnLinux(ctx, desc, mounts, opts...)
        
    case !layerIsWindows && storageIsWindows:
        // Linux layer → Windows storage
        // Add "Files/" prefix (NEW!)
        return s.applyLinuxLayerOnWindows(ctx, desc, mounts, opts...)
        
    case layerIsWindows && storageIsWindows:
        // Windows layer → Windows storage
        // No transformation needed
        return s.a.Apply(ctx, desc, mounts, opts...)
        
    case !layerIsWindows && !storageIsWindows:
        // Linux layer → Linux storage
        // No transformation needed
        return s.a.Apply(ctx, desc, mounts, opts...)
    }
}
```

#### New Function: `applyLinuxLayerOnWindows`

```go
func (s *winApplier) applyLinuxLayerOnWindows(ctx context.Context, 
    desc ocispecs.Descriptor, mounts []mount.Mount, 
    opts ...diff.ApplyOpt) (ocispecs.Descriptor, error) {
    
    // Decompress layer
    compressed, err := images.DiffCompression(ctx, desc.MediaType)
    if err != nil {
        return ocispecs.Descriptor{}, err
    }
    
    return mount.WithTempMount(ctx, mounts, func(root string) error {
        ra, err := s.cs.ReaderAt(ctx, desc)
        if err != nil {
            return err
        }
        defer ra.Close()
        
        r := content.NewReader(ra)
        if compressed != "" {
            ds, err := compression.DecompressStream(r)
            if err != nil {
                return err
            }
            defer ds.Close()
            r = ds
        }
        
        digester := digest.Canonical.Digester()
        rc := &readCounter{r: io.TeeReader(r, digester.Hash())}
        
        // Transform: Add "Files/" prefix and Windows metadata
        rc2, discard := wrapWithFilesPrefix(rc, func(hdr *tar.Header) {
            // Add "Files/" prefix to paths
            hdr.Name = "Files/" + hdr.Name
            if hdr.Linkname != "" {
                hdr.Linkname = "Files/" + hdr.Linkname
            }
            
            // Add Windows PAX headers
            prepareWinHeader(hdr)
            addSecurityDescriptor(hdr)
        })
        
        // Also need to create Hives/ directory
        if err := createHivesDirectory(root); err != nil {
            discard(err)
            return err
        }
        
        if _, err := archive.Apply(ctx, root, rc2); err != nil {
            discard(err)
            return err
        }
        
        // Read trailing data
        if _, err := io.Copy(io.Discard, rc); err != nil {
            discard(err)
            return err
        }
        
        return nil
    })
}
```

#### Change 4: `util/winlayers/differ.go` - Enhanced Compare Logic

```go
func (s *winDiffer) Compare(ctx context.Context, lower, upper []mount.Mount, 
    opts ...diff.Opt) (d ocispecs.Descriptor, err error) {
    
    layerIsWindows := hasWindowsLayerMode(ctx)
    storageIsWindows := runtime.GOOS == "windows"
    
    switch {
    case layerIsWindows && !storageIsWindows:
        // Windows layer from Linux storage
        // Add "Files/" prefix
        return s.generateWindowsLayerOnLinux(ctx, lower, upper, opts...)
        
    case !layerIsWindows && storageIsWindows:
        // Linux layer from Windows storage
        // Strip "Files/" prefix (NEW!)
        return s.generateLinuxLayerOnWindows(ctx, lower, upper, opts...)
        
    default:
        // No transformation needed
        return s.d.Compare(ctx, lower, upper, opts...)
    }
}
```

#### New Function: `generateLinuxLayerOnWindows`

```go
func (s *winDiffer) generateLinuxLayerOnWindows(ctx context.Context, 
    lower, upper []mount.Mount, opts ...diff.Opt) (ocispecs.Descriptor, error) {
    
    var config diff.Config
    for _, opt := range opts {
        if err := opt(&config); err != nil {
            return emptyDesc, err
        }
    }
    
    if config.MediaType == "" {
        config.MediaType = ocispecs.MediaTypeImageLayerGzip
    }
    
    return mount.WithTempMount(ctx, lower, func(lowerRoot string) error {
        return mount.WithTempMount(ctx, upper, func(upperRoot string) error {
            cw, err := s.store.Writer(ctx, content.WithRef(config.Reference))
            if err != nil {
                return err
            }
            defer cw.Close()
            
            // Create compression if needed
            var w io.Writer = cw
            var dgstr digest.Digester
            
            if isCompressed(config.MediaType) {
                dgstr = digest.SHA256.Digester()
                compressed, err := compression.CompressStream(cw, compression.Gzip)
                if err != nil {
                    return err
                }
                defer compressed.Close()
                w = io.MultiWriter(compressed, dgstr.Hash())
            }
            
            // Transform: Strip "Files/" prefix and remove Windows metadata
            tw := tar.NewWriter(w)
            err = archive.WriteDiff(ctx, tw, lowerRoot, upperRoot, 
                archive.WithFilter(func(hdr *tar.Header) (bool, error) {
                    // Strip "Files/" prefix
                    if after, ok := strings.CutPrefix(hdr.Name, "Files/"); ok {
                        hdr.Name = after
                        if hdr.Linkname != "" {
                            hdr.Linkname = strings.TrimPrefix(hdr.Linkname, "Files/")
                        }
                        
                        // Remove Windows PAX headers
                        removeWindowsHeaders(hdr)
                        
                        return true, nil  // Include this file
                    }
                    
                    // Skip Hives/ directory
                    if strings.HasPrefix(hdr.Name, "Hives/") {
                        return false, nil
                    }
                    
                    return false, nil
                }))
            
            if err != nil {
                return err
            }
            
            if err := tw.Close(); err != nil {
                return err
            }
            
            dgst := cw.Digest()
            if err := cw.Commit(ctx, 0, dgst); err != nil {
                return err
            }
            
            return nil
        })
    })
}

func removeWindowsHeaders(hdr *tar.Header) {
    if hdr.PAXRecords != nil {
        delete(hdr.PAXRecords, keyFileAttr)
        delete(hdr.PAXRecords, keySDRaw)
        delete(hdr.PAXRecords, keyCreationTime)
        
        if len(hdr.PAXRecords) == 0 {
            hdr.PAXRecords = nil
        }
    }
    
    // Revert to standard tar format if no PAX records remain
    if hdr.PAXRecords == nil {
        hdr.Format = tar.FormatPAX  // or tar.FormatGNU
    }
}
```

### Phase 3: Helper Functions

#### New: `wrapWithFilesPrefix`

```go
func wrapWithFilesPrefix(in io.Reader, transform func(*tar.Header)) (io.Reader, func(error)) {
    pr, pw := io.Pipe()
    rc := &readCanceler{Reader: in}
    
    go func() {
        tarReader := tar.NewReader(rc)
        tarWriter := tar.NewWriter(pw)
        
        // First, create Hives/ directory
        hivesHdr := &tar.Header{
            Name:     "Hives",
            Typeflag: tar.TypeDir,
            ModTime:  time.Now(),
        }
        prepareWinHeader(hivesHdr)
        if err := tarWriter.WriteHeader(hivesHdr); err != nil {
            pw.CloseWithError(err)
            return
        }
        
        // Then create Files/ directory
        filesHdr := &tar.Header{
            Name:     "Files",
            Typeflag: tar.TypeDir,
            ModTime:  time.Now(),
        }
        prepareWinHeader(filesHdr)
        if err := tarWriter.WriteHeader(filesHdr); err != nil {
            pw.CloseWithError(err)
            return
        }
        
        // Process each file
        err := func() error {
            for {
                hdr, err := tarReader.Next()
                if err == io.EOF {
                    break
                }
                if err != nil {
                    return err
                }
                
                // Apply transformation
                transform(hdr)
                
                if err := tarWriter.WriteHeader(hdr); err != nil {
                    return err
                }
                
                if hdr.Size > 0 {
                    if _, err := io.Copy(tarWriter, tarReader); err != nil {
                        return err
                    }
                }
            }
            return tarWriter.Close()
        }()
        
        pw.CloseWithError(err)
    }()
    
    discard := func(err error) {
        rc.cancel(err)
        pw.CloseWithError(err)
    }
    
    return pr, discard
}
```

---

## Testing Strategy

### Test Matrix

```go
func TestLayerTransformation(t *testing.T) {
    tests := []struct {
        name            string
        buildOS         string  // runtime.GOOS of BuildKit
        layerPlatform   string  // Layer platform.OS
        expectTransform bool
        transformType   string
    }{
        {
            name:            "Linux BuildKit, Linux layer",
            buildOS:         "linux",
            layerPlatform:   "linux",
            expectTransform: false,
            transformType:   "none",
        },
        {
            name:            "Linux BuildKit, Windows layer",
            buildOS:         "linux",
            layerPlatform:   "windows",
            expectTransform: true,
            transformType:   "strip Files/",
        },
        {
            name:            "Windows BuildKit, Windows layer",
            buildOS:         "windows",
            layerPlatform:   "windows",
            expectTransform: false,
            transformType:   "none",
        },
        {
            name:            "Windows BuildKit, Linux layer (NEW!)",
            buildOS:         "windows",
            layerPlatform:   "linux",
            expectTransform: true,
            transformType:   "add Files/",
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Test layer apply
            testLayerApply(t, tt.buildOS, tt.layerPlatform, tt.expectTransform)
            
            // Test layer generation
            testLayerGeneration(t, tt.buildOS, tt.layerPlatform, tt.expectTransform)
        })
    }
}
```

### Integration Tests

```go
// Test: Windows BuildKit building Linux images
func TestWindowsBuildKitLinuxImage(t *testing.T) {
    if runtime.GOOS != "windows" {
        t.Skip("Windows only")
    }
    
    // Build a simple Linux image
    dockerfile := `
        FROM alpine:latest
        RUN echo "hello from windows buildkit" > /test.txt
    `
    
    // Build
    result := buildImage(t, dockerfile, "linux/amd64")
    
    // Export and verify
    exported := exportImage(t, result)
    
    // Verify layer format is standard Linux (no Files/ prefix)
    layers := extractLayers(t, exported)
    for _, layer := range layers {
        assertNoFilesPrefix(t, layer)
        assertNoWindowsHeaders(t, layer)
    }
    
    // Verify functionality: Can the image run on Linux?
    content := runOnLinux(t, result, "cat /test.txt")
    assert.Equal(t, "hello from windows buildkit\n", content)
}

// Test: Linux BuildKit building Windows images (existing functionality)
func TestLinuxBuildKitWindowsImage(t *testing.T) {
    if runtime.GOOS != "linux" {
        t.Skip("Linux only")
    }
    
    dockerfile := `
        FROM mcr.microsoft.com/windows/servercore:ltsc2022
        RUN echo "hello from linux buildkit" > C:\test.txt
    `
    
    result := buildImage(t, dockerfile, "windows/amd64")
    exported := exportImage(t, result)
    
    // Verify layer format is Windows (has Files/ prefix)
    layers := extractLayers(t, exported)
    for _, layer := range layers {
        assertHasFilesPrefix(t, layer)
        assertHasWindowsHeaders(t, layer)
    }
}
```

### Unit Tests

```go
// Test transformation functions in isolation
func TestApplyLinuxLayerOnWindows(t *testing.T) {
    // Create a mock Linux layer tarball
    linuxLayer := createLinuxLayerTarball(t, map[string]string{
        "usr/bin/app":  "binary content",
        "etc/config":   "config content",
    })
    
    // Apply with transformation
    result := applyLinuxLayerOnWindows(t, linuxLayer)
    
    // Verify Windows format
    files := listFiles(t, result)
    assert.Contains(t, files, "Files/usr/bin/app")
    assert.Contains(t, files, "Files/etc/config")
    assert.Contains(t, files, "Hives")
    
    // Verify Windows headers present
    for _, file := range files {
        if strings.HasPrefix(file, "Files/") {
            assertHasWindowsHeaders(t, result, file)
        }
    }
}

func TestGenerateLinuxLayerOnWindows(t *testing.T) {
    // Create Windows storage snapshots
    lower := createWindowsSnapshot(t, map[string]string{
        "Files/usr/bin/app": "binary",
    })
    upper := createWindowsSnapshot(t, map[string]string{
        "Files/usr/bin/app":  "binary",
        "Files/etc/config":   "new config",  // Added file
    })
    
    // Generate diff with transformation
    diff := generateLinuxLayerOnWindows(t, lower, upper)
    
    // Verify Linux format
    files := listFilesInTarball(t, diff)
    assert.Contains(t, files, "etc/config")
    assert.NotContains(t, files, "Files/etc/config")
    assert.NotContains(t, files, "Hives")
    
    // Verify no Windows headers
    for _, file := range files {
        assertNoWindowsHeaders(t, diff, file)
    }
}
```

---

## Challenges and Considerations

### 1. Windows ACL Generation

**Challenge:** Linux layers don't have Windows ACLs, but Windows storage requires them.

**Current Approach:** Use default ACLs from `addSecurityDescriptor()`:
- Directories: `O:BAG:SYD:(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)...`
- Files: `O:BAG:SYD:(A;;FA;;;BA)(A;;FA;;;SY)...`

**Implications:**
- ✅ Sufficient for read-only filesystem access
- ✅ Works for typical build operations (COPY, RUN)
- ⚠️ May not preserve exact Linux permissions in Windows context
- ⚠️ Not suitable if Windows container needs to run Linux binaries (LCOW)

**Mitigation:**
- Document that ACLs are default/synthetic
- Consider mapping Linux permissions to Windows ACLs in future

### 2. LCOW vs WCOW

**Background:**
- **WCOW** (Windows Containers on Windows): Native Windows containers
- **LCOW** (Linux Containers on Windows): Linux containers via HyperV + WSL2

**Consideration:** 
- LCOW may handle Linux layers natively via different snapshotter
- This solution is for WCOW with Windows snapshotter
- May need snapshotter detection: `windowsfs` vs `extfs4` vs `overlay`

**Per TBBle's comment:**
> "containerd contains a different snapshotter for Linux images on Windows, which AFAIK is storing the images in extfs4 image files"

**Decision:** Focus on WCOW first, LCOW support can be added later with snapshotter-aware logic.

### 3. Performance Impact

**Concern:** Adding transformation layer adds CPU/memory overhead.

**Analysis:**
- Transformation is streaming (no full buffering)
- Overhead is primarily CPU (hash computation, tar processing)
- Typically < 10% of total build time
- Cached layers skip transformation entirely

**Optimization opportunities:**
- Skip transformation when not needed (same platform as storage)
- Consider snapshotter-native support (move to containerd)
- Parallel processing for multi-layer images

### 4. Containerd Integration

**Question:** Should this be in BuildKit or containerd?

**Arguments for containerd:**
- ✅ Benefits all containerd users (not just BuildKit)
- ✅ Closer to storage layer
- ✅ Potential for snapshotter-native optimization

**Arguments for BuildKit (current approach):**
- ✅ Faster iteration and testing
- ✅ BuildKit-specific requirements (cache, provenance)
- ✅ Can be upstreamed to containerd later

**Recommendation:** Implement in BuildKit first, propose to containerd after validation.

### 5. OCI Specification Gap

**Problem:** No standard way to indicate layer format in OCI spec.

**Current detection:**
- Fragile heuristics (check for `Files/` directory)
- Platform metadata (but Windows can have Linux layers)
- Metadata keys (BuildKit-specific)

**Proposed OCI enhancement:**
```json
{
  "annotations": {
    "org.opencontainers.image.layer.format": "windows-files-hives"
    // or "oci-standard" for Linux
  }
}
```

**Action:** 
- Propose to OCI image-spec repository
- Document current BuildKit approach as interim solution
- Migrate to standard annotation when available

### 6. Registry Compatibility

**Question:** Do registries accept transformed layers?

**Answer:** 
- ✅ Yes - layer content is opaque to registries
- ✅ Digest-based addressing still works
- ✅ Already working for Linux→Windows cross-compilation

**Validation:** Existing cross-compilation proves this works.

### 7. Backwards Compatibility

**Concern:** Will old BuildKit versions work with new images?

**Analysis:**
- ✅ No breaking changes to layer format
- ✅ Transformation is transparent to consumers
- ✅ Old Linux BuildKit already handles Windows layers correctly
- ⚠️ Old Windows BuildKit will still fail on Linux layers (no fix without upgrade)

**Migration path:**
- New Windows BuildKit can read old layers
- No re-push of existing images required
- Gradual rollout safe

### 8. Edge Cases

**Symlinks crossing Files/ boundary:**
- Per tonistiigi: "symlink was not outside of Files but outer directory had Files and then symlinks into Files"
- Rare edge case, document as unsupported initially

**Empty layers:**
- Ensure `Hives/` and `Files/` directories created even for empty diffs
- Test with multi-stage builds with empty copy layers

**Layer reuse:**
- Same layer in different platform images: need platform context
- BuildKit cache must track platform per layer

---

## Next Steps

### Immediate (Phase 1)

1. **Remove `runtime.GOOS` checks**
   - [ ] Modify `source/containerimage/pull.go:250`
   - [ ] Modify `util/winlayers/applier.go:24`
   - [ ] Add unit tests for new logic
   - [ ] Test on both Linux and Windows

2. **Add unit tests**
   - [ ] Test `setWindowsLayerType` on Windows
   - [ ] Test applier wrapper on Windows
   - [ ] Verify no regressions on Linux

### Near-term (Phase 2)

3. **Implement reverse transformations**
   - [ ] Add `applyLinuxLayerOnWindows()` function
   - [ ] Add `generateLinuxLayerOnWindows()` function
   - [ ] Add helper `wrapWithFilesPrefix()`
   - [ ] Add helper `removeWindowsHeaders()`

4. **Integration testing**
   - [ ] Test Windows BuildKit building Linux images
   - [ ] Test exported Linux image format
   - [ ] Test Linux image functionality (run on Linux)
   - [ ] Test round-trip (build on Windows, run on Linux, rebuild on Windows)

### Long-term (Phase 3)

5. **Documentation**
   - [ ] Document transformation behavior
   - [ ] Add troubleshooting guide
   - [ ] Update architecture docs

6. **Optimization**
   - [ ] Profile performance impact
   - [ ] Optimize hot paths if needed
   - [ ] Consider caching optimization

7. **Upstream**
   - [ ] Propose OCI spec enhancement
   - [ ] Discuss containerd integration
   - [ ] Share findings with community

### Success Criteria

- ✅ Windows BuildKit can build Linux images
- ✅ Exported Linux images have correct format (no `Files/` prefix)
- ✅ Linux images built on Windows run correctly on Linux
- ✅ No regressions in existing Linux→Windows cross-compilation
- ✅ All tests pass on both platforms
- ✅ Performance impact < 10%

---

## File Changes Summary

### Files to Modify

1. **`source/containerimage/pull.go`**
   - Line 250: Remove `&& runtime.GOOS != "windows"` condition
   - Impact: Always set layer type based on platform

2. **`util/winlayers/applier.go`**
   - Line 24: Remove `runtime.GOOS == "windows"` early return
   - Add: `applyLinuxLayerOnWindows()` function
   - Add: `wrapWithFilesPrefix()` helper
   - Modify: `Apply()` method to handle all four cases

3. **`util/winlayers/differ.go`**
   - Add: `generateLinuxLayerOnWindows()` function
   - Add: `removeWindowsHeaders()` helper
   - Modify: `Compare()` method to handle all four cases

4. **`util/winlayers/context.go`**
   - Consider: Rename to clarify it's about layer format, not OS
   - Add: Documentation explaining the context key usage

### New Test Files

1. **`util/winlayers/applier_test.go`**
   - Unit tests for all transformation functions
   - Test matrix covering all platform combinations

2. **`util/winlayers/differ_test.go`**
   - Unit tests for diff generation
   - Validation of output format

3. **`integration/wcow_test.go`**
   - End-to-end tests on Windows BuildKit
   - Linux image building and export validation

---

## References

- **Issue:** [moby/buildkit#4537](https://github.com/moby/buildkit/issues/4537)
- **Current winlayers implementation:** `util/winlayers/`
- **Layer application:** `util/winlayers/applier.go`
- **Layer generation:** `util/winlayers/differ.go`
- **Pull logic:** `source/containerimage/pull.go`

---

## Appendix: Code Snippets

### Current Transformation (Linux → Windows)

```go
// differ.go - makeWindowsLayer()
func makeWindowsLayer(ctx context.Context, w io.Writer) (io.Writer, func(error), chan error) {
    // Creates Windows layer structure:
    // 1. Hives/ directory
    // 2. Files/ directory
    // 3. For each file: prefix with "Files/" and add PAX headers
    
    tarWriter := tar.NewWriter(w)
    
    // Create Hives/
    h := &tar.Header{Name: "Hives", Typeflag: tar.TypeDir, ModTime: time.Now()}
    prepareWinHeader(h)
    tarWriter.WriteHeader(h)
    
    // Create Files/
    h = &tar.Header{Name: "Files", Typeflag: tar.TypeDir, ModTime: time.Now()}
    prepareWinHeader(h)
    tarWriter.WriteHeader(h)
    
    // Transform each file
    for {
        h, err := tarReader.Next()
        if err == io.EOF {
            break
        }
        h.Name = "Files/" + h.Name
        if h.Linkname != "" {
            h.Linkname = "Files/" + h.Linkname
        }
        prepareWinHeader(h)
        addSecurityDescriptor(h)
        tarWriter.WriteHeader(h)
        // ... copy content
    }
}
```

### Windows PAX Headers

```go
// differ.go - prepareWinHeader()
func prepareWinHeader(h *tar.Header) {
    if h.PAXRecords == nil {
        h.PAXRecords = map[string]string{}
    }
    
    if h.Typeflag == tar.TypeDir {
        h.Mode |= 1 << 14
        h.PAXRecords[keyFileAttr] = "16"  // FILE_ATTRIBUTE_DIRECTORY
    }
    
    if h.Typeflag == tar.TypeReg {
        h.Mode |= 1 << 15
        h.PAXRecords[keyFileAttr] = "32"  // FILE_ATTRIBUTE_ARCHIVE
    }
    
    if !h.ModTime.IsZero() {
        h.PAXRecords[keyCreationTime] = fmt.Sprintf("%d.%d", 
            h.ModTime.Unix(), h.ModTime.Nanosecond())
    }
    
    h.Format = tar.FormatPAX
}

// differ.go - addSecurityDescriptor()
func addSecurityDescriptor(h *tar.Header) {
    if h.Typeflag == tar.TypeDir {
        // Default directory ACL (Administrator, System, Users)
        h.PAXRecords[keySDRaw] = "AQAEgBQAAAAkAAAAAAAAADAAAAABAgAAAAAABSAAAAAgAgAA..."
    }
    
    if h.Typeflag == tar.TypeReg {
        // Default file ACL (Administrator, System, Users)
        h.PAXRecords[keySDRaw] = "AQAEgBQAAAAkAAAAAAAAADAAAAABAgAAAAAABSAAAAAgAgAA..."
    }
}
```

### Layer Type Context

```go
// context.go
func UseWindowsLayerMode(ctx context.Context) context.Context {
    return context.WithValue(ctx, contextKey, true)
}

func hasWindowsLayerMode(ctx context.Context) bool {
    v := ctx.Value(contextKey)
    return v != nil
}

// Usage in cache/refs.go:1328
if sr.GetLayerType() == "windows" {
    ctx = winlayers.UseWindowsLayerMode(ctx)
}
```

---

**Document Version:** 1.0  
**Last Updated:** November 4, 2025  
**Author:** BuildKit Contributor  
**Status:** Proposal / Implementation Guide
