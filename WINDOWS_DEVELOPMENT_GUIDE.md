# BuildKit Windows Development Guide# BuildKit Windows Development Guide



Welcome to BuildKit Windows development! This guide is designed for new maintainers taking over Windows-specific development responsibilities.Welcome to BuildKit Windows development! This guide is designed for new maintainers taking over Windows-specific development responsibilities.



## Table of Contents## Table of Contents



- [Essential Knowledge Areas](#essential-knowledge-areas)- [Essential Knowledge Areas](#essential-knowledge-areas)

- [Learning Path](#learning-path)- [Learning Path](#learning-path)

- [Development Environment Setup](#development-environment-setup)- [Development Environment Setup](#development-environment-setup)

- [Common Windows BuildKit Patterns](#common-windows-buildkit-patterns)- [Common Windows BuildKit Patterns](#common-windows-buildkit-patterns)

- [Key Metrics to Understand](#key-metrics-to-understand)- [Key Metrics to Understand](#key-metrics-to-understand)

- [Community and Resources](#community-and-resources)- [Community and Resources](#community-and-resources)

- [Suggested First Tasks](#suggested-first-tasks)- [Suggested First Tasks](#suggested-first-tasks)

- [Debugging Tips](#debugging-tips)- [Debugging Tips](#debugging-tips)



------



## Essential Knowledge Areas## Essential Knowledge Areas



### 1. Windows Container Architecture (CRITICAL)### 1. Windows Container Architecture (CRITICAL)



#### Why Windows is Different from Linux#### Why Windows is Different from Linux



**Linux Containers:****Linux Containers:**

- Use kernel namespaces and cgroups

- Use kernel namespaces and cgroups- Overlay filesystem (overlayfs) for layering

- Overlay filesystem (overlayfs) for layering- Direct kernel integration

- Direct kernel integration- Lightweight process isolation

- Lightweight process isolation

**Windows Containers:**

**Windows Containers:**- Managed through **HCS (Host Compute Service)**

- Layer storage uses **VHD (Virtual Hard Disk) files**

- Managed through **HCS (Host Compute Service)**- No OverlayFS equivalent - layers merged at HCS level

- Layer storage uses **VHD (Virtual Hard Disk) files**- Security via Windows access control (SIDs, ACLs)

- No OverlayFS equivalent - layers merged at HCS level

- Security via Windows access control (SIDs, ACLs)#### Key Concepts



#### Key Concepts| Concept | Linux | Windows |

|---------|-------|---------|

| Concept | Linux | Windows || Layer Storage | Directories | VHD files |

|---------|-------|---------|| Layer Merging | Kernel overlayfs | HCS service |

| Layer Storage | Directories | VHD files || Mount Type | `overlay` with `lowerdir` | Single composed mount |

| Layer Merging | Kernel overlayfs | HCS service || Permissions | Unix (uid/gid/mode) | ACLs and SIDs |

| Mount Type | `overlay` with `lowerdir` | Single composed mount || Container Runtime | runc/crun | runhcs |

| Permissions | Unix (uid/gid/mode) | ACLs and SIDs |

| Container Runtime | runc/crun | runhcs |#### Essential Resources



#### Essential Resources- [Microsoft HCS Documentation](https://github.com/microsoft/hcsshim)

- [Windows Container Internals](https://docs.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/container-base-images)

- [Microsoft HCS Documentation](https://github.com/microsoft/hcsshim)- Study `vendor/github.com/Microsoft/hcsshim/` in this repository

- [Windows Container Internals](https://docs.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/container-base-images)- [Windows Container Networking](https://docs.microsoft.com/en-us/virtualization/windowscontainers/container-networking/architecture)

- Study `vendor/github.com/Microsoft/hcsshim/` in this repository

- [Windows Container Networking](https://docs.microsoft.com/en-us/virtualization/windowscontainers/container-networking/architecture)### 2. BuildKit Core Concepts



### 2. BuildKit Core Concepts#### Architecture Overview



#### Architecture Overview```

┌──────────────────────────────────────────────────┐

```text│ Client Layer (buildctl, Docker CLI, API clients) │

┌─────────────────────────────────────────────────────┐└───────────────────┬──────────────────────────────┘

│  Client Layer (buildctl, Docker CLI, API clients)  │                    │

└────────────────────┬────────────────────────────────┘┌───────────────────▼──────────────────────────────┐

                     ││ Frontend (Dockerfile → LLB, Gateway)             │

┌────────────────────▼────────────────────────────────┐│ - Parses Dockerfile                              │

│  Frontend (Dockerfile → LLB, Gateway)               ││ - Generates LLB (Low-Level Build) graph          │

│  - Parses Dockerfile                                │└───────────────────┬──────────────────────────────┘

│  - Generates LLB (Low-Level Build) graph           │                    │

└────────────────────┬────────────────────────────────┘┌───────────────────▼──────────────────────────────┐

                     ││ Solver (Dependency Resolution & Caching)         │

┌────────────────────▼────────────────────────────────┐│ - Resolves build graph                           │

│  Solver (Dependency Resolution & Caching)           ││ - Manages cache                                  │

│  - Resolves build graph                             ││ - Schedules operations                           │

│  - Manages cache                                    │└───────────────────┬──────────────────────────────┘

│  - Schedules operations                             │                    │

└────────────────────┬────────────────────────────────┘┌───────────────────▼──────────────────────────────┐

                     ││ Worker (Executor + Snapshotter + Differ)         │

┌────────────────────▼────────────────────────────────┐│ - containerd worker                              │

│  Worker (Executor + Snapshotter + Differ)           ││ - runc/OCI worker                                │

│  - containerd worker                                │└───────────────────┬──────────────────────────────┘

│  - runc/OCI worker                                  │                    │

└────────────────────┬────────────────────────────────┘        ┌───────────┴───────────┐

                     │        │                       │

         ┌───────────┴───────────┐   ┌────▼─────┐          ┌──────▼──────┐

         │                       │   │ Executor │          │ Snapshotter │

    ┌────▼──────┐         ┌──────▼───────┐   │ (runhcs) │          │ (Windows)   │

    │ Executor  │         │ Snapshotter  │   └──────────┘          └─────────────┘

    │ (runhcs)  │         │ (Windows)    │```

    └───────────┘         └──────────────┘

```#### Key Components



#### Key Components**Frontend:**

- Parses build definitions (Dockerfile, etc.)

**Frontend:**- Converts to LLB (Low-Level Build) graph

- Location: `frontend/dockerfile/`, `frontend/gateway/`

- Parses build definitions (Dockerfile, etc.)

- Converts to LLB (Low-Level Build) graph**Solver:**

- Location: `frontend/dockerfile/`, `frontend/gateway/`- Resolves build dependencies

- Manages distributed caching

**Solver:**- Handles concurrent execution

- Location: `solver/`

- Resolves build dependencies

- Manages distributed caching**Cache:**

- Handles concurrent execution- Manages snapshots and blobs

- Location: `solver/`- Handles content-addressable storage

- Location: `cache/`

**Cache:**

**Worker:**

- Manages snapshots and blobs- Executes build operations

- Handles content-addressable storage- Manages container lifecycle

- Location: `cache/`- Location: `worker/containerd/`, `worker/runc/`



**Worker:****Executor:**

- Runs containers (via containerd/runhcs)

- Executes build operations- Manages container processes

- Manages container lifecycle- Location: `executor/`

- Location: `worker/containerd/`, `worker/runc/`

**Snapshotter:**

**Executor:**- Manages filesystem layers

- Creates and manages snapshots

- Runs containers (via containerd/runhcs)- Location: `snapshot/`

- Manages container processes

- Location: `executor/`### 3. Windows-Specific Code Paths



**Snapshotter:**#### Critical Files to Master



- Manages filesystem layers```

- Creates and manages snapshotsbuildkit/

- Location: `snapshot/`│

├── util/windows/

### 3. Windows-Specific Code Paths│   ├── util_windows.go          # Windows utilities, SID resolution

│   └── ...

#### Critical Files to Master│

├── util/winlayers/

```text│   ├── differ.go                # Windows layer diff computation

buildkit/│   ├── applier.go               # Apply layers with Windows metadata

││   ├── apply.go                 # Layer application logic

├── util/windows/│   ├── apply_nydus.go           # Nydus support

│   ├── util_windows.go          # Windows utilities, SID resolution│   └── context.go               # Windows layer mode context

│   └── ...│

│├── cache/

├── util/winlayers/│   ├── blobs.go                 # Blob/layer management (has Windows checks)

│   ├── differ.go                # Windows layer diff computation│   └── blobs_windows.go         # Windows-specific blob handling

│   ├── applier.go               # Apply layers with Windows metadata│

│   ├── apply.go                 # Layer application logic├── worker/

│   ├── apply_nydus.go           # Nydus support│   ├── containerd/

│   └── context.go               # Windows layer mode context│   │   └── containerd.go        # Containerd worker (uses winlayers)

││   └── runc/

├── cache/│       └── runc.go              # runc worker (uses winlayers)

│   ├── blobs.go                 # Blob/layer management (has Windows checks)│

│   └── blobs_windows.go         # Windows-specific blob handling├── executor/

││   ├── oci/

├── worker/│   │   └── spec_windows.go      # Windows OCI spec generation

│   ├── containerd/│   └── resources/               # Resource management

│   │   └── containerd.go        # Containerd worker (uses winlayers)│

│   └── runc/├── snapshot/

│       └── runc.go              # runc worker (uses winlayers)│   └── ...                      # Cross-platform snapshot handling

││

├── executor/└── vendor/

│   ├── oci/    └── github.com/

│   │   └── spec_windows.go      # Windows OCI spec generation        ├── Microsoft/hcsshim/   # Windows container interface

│   └── resources/               # Resource management        └── containerd/

│            └── containerd/      # Container runtime

├── snapshot/```

│   └── ...                      # Cross-platform snapshot handling

│#### Key Windows Code Patterns

└── vendor/

    └── github.com/**1. Platform Detection:**

        ├── Microsoft/hcsshim/   # Windows container interface

        └── containerd/```go

            └── containerd/      # Container runtime//go:build windows

```// File only compiled on Windows



#### Key Windows Code Patterns//go:build !windows

// File excluded on Windows

**1. Platform Detection:**

// Runtime check

```goif runtime.GOOS == "windows" {

//go:build windows    // Windows-specific code

// File only compiled on Windows}

```

//go:build !windows

// File excluded on Windows**2. Windows Layer Mode:**



// Runtime check```go

if runtime.GOOS == "windows" {// Context key for Windows layer handling

    // Windows-specific codefunc hasWindowsLayerMode(ctx context.Context) bool {

}    // Check if Windows layer processing is needed

```}



**2. Windows Layer Mode:**// Enable Windows mode

ctx = winlayers.WithWindowsLayerMode(ctx)

```go```

// Context key for Windows layer handling

func hasWindowsLayerMode(ctx context.Context) bool {**3. Mount Validation:**

    // Check if Windows layer processing is needed

}```go

// Windows requires exactly 1 mount

// Enable Windows modeif len(mounts) != 1 {

ctx = winlayers.WithWindowsLayerMode(ctx)    return errors.Errorf("Windows requires exactly 1 mount, got %d", len(mounts))

```}

```

**3. Mount Validation:**

---

```go

// Windows requires exactly 1 mount## Learning Path

if len(mounts) != 1 {

    return errors.Errorf("Windows requires exactly 1 mount, got %d", len(mounts))### Phase 1: Foundation (Week 1-2)

}

```#### Day 1-2: Project Overview



---1. **Read core documentation:**

   ```bash

## Learning Path   cat README.md

   cat PROJECT.md

### Phase 1: Foundation (Week 1-2)   cat docs/*.md

   ```

#### Day 1-2: Project Overview

2. **Understand the architecture:**

1. **Read core documentation:**   - Review the architecture diagram above

   - Read `docs/dev/architecture.md` (if exists)

   ```bash   - Browse through main directories

   cat README.md

   cat PROJECT.md3. **Set up development environment** (see below)

   cat docs/*.md

   ```#### Day 3-5: Simple Build Trace



2. **Understand the architecture:**1. **Run a simple build with debug output:**

   - Review the architecture diagram above   ```powershell

   - Read `docs/dev/architecture.md` (if exists)   $env:BUILDKIT_DEBUG="1"

   - Browse through main directories   buildkitd.exe --debug

   ```

3. **Set up development environment** (see below)

2. **Trace a Dockerfile build:**

#### Day 3-5: Simple Build Trace   ```dockerfile

   # test.Dockerfile

1. **Run a simple build with debug output:**   FROM mcr.microsoft.com/windows/nanoserver:ltsc2022

   RUN echo "Hello Windows"

   ```powershell   ```

   $env:BUILDKIT_DEBUG="1"

   buildkitd.exe --debug3. **Follow the logs:**

   ```   - Watch how the frontend parses the Dockerfile

   - See solver resolve dependencies

2. **Trace a Dockerfile build:**   - Observe worker execute RUN command

   - Notice snapshot creation

   ```dockerfile

   # test.Dockerfile#### Day 6-10: Code Reading

   FROM mcr.microsoft.com/windows/nanoserver:ltsc2022

   RUN echo "Hello Windows"**Read in this order:**

   ```

1. `client/client.go` - Understand client API

3. **Follow the logs:**2. `solver/solver.go` - See how builds are solved

   - Watch how the frontend parses the Dockerfile3. `cache/manager.go` - Learn cache management

   - See solver resolve dependencies4. `worker/containerd/containerd.go` - Worker implementation

   - Observe worker execute RUN command5. `executor/oci/spec_windows.go` - Windows OCI spec

   - Notice snapshot creation

### Phase 2: Windows Specifics (Week 3-4)

#### Day 6-10: Code Reading

#### Week 3: Windows Layer Handling

**Read in this order:**

**Study these files sequentially:**

1. `client/client.go` - Understand client API

2. `solver/solver.go` - See how builds are solved1. **`util/winlayers/context.go`**

3. `cache/manager.go` - Learn cache management   - How Windows layer mode is enabled/disabled

4. `worker/containerd/containerd.go` - Worker implementation   - Context key management

5. `executor/oci/spec_windows.go` - Windows OCI spec

2. **`util/winlayers/differ.go`**

### Phase 2: Windows Specifics (Week 3-4)   - How diffs between layers are computed

   - `Compare()` method for Windows layers

#### Week 3: Windows Layer Handling   - TAR format with Windows metadata



**Study these files sequentially:**3. **`util/winlayers/applier.go`**

   - How layers are applied to snapshots

1. **`util/winlayers/context.go`**   - `Apply()` method

   - How Windows layer mode is enabled/disabled   - Filtering Windows-specific TAR entries

   - Context key management

4. **`util/windows/util_windows.go`**

2. **`util/winlayers/differ.go`**   - SID (Security Identifier) resolution

   - How diffs between layers are computed   - User account lookups in containers

   - `Compare()` method for Windows layers   - Windows-specific utilities

   - TAR format with Windows metadata

#### Week 4: Integration Understanding

3. **`util/winlayers/applier.go`**

   - How layers are applied to snapshots1. **Trace a Windows build end-to-end:**

   - `Apply()` method   - Set breakpoints in key functions

   - Filtering Windows-specific TAR entries   - Step through a build operation

   - Watch layer creation and caching

4. **`util/windows/util_windows.go`**

   - SID (Security Identifier) resolution2. **Study HCS integration:**

   - User account lookups in containers   ```bash

   - Windows-specific utilities   # Read vendor code (read-only)

   vendor/github.com/Microsoft/hcsshim/

#### Week 4: Integration Understanding   vendor/github.com/containerd/containerd/v2/core/snapshots/

   ```

1. **Trace a Windows build end-to-end:**

   - Set breakpoints in key functions3. **Understand the current test failure:**

   - Step through a build operation   - Read `client/client_test.go` lines 2648-2747

   - Watch layer creation and caching   - Understand `testSessionExporter`

   - Trace why "number of mounts should always be 1" fails

2. **Study HCS integration:**

### Phase 3: Hands-On Development (Week 5+)

   ```bash

   # Read vendor code (read-only)#### Week 5: First Bug Fix

   vendor/github.com/Microsoft/hcsshim/

   vendor/github.com/containerd/containerd/v2/core/snapshots/**Current Issue: TestSessionExporter**

   ```

1. **Add diagnostic logging:**

3. **Understand the current test failure:**   ```go

   - Read `client/client_test.go` lines 2648-2747   // In cache/blobs.go around line 135

   - Understand `testSessionExporter`   bklog.G(ctx).Debugf("WINDOWS_DEBUG: lower mounts: %+v", lower)

   - Trace why "number of mounts should always be 1" fails   bklog.G(ctx).Debugf("WINDOWS_DEBUG: upper mounts: %+v", upper)

   ```

### Phase 3: Hands-On Development (Week 5+)

2. **Run the test:**

#### Week 5: First Bug Fix   ```powershell

   gotestsum --format testname -- ./client -v -run "TestIntegration/.*TestSessionExporter$" -timeout 5m

**Current Issue: TestSessionExporter**   ```



1. **Add diagnostic logging:**3. **Analyze the output:**

   - How many mounts are being created?

   ```go   - Where do they come from?

   // In cache/blobs.go around line 135   - Why is the Windows snapshotter returning multiple mounts?

   bklog.G(ctx).Debugf("WINDOWS_DEBUG: lower mounts: %+v", lower)

   bklog.G(ctx).Debugf("WINDOWS_DEBUG: upper mounts: %+v", upper)4. **Research the solution:**

   ```   - Check if it's a bug in snapshotter

   - See if export logic needs Windows-specific handling

2. **Run the test:**   - Compare with Linux overlay export



   ```powershell#### Week 6: Test Suite Familiarity

   gotestsum --format testname -- ./client -v -run "TestIntegration/.*TestSessionExporter$" -timeout 5m

   ```1. **Run all integration tests:**

   ```powershell

3. **Analyze the output:**   gotestsum --format testname -- ./... -v

   - How many mounts are being created?   ```

   - Where do they come from?

   - Why is the Windows snapshotter returning multiple mounts?2. **Categorize failures:**

   - Known Windows limitations

4. **Research the solution:**   - Bugs to fix

   - Check if it's a bug in snapshotter   - Tests that need Windows-specific variants

   - See if export logic needs Windows-specific handling

   - Compare with Linux overlay export3. **Pick an easy test to fix:**

   - Start with skipped tests

#### Week 6: Test Suite Familiarity   - Re-enable after fixing



1. **Run all integration tests:**#### Week 7+: Ongoing Development



   ```powershell1. **Review recent Windows PRs:**

   gotestsum --format testname -- ./... -v   ```bash

   ```   git log --all --grep="windows" --oneline

   git log --all --grep="Windows" --oneline

2. **Categorize failures:**   ```

   - Known Windows limitations

   - Bugs to fix2. **Check Windows-related issues:**

   - Tests that need Windows-specific variants   - GitHub issues labeled `platform/windows`

   - Issues mentioning HCS, winlayers, etc.

3. **Pick an easy test to fix:**

   - Start with skipped tests3. **Plan improvements:**

   - Re-enable after fixing   - Performance optimizations

   - Missing features

#### Week 7+: Ongoing Development   - Better error messages



1. **Review recent Windows PRs:**---



   ```bash## Development Environment Setup

   git log --all --grep="windows" --oneline

   git log --all --grep="Windows" --oneline### Required Tools

   ```

#### Core Development Tools

2. **Check Windows-related issues:**

   - GitHub issues labeled `platform/windows````powershell

   - Issues mentioning HCS, winlayers, etc.# Package manager

winget install Microsoft.VisualStudioCode

3. **Plan improvements:**winget install Git.Git

   - Performance optimizationswinget install GoLang.Go

   - Missing features

   - Better error messages# Verify installations

git --version

---go version

code --version

## Development Environment Setup```



### Required Tools#### Windows Container Tools



#### Core Development Tools**Option 1: Docker Desktop (Easiest)**

```powershell

```powershellwinget install Docker.DockerDesktop

# Package manager# After installation, switch to Windows containers

winget install Microsoft.VisualStudioCode# Right-click Docker tray icon → "Switch to Windows containers..."

winget install Git.Git```

winget install GoLang.Go

**Option 2: Containerd (Direct)**

# Verify installations```powershell

git --version# Download containerd for Windows

go version# https://github.com/containerd/containerd/releases

code --version# Extract and install as a service

``````



#### Windows Container Tools#### Testing Tools



**Option 1: Docker Desktop (Easiest)**```powershell

# Install gotestsum for better test output

```powershellgo install gotest.tools/gotestsum@latest

winget install Docker.DockerDesktop

# After installation, switch to Windows containers# Verify

# Right-click Docker tray icon → "Switch to Windows containers..."gotestsum --version

``````



**Option 2: Containerd (Direct)**### VS Code Setup



```powershell#### Recommended Extensions

# Download containerd for Windows

# https://github.com/containerd/containerd/releasesInstall via VS Code or command line:

# Extract and install as a service

``````powershell

code --install-extension golang.go

#### Testing Toolscode --install-extension ms-azuretools.vscode-docker

code --install-extension eamodio.gitlens

```powershellcode --install-extension ms-vscode.powershell

# Install gotestsum for better test output```

go install gotest.tools/gotestsum@latest

#### Workspace Settings

# Verify

gotestsum --versionCreate `.vscode/settings.json`:

```

```json

### VS Code Setup{

    "go.useLanguageServer": true,

#### Recommended Extensions    "go.lintTool": "golangci-lint",

    "go.lintOnSave": "workspace",

Install via VS Code or command line:    "go.buildTags": "windows",

    "go.testTimeout": "10m",

```powershell    "files.eol": "\n",

code --install-extension golang.go    "editor.formatOnSave": true,

code --install-extension ms-azuretools.vscode-docker    "[go]": {

code --install-extension eamodio.gitlens        "editor.defaultFormatter": "golang.go",

code --install-extension ms-vscode.powershell        "editor.codeActionsOnSave": {

```            "source.organizeImports": true

        }

#### Workspace Settings    }

}

Create `.vscode/settings.json`:```



```json#### Debug Configuration

{

    "go.useLanguageServer": true,Create `.vscode/launch.json`:

    "go.lintTool": "golangci-lint",

    "go.lintOnSave": "workspace",```json

    "go.buildTags": "windows",{

    "go.testTimeout": "10m",    "version": "0.2.0",

    "files.eol": "\n",    "configurations": [

    "editor.formatOnSave": true,        {

    "[go]": {            "name": "Debug Current Test",

        "editor.defaultFormatter": "golang.go",            "type": "go",

        "editor.codeActionsOnSave": {            "request": "launch",

            "source.organizeImports": true            "mode": "test",

        }            "program": "${fileDirname}",

    }            "args": [

}                "-test.v",

```                "-test.run",

                "${selectedText}"

#### Debug Configuration            ],

            "env": {

Create `.vscode/launch.json`:                "BUILDKIT_DEBUG": "1"

            },

```json            "showLog": true

{        },

    "version": "0.2.0",        {

    "configurations": [            "name": "Debug TestSessionExporter",

        {            "type": "go",

            "name": "Debug Current Test",            "request": "launch",

            "type": "go",            "mode": "test",

            "request": "launch",            "program": "${workspaceFolder}/client",

            "mode": "test",            "args": [

            "program": "${fileDirname}",                "-test.v",

            "args": [                "-test.run",

                "-test.v",                "TestIntegration/.*TestSessionExporter$",

                "-test.run",                "-test.timeout",

                "${selectedText}"                "5m"

            ],            ],

            "env": {            "env": {

                "BUILDKIT_DEBUG": "1"                "BUILDKIT_DEBUG": "1"

            },            },

            "showLog": true            "showLog": true

        },        },

        {        {

            "name": "Debug TestSessionExporter",            "name": "Debug buildkitd",

            "type": "go",            "type": "go",

            "request": "launch",            "request": "launch",

            "mode": "test",            "mode": "debug",

            "program": "${workspaceFolder}/client",            "program": "${workspaceFolder}/cmd/buildkitd",

            "args": [            "args": [

                "-test.v",                "--debug",

                "-test.run",                "--config",

                "TestIntegration/.*TestSessionExporter$",                "C:\\path\\to\\buildkitd.toml"

                "-test.timeout",            ],

                "5m"            "env": {

            ],                "BUILDKIT_DEBUG": "1"

            "env": {            }

                "BUILDKIT_DEBUG": "1"        }

            },    ]

            "showLog": true}

        },```

        {

            "name": "Debug buildkitd",### Building BuildKit

            "type": "go",

            "request": "launch",```powershell

            "mode": "debug",# Clone the repository (if not already done)

            "program": "${workspaceFolder}/cmd/buildkitd",git clone https://github.com/moby/buildkit.git

            "args": [cd buildkit

                "--debug",

                "--config",# Build buildkitd

                "C:\\path\\to\\buildkitd.toml"go build -o bin/buildkitd.exe ./cmd/buildkitd

            ],

            "env": {# Build buildctl

                "BUILDKIT_DEBUG": "1"go build -o bin/buildctl.exe ./cmd/buildctl

            }

        }# Run tests

    ]go test ./...

}

```# Or with gotestsum for better output

gotestsum --format testname -- ./...

### Building BuildKit```



```powershell### Running BuildKit

# Clone the repository (if not already done)

git clone https://github.com/moby/buildkit.git```powershell

cd buildkit# Start containerd (if using containerd worker)

containerd.exe --config C:\path\to\containerd-config.toml

# Build buildkitd

go build -o bin/buildkitd.exe ./cmd/buildkitd# Start buildkitd

.\bin\buildkitd.exe `

# Build buildctl    --debug `

go build -o bin/buildctl.exe ./cmd/buildctl    --containerd-worker=true `

    --containerd-worker-addr "npipe:////./pipe/containerd-containerd"

# Run tests

go test ./...# In another terminal, use buildctl

.\bin\buildctl.exe build `

# Or with gotestsum for better output    --frontend dockerfile.v0 `

gotestsum --format testname -- ./...    --local context=. `

```    --local dockerfile=.

```

### Running BuildKit

---

```powershell

# Start containerd (if using containerd worker)## Common Windows BuildKit Patterns

containerd.exe --config C:\path\to\containerd-config.toml

### 1. Build Tags and Conditional Compilation

# Start buildkitd

.\bin\buildkitd.exe ````go

    --debug `// File: util_windows.go

    --containerd-worker=true `//go:build windows

    --containerd-worker-addr "npipe:////./pipe/containerd-containerd"

package mypackage

# In another terminal, use buildctl

.\bin\buildctl.exe build `// This file is only compiled on Windows

    --frontend dockerfile.v0 `

    --local context=. `func WindowsSpecificFunction() {

    --local dockerfile=.    // Implementation

```}

```

---

```go

## Common Windows BuildKit Patterns// File: util_unix.go

//go:build !windows

### 1. Build Tags and Conditional Compilation

package mypackage

```go

// File: util_windows.go// This file is compiled on all platforms except Windows

//go:build windows

func WindowsSpecificFunction() {

package mypackage    panic("not implemented on this platform")

}

// This file is only compiled on Windows```



func WindowsSpecificFunction() {### 2. Runtime Platform Checks

    // Implementation

}```go

```import "runtime"



```gofunc ProcessMount(mounts []mount.Mount) error {

// File: util_unix.go    if runtime.GOOS == "windows" {

//go:build !windows        // Windows-specific handling

        if len(mounts) != 1 {

package mypackage            return errors.Errorf("Windows requires exactly 1 mount")

        }

// This file is compiled on all platforms except Windows        return processWindowsMount(mounts[0])

    }

func WindowsSpecificFunction() {    

    panic("not implemented on this platform")    // Linux/Unix handling

}    return processOverlayMount(mounts)

```}

```

### 2. Runtime Platform Checks

### 3. Windows Layer Mode Context

```go

import "runtime"```go

import "github.com/moby/buildkit/util/winlayers"

func ProcessMount(mounts []mount.Mount) error {

    if runtime.GOOS == "windows" {// Enable Windows layer mode

        // Windows-specific handlingctx = winlayers.WithWindowsLayerMode(ctx)

        if len(mounts) != 1 {

            return errors.Errorf("Windows requires exactly 1 mount")// Check if Windows layer mode is active

        }func (d *differ) Compare(ctx context.Context, lower, upper []mount.Mount) {

        return processWindowsMount(mounts[0])    if !winlayers.HasWindowsLayerMode(ctx) {

    }        // Use standard differ

            return d.standardDiffer.Compare(ctx, lower, upper)

    // Linux/Unix handling    }

    return processOverlayMount(mounts)    

}    // Use Windows-specific differ

```    return d.windowsDiffer.Compare(ctx, lower, upper)

}

### 3. Windows Layer Mode Context```



```go### 4. Windows Security (SIDs and ACLs)

import "github.com/moby/buildkit/util/winlayers"

```go

// Enable Windows layer mode// Resolve Windows username to SID

ctx = winlayers.WithWindowsLayerMode(ctx)sid, err := windows.ResolveUsernameToSID(ctx, exec, rootMount, "ContainerAdministrator")

if err != nil {

// Check if Windows layer mode is active    return err

func (d *differ) Compare(ctx context.Context, lower, upper []mount.Mount) {}

    if !winlayers.HasWindowsLayerMode(ctx) {

        // Use standard differ// Well-known Windows SIDs

        return d.standardDiffer.Compare(ctx, lower, upper)const (

    }    ContainerAdministratorSID = "S-1-5-93-2-1"

        ContainerUserSID          = "S-1-5-93-2-2"

    // Use Windows-specific differ)

    return d.windowsDiffer.Compare(ctx, lower, upper)```

}

```### 5. Windows Layer TAR Format



### 4. Windows Security (SIDs and ACLs)```go

// Windows layers have special structure:

```go// Hives/          - Registry hives (usually empty in practice)

// Resolve Windows username to SID// Files/          - Actual filesystem content

sid, err := windows.ResolveUsernameToSID(ctx, exec, rootMount, "ContainerAdministrator")//   Files/foo.txt

if err != nil {//   Files/bar/

    return err

}// PAX headers for Windows metadata:

// MSWINDOWS.fileattr  - File attributes (16=directory, 32=file)

// Well-known Windows SIDs// MSWINDOWS.rawsd     - Security descriptor (base64 encoded ACL)

const (// LIBARCHIVE.creationtime - Creation timestamp

    ContainerAdministratorSID = "S-1-5-93-2-1"```

    ContainerUserSID          = "S-1-5-93-2-2"

)### 6. Error Handling

```

```go

### 5. Windows Layer TAR Formatimport "github.com/containerd/errdefs"



```go// Use containerd error definitions

// Windows layers have special structure:if errdefs.IsNotFound(err) {

// Hives/          - Registry hives (usually empty in practice)    // Handle not found

// Files/          - Actual filesystem content}

//   Files/foo.txt

//   Files/bar/if errdefs.IsAlreadyExists(err) {

    // Handle already exists

// PAX headers for Windows metadata:}

// MSWINDOWS.fileattr  - File attributes (16=directory, 32=file)

// MSWINDOWS.rawsd     - Security descriptor (base64 encoded ACL)// Wrap errors with context

// LIBARCHIVE.creationtime - Creation timestampreturn errors.Wrapf(err, "failed to create snapshot %s", snapshotID)

``````



### 6. Error Handling### 7. Logging



```go```go

import "github.com/containerd/errdefs"import "github.com/moby/buildkit/util/bklog"



// Use containerd error definitions// Structured logging

if errdefs.IsNotFound(err) {bklog.G(ctx).WithFields(map[string]interface{}{

    // Handle not found    "snapshotID": snapshotID,

}    "mountCount": len(mounts),

}).Debug("creating snapshot")

if errdefs.IsAlreadyExists(err) {

    // Handle already exists// With error

}bklog.G(ctx).WithError(err).Error("failed to create snapshot")



// Wrap errors with context// Trace-level with stack

return errors.Wrapf(err, "failed to create snapshot %s", snapshotID)bklog.G(ctx).WithField("stack", bklog.TraceLevelOnlyStack()).

```    Trace("entering function")

```

### 7. Logging

---

```go

import "github.com/moby/buildkit/util/bklog"## Key Metrics to Understand



// Structured logging### Performance Characteristics

bklog.G(ctx).WithFields(map[string]interface{}{

    "snapshotID": snapshotID,| Metric | Linux | Windows | Notes |

    "mountCount": len(mounts),|--------|-------|---------|-------|

}).Debug("creating snapshot")| **Base Image Size** | ~5MB (alpine) | ~100MB (nanoserver) | Windows has larger base |

| **Layer Overhead** | Minimal (~4KB) | Significant (~10-20MB) | VHD overhead |

// With error| **Build Time** | Fast | Slower | HCS overhead |

bklog.G(ctx).WithError(err).Error("failed to create snapshot")| **Cache Hit Speed** | Very fast | Fast | Content-addressable helps both |

| **First-time Pull** | Fast | Slow | Large Windows images |

// Trace-level with stack

bklog.G(ctx).WithField("stack", bklog.TraceLevelOnlyStack()).### Windows-Specific Considerations

    Trace("entering function")

```1. **Image Compatibility:**

   - Windows containers must match host kernel version

---   - Example: ltsc2019, ltsc2022, ltsc2025

   - BuildKit must handle version mismatches gracefully

## Key Metrics to Understand

2. **Layer Limits:**

### Performance Characteristics   - Windows has a maximum layer limit (historically 127)

   - Modern versions support more but still limited

| Metric | Linux | Windows | Notes |   - BuildKit should optimize layer count

|--------|-------|---------|-------|

| **Base Image Size** | ~5MB (alpine) | ~100MB (nanoserver) | Windows has larger base |3. **Filesystem Differences:**

| **Layer Overhead** | Minimal (~4KB) | Significant (~10-20MB) | VHD overhead |   - Case-insensitive by default

| **Build Time** | Fast | Slower | HCS overhead |   - Different path separators (backslash)

| **Cache Hit Speed** | Very fast | Fast | Content-addressable helps both |   - No hard links in traditional sense

| **First-time Pull** | Fast | Slow | Large Windows images |   - Different permission model



### Windows-Specific Considerations4. **Resource Usage:**

   - Higher memory overhead per container

1. **Image Compatibility:**   - Longer container start times

   - Windows containers must match host kernel version   - More disk I/O for VHD operations

   - Example: ltsc2019, ltsc2022, ltsc2025

   - BuildKit must handle version mismatches gracefully---



2. **Layer Limits:**## Community and Resources

   - Windows has a maximum layer limit (historically 127)

   - Modern versions support more but still limited### Official Channels

   - BuildKit should optimize layer count

**BuildKit:**

3. **Filesystem Differences:**- GitHub: [github.com/moby/buildkit](https://github.com/moby/buildkit)

   - Case-insensitive by default- Discussions: [github.com/moby/buildkit/discussions](https://github.com/moby/buildkit/discussions)

   - Different path separators (backslash)- Issues: [github.com/moby/buildkit/issues](https://github.com/moby/buildkit/issues)

   - No hard links in traditional sense

   - Different permission model**Slack:**

- [Docker Community Slack](https://dockercommunity.slack.com/) - #buildkit channel

4. **Resource Usage:**- [Containerd Slack](https://containerd.slack.com/) - #general, #windows

   - Higher memory overhead per container

   - Longer container start times**Mailing Lists:**

   - More disk I/O for VHD operations- [Moby Project Mailing List](https://groups.google.com/g/moby-project)



---### Related Projects



## Community and Resources**Core Dependencies:**

- [containerd](https://github.com/containerd/containerd) - Container runtime

### Official Channels- [hcsshim](https://github.com/microsoft/hcsshim) - Windows container shim

- [runc](https://github.com/opencontainers/runc) - OCI runtime (Linux)

**BuildKit:**- [runhcs](https://github.com/microsoft/hcsshim/tree/main/cmd/runhcs) - OCI runtime (Windows)



- GitHub: [github.com/moby/buildkit](https://github.com/moby/buildkit)**Docker Ecosystem:**

- Discussions: [github.com/moby/buildkit/discussions](https://github.com/moby/buildkit/discussions)- [Docker Engine](https://github.com/moby/moby) - Uses BuildKit

- Issues: [github.com/moby/buildkit/issues](https://github.com/moby/buildkit/issues)- [Docker CLI](https://github.com/docker/cli) - BuildKit integration



**Slack:**### Documentation



- [Docker Community Slack](https://dockercommunity.slack.com/) - #buildkit channel**Essential Reading:**

- [Containerd Slack](https://containerd.slack.com/) - #general, #windows- [BuildKit README](https://github.com/moby/buildkit/blob/master/README.md)

- [BuildKit Documentation](https://github.com/moby/buildkit/tree/master/docs)

**Mailing Lists:**- [Windows Containers Documentation](https://docs.microsoft.com/en-us/virtualization/windowscontainers/)

- [HCS Documentation](https://github.com/microsoft/hcsshim/tree/main/doc)

- [Moby Project Mailing List](https://groups.google.com/g/moby-project)

### Key People (as of 2024-2025)

### Related Projects

Check these files for current maintainers:

**Core Dependencies:**- `MAINTAINERS` - List of project maintainers

- `CODEOWNERS` - Code ownership by area

- [containerd](https://github.com/containerd/containerd) - Container runtime

- [hcsshim](https://github.com/microsoft/hcsshim) - Windows container shimTo find Windows contributors:

- [runc](https://github.com/opencontainers/runc) - OCI runtime (Linux)```bash

- [runhcs](https://github.com/microsoft/hcsshim/tree/main/cmd/runhcs) - OCI runtime (Windows)git log --all --author="windows" --format="%an <%ae>" | sort -u

git log --all -- "**/*windows*" --format="%an <%ae>" | sort -u

**Docker Ecosystem:**```



- [Docker Engine](https://github.com/moby/moby) - Uses BuildKit### Asking for Help

- [Docker CLI](https://github.com/docker/cli) - BuildKit integration

**Before asking:**

### Documentation1. Search existing issues and discussions

2. Check documentation

**Essential Reading:**3. Review recent PRs for similar problems

4. Try to debug and provide detailed information

- [BuildKit README](https://github.com/moby/buildkit/blob/master/README.md)

- [BuildKit Documentation](https://github.com/moby/buildkit/tree/master/docs)**When asking:**

- [Windows Containers Documentation](https://docs.microsoft.com/en-us/virtualization/windowscontainers/)1. Provide minimal reproduction case

- [HCS Documentation](https://github.com/microsoft/hcsshim/tree/main/doc)2. Include BuildKit version, Windows version

3. Share relevant logs (use `--debug`)

### Key People (as of 2024-2025)4. Describe what you've tried

5. Be respectful and patient

Check these files for current maintainers:

**Example good question:**

- `MAINTAINERS` - List of project maintainers```

- `CODEOWNERS` - Code ownership by areaTitle: TestSessionExporter fails on Windows with "number of mounts should always be 1"



To find Windows contributors:Environment:

- BuildKit: main branch (commit abc123)

```bash- Windows: Windows Server 2022 (10.0.20348)

git log --all --author="windows" --format="%an <%ae>" | sort -u- Containerd: v2.1.4

git log --all -- "**/*windows*" --format="%an <%ae>" | sort -u

```Issue:

The TestSessionExporter integration test fails when exporting layers.

### Asking for HelpThe error message is: "Lower mount invalid: number of mounts should 

always be 1 for Windows layers"

**Before asking:**

Reproduction:

1. Search existing issues and discussionsgotestsum --format testname -- ./client -v -run "TestIntegration/.*TestSessionExporter$"

2. Check documentation

3. Review recent PRs for similar problemsLogs:

4. Try to debug and provide detailed information[attach relevant logs]



**When asking:**Investigation so far:

I've traced the issue to cache/blobs.go line 238 where Compare() is called.

1. Provide minimal reproduction caseThe lower mount slice has 2 entries instead of 1. I suspect the Windows

2. Include BuildKit version, Windows versionsnapshotter is creating view snapshots incorrectly.

3. Share relevant logs (use `--debug`)

4. Describe what you've triedQuestion:

5. Be respectful and patientShould the Windows snapshotter merge layers before returning mounts, or

should the export logic handle multiple Windows mounts?

**Example good question:**```



```text---

Title: TestSessionExporter fails on Windows with "number of mounts should always be 1"

## Suggested First Tasks

Environment:

- BuildKit: main branch (commit abc123)### Easy (Get Familiar) - Week 1-2

- Windows: Windows Server 2022 (10.0.20348)

- Containerd: v2.1.4#### 1. Documentation Improvements



Issue:**Task:** Improve Windows-specific documentation

The TestSessionExporter integration test fails when exporting layers.

The error message is: "Lower mount invalid: number of mounts should - Add Windows setup instructions to README

always be 1 for Windows layers"- Document Windows-specific limitations

- Add examples for Windows builds

Reproduction:

gotestsum --format testname -- ./client -v -run "TestIntegration/.*TestSessionExporter$"**Files to modify:**

- `README.md`

Logs:- `docs/windows.md` (create if doesn't exist)

[attach relevant logs]- `docs/building.md`



Investigation so far:**Skills learned:**

I've traced the issue to cache/blobs.go line 238 where Compare() is called.- Repository structure

The lower mount slice has 2 entries instead of 1. I suspect the Windows- Documentation standards

snapshotter is creating view snapshots incorrectly.- Windows-specific features



Question:#### 2. Enhanced Error Messages

Should the Windows snapshotter merge layers before returning mounts, or

should the export logic handle multiple Windows mounts?**Task:** Improve error messages for Windows operations

```

**Example changes:**

---```go

// Before

## Suggested First Tasksreturn errors.New("invalid mount")



### Easy (Get Familiar) - Week 1-2// After

return errors.Errorf("invalid mount configuration for Windows: expected 1 mount, got %d (mounts: %+v)", 

#### 1. Documentation Improvements    len(mounts), mounts)

```

**Task:** Improve Windows-specific documentation

**Files to modify:**

- Add Windows setup instructions to README- `util/windows/util_windows.go`

- Document Windows-specific limitations- `util/winlayers/differ.go`

- Add examples for Windows builds- `cache/blobs_windows.go`



**Files to modify:****Skills learned:**

- Error handling patterns

- `README.md`- Logging practices

- `docs/windows.md` (create if doesn't exist)- User-facing messages

- `docs/building.md`

#### 3. Add Diagnostic Logging

**Skills learned:**

**Task:** Add debug logging to Windows code paths

- Repository structure

- Documentation standards```go

- Windows-specific featuresbklog.G(ctx).WithFields(map[string]interface{}{

    "operation": "createSnapshot",

#### 2. Enhanced Error Messages    "snapshotID": snapshotID,

    "parent": parent,

**Task:** Improve error messages for Windows operations    "mountCount": len(mounts),

}).Debug("Windows snapshot operation")

**Example changes:**```



```go**Files to modify:**

// Before- `util/winlayers/differ.go`

return errors.New("invalid mount")- `util/winlayers/applier.go`

- `cache/blobs.go` (Windows-specific sections)

// After

return errors.Errorf("invalid mount configuration for Windows: expected 1 mount, got %d (mounts: %+v)", **Skills learned:**

    len(mounts), mounts)- BuildKit logging

```- Debugging techniques

- Code navigation

**Files to modify:**

### Medium (Learn Architecture) - Week 3-6

- `util/windows/util_windows.go`

- `util/winlayers/differ.go`#### 1. Fix TestSessionExporter

- `cache/blobs_windows.go`

**Task:** Resolve the "number of mounts should always be 1" error

**Skills learned:**

**Investigation steps:**

- Error handling patterns1. Add logging to see mount creation

- Logging practices2. Trace Windows snapshotter behavior

- User-facing messages3. Compare with Linux overlay handling

4. Implement fix

#### 3. Add Diagnostic Logging

**Files to investigate:**

**Task:** Add debug logging to Windows code paths- `client/client_test.go` (test code)

- `cache/blobs.go` (export logic)

```go- `util/windows/util_windows.go` (mount validation)

bklog.G(ctx).WithFields(map[string]interface{}{- Containerd snapshotter code

    "operation": "createSnapshot",

    "snapshotID": snapshotID,**Skills learned:**

    "parent": parent,- Debugging complex issues

    "mountCount": len(mounts),- Understanding BuildKit architecture

}).Debug("Windows snapshot operation")- Windows snapshotter internals

```- Test writing



**Files to modify:**#### 2. Add Windows-Specific Integration Tests



- `util/winlayers/differ.go`**Task:** Create Windows variants of Linux-only tests

- `util/winlayers/applier.go`

- `cache/blobs.go` (Windows-specific sections)**Example:**

```go

**Skills learned:**//go:build windows



- BuildKit loggingfunc testWindowsLayerExport(t *testing.T, sb integration.Sandbox) {

- Debugging techniques    // Test Windows-specific layer export

- Code navigation}

```

### Medium (Learn Architecture) - Week 3-6

**Files to create/modify:**

#### 1. Fix TestSessionExporter- `client/client_windows_test.go`

- `solver/solver_windows_test.go`

**Task:** Resolve the "number of mounts should always be 1" error

**Skills learned:**

**Investigation steps:**- Test infrastructure

- Platform-specific testing

1. Add logging to see mount creation- Integration test patterns

2. Trace Windows snapshotter behavior

3. Compare with Linux overlay handling#### 3. Optimize Windows Layer Caching

4. Implement fix

**Task:** Improve cache hit rates for Windows builds

**Files to investigate:**

**Ideas:**

- `client/client_test.go` (test code)- Analyze cache miss patterns

- `cache/blobs.go` (export logic)- Optimize layer metadata

- `util/windows/util_windows.go` (mount validation)- Improve content hashing for Windows

- Containerd snapshotter code

**Files to investigate:**

**Skills learned:**- `cache/manager.go`

- `cache/metadata.go`

- Debugging complex issues- `util/winlayers/differ.go`

- Understanding BuildKit architecture

- Windows snapshotter internals**Skills learned:**

- Test writing- Cache architecture

- Performance optimization

#### 2. Add Windows-Specific Integration Tests- Profiling and benchmarking



**Task:** Create Windows variants of Linux-only tests### Hard (Deep Expertise) - Week 7+



**Example:**#### 1. Implement Missing Windows Features



```go**Task:** Add Windows support for features that currently only work on Linux

//go:build windows

**Candidates:**

func testWindowsLayerExport(t *testing.T, sb integration.Sandbox) {- Rootless mode (if feasible on Windows)

    // Test Windows-specific layer export- Advanced networking features

}- Security features (sandboxing)

```

**Skills learned:**

**Files to create/modify:**- Deep Windows internals

- Security considerations

- `client/client_windows_test.go`- Feature design

- `solver/solver_windows_test.go`

#### 2. Performance Optimizations

**Skills learned:**

**Task:** Reduce Windows container overhead in BuildKit

- Test infrastructure

- Platform-specific testing**Areas:**

- Integration test patterns- VHD I/O optimization

- Layer caching improvements

#### 3. Optimize Windows Layer Caching- Snapshot diff computation



**Task:** Improve cache hit rates for Windows builds**Skills learned:**

- Profiling tools

**Ideas:**- Performance analysis

- Windows storage stack

- Analyze cache miss patterns

- Optimize layer metadata#### 3. Windows Container Version Compatibility

- Improve content hashing for Windows

**Task:** Better handling of Windows version mismatches

**Files to investigate:**

**Goals:**

- `cache/manager.go`- Auto-detect version requirements

- `cache/metadata.go`- Clear error messages

- `util/winlayers/differ.go`- Graceful degradation



**Skills learned:****Skills learned:**

- Windows versioning

- Cache architecture- Compatibility layers

- Performance optimization- Error handling design

- Profiling and benchmarking

---

### Hard (Deep Expertise) - Week 7+

## Debugging Tips

#### 1. Implement Missing Windows Features

### Enable Verbose Logging

**Task:** Add Windows support for features that currently only work on Linux

#### BuildKit Daemon

**Candidates:**

```powershell

- Rootless mode (if feasible on Windows)# Set environment variable

- Advanced networking features$env:BUILDKIT_DEBUG="1"

- Security features (sandboxing)

# Start buildkitd with debug flag

**Skills learned:**buildkitd.exe --debug --config buildkitd.toml



- Deep Windows internals# Or in code, set log level

- Security considerationsbklog.G(ctx).Logger.SetLevel(logrus.DebugLevel)

- Feature design```



#### 2. Performance Optimizations#### Tests



**Task:** Reduce Windows container overhead in BuildKit```powershell

# Run tests with verbose output

**Areas:**gotestsum --format testname -- ./client -v -run TestSessionExporter



- VHD I/O optimization# Run specific test with extra debugging

- Layer caching improvementsgo test -v -run TestSessionExporter ./client 2>&1 | Tee-Object -File test-output.log

- Snapshot diff computation

# With BuildKit debug enabled

**Skills learned:**$env:BUILDKIT_DEBUG="1"

go test -v -run TestSessionExporter ./client

- Profiling tools```

- Performance analysis

- Windows storage stack### Add Print Debugging



#### 3. Windows Container Version Compatibility```go

// Quick debug output

**Task:** Better handling of Windows version mismatchesfmt.Printf("DEBUG: mounts=%+v\n", mounts)

fmt.Printf("DEBUG: len(mounts)=%d\n", len(mounts))

**Goals:**

// Better: Use BuildKit logger

- Auto-detect version requirementsbklog.G(ctx).Debugf("mounts=%+v", mounts)

- Clear error messagesbklog.G(ctx).WithField("mountCount", len(mounts)).Debug("processing mounts")

- Graceful degradation

// For JSON output

**Skills learned:**import "encoding/json"

data, _ := json.MarshalIndent(mounts, "", "  ")

- Windows versioningfmt.Printf("DEBUG: mounts=%s\n", data)

- Compatibility layers```

- Error handling design

### Use VS Code Debugger

---

1. **Set breakpoints** in code

## Debugging Tips2. **Run debug configuration** from launch.json

3. **Step through code**:

### Enable Verbose Logging   - F10: Step over

   - F11: Step into

#### BuildKit Daemon   - Shift+F11: Step out

4. **Inspect variables** in debug panel

```powershell5. **Use Debug Console** for evaluating expressions

# Set environment variable

$env:BUILDKIT_DEBUG="1"### Inspect Containerd State



# Start buildkitd with debug flag```powershell

buildkitd.exe --debug --config buildkitd.toml# List namespaces

ctr namespaces ls

# Or in code, set log level

bklog.G(ctx).Logger.SetLevel(logrus.DebugLevel)# List snapshots in buildkit namespace

```ctr -n buildkit snapshots ls



#### Tests# Get snapshot info

ctr -n buildkit snapshots info <snapshot-id>

```powershell

# Run tests with verbose output# List containers

gotestsum --format testname -- ./client -v -run TestSessionExporterctr -n buildkit containers ls



# Run specific test with extra debugging# Inspect container

go test -v -run TestSessionExporter ./client 2>&1 | Tee-Object -File test-output.logctr -n buildkit containers info <container-id>



# With BuildKit debug enabled# List content blobs

$env:BUILDKIT_DEBUG="1"ctr -n buildkit content ls

go test -v -run TestSessionExporter ./client

```# Get content info

ctr -n buildkit content info <digest>

### Add Print Debugging```



```go### Trace System Calls (Advanced)

// Quick debug output

fmt.Printf("DEBUG: mounts=%+v\n", mounts)**Process Monitor (Microsoft):**

fmt.Printf("DEBUG: len(mounts)=%d\n", len(mounts))1. Download [Process Monitor](https://docs.microsoft.com/en-us/sysinternals/downloads/procmon)

2. Filter for `buildkitd.exe` or `containerd.exe`

// Better: Use BuildKit logger3. Watch file system and registry operations

bklog.G(ctx).Debugf("mounts=%+v", mounts)4. Identify VHD operations and failures

bklog.G(ctx).WithField("mountCount", len(mounts)).Debug("processing mounts")

**ETW Tracing:**

// For JSON output```powershell

import "encoding/json"# Start trace

data, _ := json.MarshalIndent(mounts, "", "  ")logman create trace BuildKitTrace -p Microsoft-Windows-Containers-WCIFS -o trace.etl -ets

fmt.Printf("DEBUG: mounts=%s\n", data)

```# Run your operation

buildkitd.exe ...

### Use VS Code Debugger

# Stop trace

1. **Set breakpoints** in codelogman stop BuildKitTrace -ets

2. **Run debug configuration** from launch.json

3. **Step through code**:# Analyze with Windows Performance Analyzer

   - F10: Step over```

   - F11: Step into

   - Shift+F11: Step out### Common Issues and Solutions

4. **Inspect variables** in debug panel

5. **Use Debug Console** for evaluating expressions#### Issue: "failed to create container: hcsshim::CreateComputeSystem"



### Inspect Containerd State**Cause:** HCS failure, often due to:

- Version mismatch (container vs host)

```powershell- Layer corruption

# List namespaces- Resource exhaustion

ctr namespaces ls

**Debug:**

# List snapshots in buildkit namespace```powershell

ctr -n buildkit snapshots ls# Check event logs

Get-WinEvent -LogName Microsoft-Windows-Containers-Wcifs/Operational -MaxEvents 50

# Get snapshot info

ctr -n buildkit snapshots info <snapshot-id># Check HCS diagnostic logs

Get-ComputeProcess | Format-List

# List containers```

ctr -n buildkit containers ls

**Solution:**

# Inspect container- Ensure matching Windows versions

ctr -n buildkit containers info <container-id>- Clean up old containers/images

- Check disk space

# List content blobs

ctr -n buildkit content ls#### Issue: "number of mounts should always be 1 for Windows layers"



# Get content info**Cause:** Windows snapshotter returning multiple mounts

ctr -n buildkit content info <digest>

```**Debug:**

```go

### Trace System Calls (Advanced)// Add logging before the check

bklog.G(ctx).Debugf("Mounts received: %+v", mounts)

**Process Monitor (Microsoft):**for i, m := range mounts {

    bklog.G(ctx).Debugf("Mount[%d]: Type=%s, Source=%s, Options=%v", 

1. Download [Process Monitor](https://docs.microsoft.com/en-us/sysinternals/downloads/procmon)        i, m.Type, m.Source, m.Options)

2. Filter for `buildkitd.exe` or `containerd.exe`}

3. Watch file system and registry operations```

4. Identify VHD operations and failures

**Solution:** (Investigation in progress)

**ETW Tracing:**- Check snapshotter View() behavior

- Ensure proper mount composition

```powershell- May need to fix snapshotter or export logic

# Start trace

logman create trace BuildKitTrace -p Microsoft-Windows-Containers-WCIFS -o trace.etl -ets#### Issue: Test timeouts on Windows



# Run your operation**Cause:** Windows operations are slower

buildkitd.exe ...

**Solution:**

# Stop trace```go

logman stop BuildKitTrace -ets// Increase timeout

//go:build windows

# Analyze with Windows Performance Analyzerconst operationTimeout = 5 * time.Minute // vs 1 minute on Linux

``````



### Common Issues and Solutions### Helpful Commands



#### Issue: "failed to create container: hcsshim::CreateComputeSystem"```powershell

# Build with race detector

**Cause:** HCS failure, often due to:go test -race ./...



- Version mismatch (container vs host)# Build with coverage

- Layer corruptiongo test -cover ./...

- Resource exhaustiongo test -coverprofile=coverage.out ./...

go tool cover -html=coverage.out

**Debug:**

# Run specific test with timeout

```powershellgo test -v -timeout 10m -run TestSessionExporter ./client

# Check event logs

Get-WinEvent -LogName Microsoft-Windows-Containers-Wcifs/Operational -MaxEvents 50# Find all Windows-specific files

Get-ChildItem -Recurse -Filter "*windows*"

# Check HCS diagnostic logs

Get-ComputeProcess | Format-List# Find TODOs in Windows code

```Select-String -Pattern "TODO.*[Ww]indows" -Path . -Recurse



**Solution:**# Check for platform-specific build tags

Select-String -Pattern "//go:build" -Path . -Recurse

- Ensure matching Windows versions```

- Clean up old containers/images

- Check disk space### Performance Profiling



#### Issue: "number of mounts should always be 1 for Windows layers"```powershell

# CPU profiling

**Cause:** Windows snapshotter returning multiple mountsgo test -cpuprofile=cpu.prof -bench=. ./...

go tool pprof cpu.prof

**Debug:**

# Memory profiling

```gogo test -memprofile=mem.prof -bench=. ./...

// Add logging before the checkgo tool pprof mem.prof

bklog.G(ctx).Debugf("Mounts received: %+v", mounts)

for i, m := range mounts {# Generate profile graph (requires graphviz)

    bklog.G(ctx).Debugf("Mount[%d]: Type=%s, Source=%s, Options=%v", go tool pprof -http=:8080 cpu.prof

        i, m.Type, m.Source, m.Options)```

}

```---



**Solution:** (Investigation in progress)## Additional Resources



- Check snapshotter View() behavior### Books

- Ensure proper mount composition

- May need to fix snapshotter or export logic- **"Docker Deep Dive" by Nigel Poulton** - Good intro to containers

- **"Kubernetes Patterns" by Bilgin Ibryam** - Advanced container patterns

#### Issue: Test timeouts on Windows

### Courses

**Cause:** Windows operations are slower

- [Windows Containers on Microsoft Learn](https://docs.microsoft.com/en-us/learn/modules/intro-to-containers/)

**Solution:**- [Docker Mastery for Node.js course](https://www.udemy.com/docker-mastery/) - Has Windows section



```go### Blogs

// Increase timeout

//go:build windows- [BuildKit Blog](https://blog.mobyproject.org/tag/buildkit/)

const operationTimeout = 5 * time.Minute // vs 1 minute on Linux- [Windows Containers Blog](https://techcommunity.microsoft.com/t5/containers/bg-p/Containers)

```

### Tools

### Helpful Commands

- [Docker Desktop](https://www.docker.com/products/docker-desktop) - Easy Windows setup

```powershell- [Process Monitor](https://docs.microsoft.com/en-us/sysinternals/downloads/procmon) - System call tracing

# Build with race detector- [Windows Performance Analyzer](https://docs.microsoft.com/en-us/windows-hardware/test/wpt/) - ETW analysis

go test -race ./...

---

# Build with coverage

go test -cover ./...## Quick Reference

go test -coverprofile=coverage.out ./...

go tool cover -html=coverage.out### BuildKit Commands



# Run specific test with timeout```powershell

go test -v -timeout 10m -run TestSessionExporter ./client# Build image from Dockerfile

buildctl build --frontend dockerfile.v0 `

# Find all Windows-specific files    --local context=. `

Get-ChildItem -Recurse -Filter "*windows*"    --local dockerfile=. `

    --output type=image,name=myimage:latest

# Find TODOs in Windows code

Select-String -Pattern "TODO.*[Ww]indows" -Path . -Recurse# Export to tar

buildctl build ... --output type=tar,dest=image.tar

# Check for platform-specific build tags

Select-String -Pattern "//go:build" -Path . -Recurse# Use cache from registry

```buildctl build ... `

    --export-cache type=registry,ref=myregistry/buildcache `

### Performance Profiling    --import-cache type=registry,ref=myregistry/buildcache



```powershell# Debug build

# CPU profilingbuildctl --debug build ...

go test -cpuprofile=cpu.prof -bench=. ./...```

go tool pprof cpu.prof

### Test Commands

# Memory profiling

go test -memprofile=mem.prof -bench=. ./...```powershell

go tool pprof mem.prof# Run all tests

gotestsum --format testname -- ./...

# Generate profile graph (requires graphviz)

go tool pprof -http=:8080 cpu.prof# Run specific test

```gotestsum --format testname -- ./client -run TestSessionExporter -v



---# Run with coverage

gotestsum -- -coverprofile=coverage.out ./...

## Additional Resources

# Run integration tests only

### Booksgotestsum -- -tags=integration ./...

```

- **"Docker Deep Dive" by Nigel Poulton** - Good intro to containers

- **"Kubernetes Patterns" by Bilgin Ibryam** - Advanced container patterns### Common File Locations



### Courses```

C:\ProgramData\containerd\       - Containerd data

- [Windows Containers on Microsoft Learn](https://docs.microsoft.com/en-us/learn/modules/intro-to-containers/)C:\ProgramData\docker\           - Docker data (if using Docker)

- [Docker Mastery for Node.js course](https://www.udemy.com/docker-mastery/) - Has Windows section%TEMP%\buildkit\                 - BuildKit temp files

%LOCALAPPDATA%\buildkit\         - BuildKit local cache

### Blogs```



- [BuildKit Blog](https://blog.mobyproject.org/tag/buildkit/)---

- [Windows Containers Blog](https://techcommunity.microsoft.com/t5/containers/bg-p/Containers)

## Conclusion

### Tools

Windows container development in BuildKit is challenging but rewarding. The platform has unique constraints and requirements that differ significantly from Linux, but the core BuildKit architecture is well-designed to accommodate platform-specific implementations.

- [Docker Desktop](https://www.docker.com/products/docker-desktop) - Easy Windows setup

- [Process Monitor](https://docs.microsoft.com/en-us/sysinternals/downloads/procmon) - System call tracing**Remember:**

- [Windows Performance Analyzer](https://docs.microsoft.com/en-us/windows-hardware/test/wpt/) - ETW analysis- Ask questions in the community

- Document your learnings

---- Write tests for your changes

- Be patient - Windows containers have quirks

## Quick Reference- Share your knowledge with future maintainers



### BuildKit Commands**Good luck, and welcome to the BuildKit team! 🚀**



```powershell---

# Build image from Dockerfile

buildctl build --frontend dockerfile.v0 `## Changelog

    --local context=. `

    --local dockerfile=. `| Date | Author | Changes |

    --output type=image,name=myimage:latest|------|--------|---------|

| 2025-10-24 | Initial | Created comprehensive Windows development guide |

# Export to tar

buildctl build ... --output type=tar,dest=image.tar## Contributing to This Guide



# Use cache from registryThis guide is meant to be a living document. If you find errors, have suggestions, or want to add sections:

buildctl build ... `

    --export-cache type=registry,ref=myregistry/buildcache `1. Create a PR with your changes

    --import-cache type=registry,ref=myregistry/buildcache2. Tag relevant maintainers for review

3. Update the changelog

# Debug build

buildctl --debug build ...Questions about this guide? Open a GitHub discussion in the BuildKit repository.

```

### Test Commands

```powershell
# Run all tests
gotestsum --format testname -- ./...

# Run specific test
gotestsum --format testname -- ./client -run TestSessionExporter -v

# Run with coverage
gotestsum -- -coverprofile=coverage.out ./...

# Run integration tests only
gotestsum -- -tags=integration ./...
```

### Common File Locations

```text
C:\ProgramData\containerd\       - Containerd data
C:\ProgramData\docker\           - Docker data (if using Docker)
%TEMP%\buildkit\                 - BuildKit temp files
%LOCALAPPDATA%\buildkit\         - BuildKit local cache
```

---

## Conclusion

Windows container development in BuildKit is challenging but rewarding. The platform has unique constraints and requirements that differ significantly from Linux, but the core BuildKit architecture is well-designed to accommodate platform-specific implementations.

**Remember:**

- Ask questions in the community
- Document your learnings
- Write tests for your changes
- Be patient - Windows containers have quirks
- Share your knowledge with future maintainers

**Good luck, and welcome to the BuildKit team! 🚀**

---

## Changelog

| Date | Author | Changes |
|------|--------|---------|
| 2025-10-24 | Initial | Created comprehensive Windows development guide |

## Contributing to This Guide

This guide is meant to be a living document. If you find errors, have suggestions, or want to add sections:

1. Create a PR with your changes
2. Tag relevant maintainers for review
3. Update the changelog

Questions about this guide? Open a GitHub discussion in the BuildKit repository.
