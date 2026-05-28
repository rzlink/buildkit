# Self-Hosted ARM64 Windows Runner Setup Guide

This document describes how the Windows ARM64 self-hosted GitHub Actions runners
are provisioned and managed for BuildKit CI testing.

## Architecture Overview

```
GitHub Actions                          Azure (eastus2)
┌─────────────────┐                    ┌──────────────────────────┐
│  test-os.yml    │                    │  buildkit-arm64-runner-rg│
│                 │                    │                          │
│  runs-on:       │◄──── outbound ─────│  bk-arm64-run-01 (D8)    │
│  [self-hosted,  │     connection     │  bk-arm64-run-02 (D4)    │
│   windows-      │                    │  bk-arm64-run-03 (D4)    │
│   arm64-        │  Jobs distributed  │  ...                     │
│   selfhosted]   │  to idle runners   │  bk-arm64-run-10 (D4)    │
└─────────────────┘                    └──────────────────────────┘
```

**How it works:**
1. Each Azure VM runs a GitHub Actions **runner agent** as a Windows service
2. The runner agent connects **outbound** to GitHub (no inbound ports needed)
3. Runners are registered with label: `windows-arm64-selfhosted`
4. The workflow specifies `runs-on: [self-hosted, windows-arm64-selfhosted]`
5. GitHub matches queued jobs to available runners with matching labels
6. With N runners online, N test shards run simultaneously

**No changes to the GitHub account are needed** beyond having the runner agents
registered — the runners appear automatically under
**Repository Settings → Actions → Runners**.

## Azure Resources

| Resource       | Details                                                         |
| -------------- | --------------------------------------------------------------- |
| Subscription   | CoreOS_DPLAT_WCCT_Demo                                          |
| Resource Group | `buildkit-arm64-runner-rg`                                      |
| Location       | eastus2                                                         |
| VM Image       | `MicrosoftWindowsDesktop:windows11preview-arm64:win11-24h2-ent` |
| vCPU Quota     | 100 Dpdsv6 family vCPUs                                         |

### VM Fleet

| VM Name                  | Size              | vCPU | RAM   | Role            |
| ------------------------ | ----------------- | ---- | ----- | --------------- |
| bk-arm64-runner (run-01) | Standard_D8pds_v6 | 8    | 32 GB | Original runner |
| bk-arm64-run-02          | Standard_D4pds_v6 | 4    | 16 GB | Test runner     |
| bk-arm64-run-03          | Standard_D4pds_v6 | 4    | 16 GB | Test runner     |
| ...                      | ...               | ...  | ...   | ...             |
| bk-arm64-run-10          | Standard_D4pds_v6 | 4    | 16 GB | Test runner     |

**Total: 10 runners, 44 vCPUs** (of 100 quota)

All VMs use Cobalt 100 ARM64 processors with NVMe local storage, which eliminates
the I/O timeout issues seen on the GitHub partner runner.

### Cost Estimates

| Scenario                          | Monthly Cost (approx.)   |
| --------------------------------- | ------------------------ |
| 10 runners, 24/7                  | ~$1,400                  |
| 10 runners, 4.5 hrs/day (CI only) | ~$259                    |
| 10 runners, deallocated when idle | ~$57 (disk storage only) |

## Software Stack (per VM)

Each runner VM requires the following software:

| Software              | Version         | Path                                | Purpose                        |
| --------------------- | --------------- | ----------------------------------- | ------------------------------ |
| Windows 11 ARM64      | 24H2 Enterprise | —                                   | Base OS                        |
| Containers feature    | —               | —                                   | HCS/HNS for Windows containers |
| Git                   | 2.47.1 ARM64    | `C:\Program Files\Git\`             | Source checkout + bash shell   |
| Go                    | 1.26.0 ARM64    | `C:\go\`                            | Test execution                 |
| Node.js               | 20.18.3 ARM64   | `C:\nodejs\`                        | GitHub Actions (codecov, etc.) |
| Python                | 3.12.9 ARM64    | `C:\Program Files\Python312-arm64\` | Test summary script            |
| GitHub Actions Runner | 2.322.0 ARM64   | `C:\actions-runner\`                | Job execution agent            |

### Required Windows Features & Services

| Feature/Service | State              | Purpose                          |
| --------------- | ------------------ | -------------------------------- |
| Containers      | Enabled            | Windows container support        |
| Containers-HNS  | Enabled            | Host Networking Service          |
| Containers-SDN  | Enabled            | Software Defined Networking      |
| vmcompute (HCS) | Running, Automatic | Host Compute Service for hcsshim |
| hns             | Running, Automatic | Host Networking Service          |
| Developer Mode  | Enabled            | Symlink creation without admin   |

### System PATH Additions

The following must be in the system PATH for the runner service account:
```
C:\Program Files\Git\bin
C:\Program Files\Git\cmd
C:\Program Files\Git\usr\bin
C:\go\bin
C:\nodejs
C:\Program Files\Python312-arm64
C:\Program Files\Python312-arm64\Scripts
```

A `python3.exe` copy of `python.exe` is required (Windows installs Python as
`python.exe` but the workflow calls `python3`).

## Provisioning a New Runner

### Prerequisites
- Azure CLI authenticated (`az login`)
- GitHub personal access token with `repo` scope (for runner registration)
- The resource group `buildkit-arm64-runner-rg` must exist

### Step 1: Create the VM

```bash
VM_NAME="bk-arm64-run-XX"
az vm create \
  --resource-group buildkit-arm64-runner-rg \
  --name "$VM_NAME" \
  --image "MicrosoftWindowsDesktop:windows11preview-arm64:win11-24h2-ent:latest" \
  --size Standard_D4pds_v6 \
  --admin-username bkrunner \
  --admin-password 'YOUR_PASSWORD' \
  --os-disk-size-gb 128 \
  --public-ip-sku Standard \
  --nsg-rule NONE
```

### Step 2: Enable Windows Containers (requires reboot)

```bash
az vm run-command invoke \
  --resource-group buildkit-arm64-runner-rg \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '
Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName Containers-HNS -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName Containers-SDN -All -NoRestart
'

az vm restart --resource-group buildkit-arm64-runner-rg --name "$VM_NAME"
```

### Step 3: Configure services and Developer Mode

```bash
az vm run-command invoke \
  --resource-group buildkit-arm64-runner-rg \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '
Set-Service -Name vmcompute -StartupType Automatic
Start-Service -Name vmcompute
Set-Service -Name hns -StartupType Automatic

$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
Set-ItemProperty -Path $regPath -Name "AllowDevelopmentWithoutDevLicense" -Value 1
Set-ItemProperty -Path $regPath -Name "AllowAllTrustedApps" -Value 1
'
```

### Step 4: Install software

```bash
az vm run-command invoke \
  --resource-group buildkit-arm64-runner-rg \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts '
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path C:\temp | Out-Null

# Git
Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.2/Git-2.47.1.2-arm64.exe" -OutFile C:\temp\git.exe -UseBasicParsing
Start-Process C:\temp\git.exe -ArgumentList "/VERYSILENT","/NORESTART","/NOCANCEL","/SP-" -Wait

# Go
Invoke-WebRequest -Uri "https://go.dev/dl/go1.26.0.windows-arm64.zip" -OutFile C:\temp\go.zip -UseBasicParsing
Expand-Archive C:\temp\go.zip -DestinationPath C:\ -Force

# Node.js
Invoke-WebRequest -Uri "https://nodejs.org/dist/v20.18.3/node-v20.18.3-win-arm64.zip" -OutFile C:\temp\node.zip -UseBasicParsing
Expand-Archive C:\temp\node.zip -DestinationPath C:\temp\node -Force
Move-Item "C:\temp\node\node-v20.18.3-win-arm64" "C:\nodejs" -Force

# Python
Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.9/python-3.12.9-arm64.exe" -OutFile C:\temp\py.exe -UseBasicParsing
Start-Process C:\temp\py.exe -ArgumentList "/quiet","InstallAllUsers=1","PrependPath=1" -Wait
Copy-Item "C:\Program Files\Python312-arm64\python.exe" "C:\Program Files\Python312-arm64\python3.exe"

# Update PATH
$path = [Environment]::GetEnvironmentVariable("Path", "Machine")
$adds = @("C:\Program Files\Git\bin","C:\Program Files\Git\cmd","C:\Program Files\Git\usr\bin","C:\go\bin","C:\nodejs","C:\Program Files\Python312-arm64","C:\Program Files\Python312-arm64\Scripts")
foreach ($p in $adds) { if (-not $path.Contains($p)) { $path += ";$p" } }
[Environment]::SetEnvironmentVariable("Path", $path, "Machine")

Remove-Item -Recurse -Force C:\temp
'
```

### Step 5: Register and start the runner agent

```bash
# Get registration token
REG_TOKEN=$(curl -s -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/rzlink/buildkit/actions/runners/registration-token" \
  | jq -r '.token')

# Configure and install as service
az vm run-command invoke \
  --resource-group buildkit-arm64-runner-rg \
  --name "$VM_NAME" \
  --command-id RunPowerShellScript \
  --scripts "
New-Item -ItemType Directory -Force -Path C:\actions-runner | Out-Null
Set-Location C:\actions-runner
Invoke-WebRequest -Uri 'https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-win-arm64-2.322.0.zip' -OutFile runner.zip -UseBasicParsing
Expand-Archive runner.zip -DestinationPath . -Force
Remove-Item runner.zip

.\config.cmd --url 'https://github.com/rzlink/buildkit' --token '$REG_TOKEN' --name '$VM_NAME' --labels 'windows-arm64-selfhosted' --unattended --replace

# Install as Windows service
\$svcName = 'actions.runner.rzlink-buildkit.$VM_NAME'
sc.exe create \$svcName binPath= 'C:\actions-runner\bin\RunnerService.exe' start= auto
sc.exe start \$svcName
"
```

The runner should appear as **online** at:
`https://github.com/rzlink/buildkit/settings/actions/runners`

## Scaling Guide

### Adding more runners
1. Follow the provisioning steps above with a new VM name
2. All runners using the label `windows-arm64-selfhosted` will automatically
   pick up queued ARM64 test jobs
3. Each additional D4pds_v6 runner uses 4 vCPUs from the 100 quota

### Removing runners
```bash
# Remove from GitHub first
curl -X DELETE -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/rzlink/buildkit/actions/runners/RUNNER_ID"

# Then delete the Azure VM
az vm delete -g buildkit-arm64-runner-rg -n VM_NAME --yes
```

### Performance scaling reference
With 22 test shards:

| Runners | Estimated Wall Clock | Notes                        |
| ------- | -------------------- | ---------------------------- |
| 1       | ~3.5 hours           | Sequential execution         |
| 5       | ~45 min              |                              |
| 10      | ~35 min              | Current setup                |
| 22      | ~27 min              | One runner per shard (floor) |

The theoretical minimum is ~27 minutes, bounded by the longest shard
(client#2-4 at 26.5 min). Reaching 20 minutes would require splitting
the largest test shards further.

## Cost Management

### Stop all runners (stop billing for compute, still pay for disks)
```bash
for vm in $(az vm list -g buildkit-arm64-runner-rg --query "[].name" -o tsv); do
  az vm deallocate -g buildkit-arm64-runner-rg -n "$vm" --no-wait
done
```

### Start all runners
```bash
for vm in $(az vm list -g buildkit-arm64-runner-rg --query "[].name" -o tsv); do
  az vm start -g buildkit-arm64-runner-rg -n "$vm" --no-wait
done
```

### Delete everything
```bash
az group delete -g buildkit-arm64-runner-rg --yes
```

## Future: Auto Start/Stop Strategy

When moving to a non-Microsoft Azure subscription that supports programmatic
access from GitHub Actions, the following strategy can automate cost management:

### Workflow-triggered VM lifecycle

Add two jobs to `test-os.yml`:

```yaml
  start-runners:
    if: inputs.arm64_only == 'true' || github.event_name == 'schedule'
    runs-on: ubuntu-24.04  # Free GitHub-hosted runner
    steps:
      - uses: azure/login@v2
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      - name: Start ARM64 runners
        run: |
          for vm in $(az vm list -g buildkit-arm64-runner-rg --query "[].name" -o tsv); do
            az vm start -g buildkit-arm64-runner-rg -n "$vm" --no-wait
          done
          # Wait for runners to come online
          sleep 120

  test-windows-arm64:
    needs: [build, start-runners]
    # ... existing test job config ...

  stop-runners:
    if: always()
    needs: [test-windows-arm64]
    runs-on: ubuntu-24.04
    steps:
      - uses: azure/login@v2
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      - name: Deallocate ARM64 runners
        run: |
          for vm in $(az vm list -g buildkit-arm64-runner-rg --query "[].name" -o tsv); do
            az vm deallocate -g buildkit-arm64-runner-rg -n "$vm" --no-wait
          done
```

### Azure Service Principal setup
```bash
az ad sp create-for-rbac \
  --name "buildkit-ci-runner-manager" \
  --role Contributor \
  --scopes /subscriptions/SUBSCRIPTION_ID/resourceGroups/buildkit-arm64-runner-rg \
  --sdk-auth
```

Store the output as the `AZURE_CREDENTIALS` repository secret.

This approach keeps VMs **deallocated** (~$5.70/mo for disk storage per VM)
and only bills for compute during actual CI runs (~$0.19/hr per D4pds_v6 VM).

## Troubleshooting

### Runner shows "offline" in GitHub
1. Check the Windows service is running:
   ```powershell
   Get-Service actions.runner.*
   ```
2. Check runner diagnostic logs:
   ```powershell
   Get-Content C:\actions-runner\_diag\Runner_*.log | Select-Object -Last 30
   ```
3. Restart the service:
   ```powershell
   Restart-Service actions.runner.*
   ```

### "bash: command not found" in CI
Git's bash is not in the service account's PATH. Ensure `C:\Program Files\Git\bin`
is in the system PATH and restart the runner service.

### "hcsshim::ActivateLayer failed" errors
The Windows Containers feature is not enabled or HCS service is not running:
```powershell
# Check feature
Get-WindowsOptionalFeature -Online -FeatureName Containers
# Check service
Get-Service vmcompute
# Fix
Enable-WindowsOptionalFeature -Online -FeatureName Containers -All
Set-Service vmcompute -StartupType Automatic
Start-Service vmcompute
```

### "mklink" / symlink failures
Developer Mode must be enabled:
```powershell
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
Set-ItemProperty -Path $regPath -Name "AllowDevelopmentWithoutDevLicense" -Value 1
```

### "python3: command not found"
Windows installs Python as `python.exe`. Create a copy:
```powershell
Copy-Item "C:\Program Files\Python312-arm64\python.exe" "C:\Program Files\Python312-arm64\python3.exe"
```

### Tests fail with "docker: command not found"
Docker is not installed on the self-hosted runners. The CI workflow's diagnostic
step calls `docker info` but this is non-fatal (`ignoreReturnCode: true`).
BuildKit tests use containerd directly (built from source by the CI build job).
