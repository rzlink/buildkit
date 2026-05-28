#!/usr/bin/env bash
# create-golden-image.sh — Provision a clean Windows ARM64 VM, install software,
# sysprep, and capture as an Azure Managed Image for VMSS use.
#
# Prerequisites:
#   - Azure CLI authenticated to CoreOS_DPLAT_WCCT_Demo subscription
#   - Sufficient Dpdsv6 vCPU quota in eastus2
#
# Usage: ./create-golden-image.sh [--skip-create] [--skip-install] [--skip-sysprep]

set -euo pipefail

RG="buildkit-arm64-runner-rg"
LOCATION="eastus2"
VM_NAME="bk-arm64-golden"
VM_SIZE="Standard_D4pds_v6"
IMAGE_NAME="bk-arm64-runner-image"
ADMIN_USER="bkrunner"

# Parse flags
SKIP_CREATE=false
SKIP_INSTALL=false
SKIP_SYSPREP=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-create)  SKIP_CREATE=true; shift ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    --skip-sysprep) SKIP_SYSPREP=true; shift ;;
    --sku)          VM_SIZE="$2"; shift 2 ;;
    *)              shift ;;
  esac
done

echo "=== Golden Image Builder ==="
echo "RG: $RG | VM: $VM_NAME | Size: $VM_SIZE | Location: $LOCATION"

# Step 1: Create a fresh VM
if [ "$SKIP_CREATE" = false ]; then
  echo ""
  echo ">>> Step 1: Creating fresh VM..."
  read -sp "Enter admin password for $ADMIN_USER: " ADMIN_PASS
  echo ""

  az vm create \
    --resource-group "$RG" \
    --name "$VM_NAME" \
    --image "MicrosoftWindowsDesktop:windows11preview-arm64:win11-24h2-ent:latest" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --admin-password "$ADMIN_PASS" \
    --os-disk-size-gb 128 \
    --public-ip-sku Standard \
    --nsg-rule NONE \
    --location "$LOCATION" \
    --output table

  echo "VM created. Waiting 60s for Windows to fully boot..."
  sleep 60
else
  echo ">>> Skipping VM creation (--skip-create)"
fi

run_command() {
  local desc="$1"
  local script="$2"
  echo ""
  echo ">>> $desc"
  az vm run-command invoke \
    --resource-group "$RG" \
    --name "$VM_NAME" \
    --command-id RunPowerShellScript \
    --scripts "$script" \
    --output json | jq -r '.value[0].message' 2>/dev/null || true
}

# Step 2: Enable Windows Containers
if [ "$SKIP_INSTALL" = false ]; then
  run_command "Step 2: Enabling Windows Containers feature..." '
$ErrorActionPreference = "Stop"
Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName Containers-HNS -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName Containers-SDN -All -NoRestart
Write-Output "Containers features enabled. Rebooting..."
'

  echo "Rebooting VM for Containers feature..."
  az vm restart --resource-group "$RG" --name "$VM_NAME" --no-wait
  echo "Waiting 120s for reboot..."
  sleep 120

  # Step 3: Configure services and Developer Mode
  run_command "Step 3: Configuring services and Developer Mode..." '
$ErrorActionPreference = "Stop"
Set-Service -Name vmcompute -StartupType Automatic
Start-Service -Name vmcompute
Set-Service -Name hns -StartupType Automatic

$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
Set-ItemProperty -Path $regPath -Name "AllowDevelopmentWithoutDevLicense" -Value 1
Set-ItemProperty -Path $regPath -Name "AllowAllTrustedApps" -Value 1
Write-Output "Services configured, Developer Mode enabled."
'

  # Step 4: Install software
  run_command "Step 4: Installing Git, Go, Node.js, Python..." '
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path C:\temp | Out-Null

# Git
Write-Output "Installing Git..."
Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.2/Git-2.47.1.2-arm64.exe" -OutFile C:\temp\git.exe -UseBasicParsing
Start-Process C:\temp\git.exe -ArgumentList "/VERYSILENT","/NORESTART","/NOCANCEL","/SP-" -Wait

# Go
Write-Output "Installing Go..."
Invoke-WebRequest -Uri "https://go.dev/dl/go1.26.0.windows-arm64.zip" -OutFile C:\temp\go.zip -UseBasicParsing
Expand-Archive C:\temp\go.zip -DestinationPath C:\ -Force

# Node.js
Write-Output "Installing Node.js..."
Invoke-WebRequest -Uri "https://nodejs.org/dist/v20.18.3/node-v20.18.3-win-arm64.zip" -OutFile C:\temp\node.zip -UseBasicParsing
Expand-Archive C:\temp\node.zip -DestinationPath C:\temp\node -Force
Move-Item "C:\temp\node\node-v20.18.3-win-arm64" "C:\nodejs" -Force

# Python
Write-Output "Installing Python..."
Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.9/python-3.12.9-arm64.exe" -OutFile C:\temp\py.exe -UseBasicParsing
Start-Process C:\temp\py.exe -ArgumentList "/quiet","InstallAllUsers=1","PrependPath=1" -Wait
Copy-Item "C:\Program Files\Python312-arm64\python.exe" "C:\Program Files\Python312-arm64\python3.exe"

# Update PATH
$path = [Environment]::GetEnvironmentVariable("Path", "Machine")
$adds = @(
  "C:\Program Files\Git\bin",
  "C:\Program Files\Git\cmd",
  "C:\Program Files\Git\usr\bin",
  "C:\go\bin",
  "C:\nodejs",
  "C:\Program Files\Python312-arm64",
  "C:\Program Files\Python312-arm64\Scripts"
)
foreach ($p in $adds) { if (-not $path.Contains($p)) { $path += ";$p" } }
[Environment]::SetEnvironmentVariable("Path", $path, "Machine")

Remove-Item -Recurse -Force C:\temp
Write-Output "All software installed."
'

  # Step 5: Pre-install GitHub Actions runner (but do NOT register)
  run_command "Step 5: Installing GitHub Actions runner agent..." '
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path C:\actions-runner | Out-Null
Set-Location C:\actions-runner
Invoke-WebRequest -Uri "https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-win-arm64-2.322.0.zip" -OutFile runner.zip -UseBasicParsing
Expand-Archive runner.zip -DestinationPath . -Force
Remove-Item runner.zip
Write-Output "Runner agent extracted to C:\actions-runner (NOT registered - will register at boot)."
'

  # Verify installation
  run_command "Verifying installations..." '
Write-Output "Git: $(& "C:\Program Files\Git\cmd\git.exe" --version)"
Write-Output "Go: $(& "C:\go\bin\go.exe" version)"
Write-Output "Node: $(& "C:\nodejs\node.exe" --version)"
Write-Output "Python: $(& "C:\Program Files\Python312-arm64\python.exe" --version)"
Write-Output "Runner: $(Test-Path C:\actions-runner\run.cmd)"
Write-Output "Containers: $((Get-WindowsOptionalFeature -Online -FeatureName Containers).State)"
Write-Output "vmcompute: $((Get-Service vmcompute).Status)"
'
else
  echo ">>> Skipping software installation (--skip-install)"
fi

# Step 6: Sysprep and capture
if [ "$SKIP_SYSPREP" = false ]; then
  echo ""
  echo ">>> Step 6: Running sysprep (VM will shut down)..."
  az vm run-command invoke \
    --resource-group "$RG" \
    --name "$VM_NAME" \
    --command-id RunPowerShellScript \
    --scripts '
# Clean up any temp files
Remove-Item -Recurse -Force C:\Windows\Temp\* -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force C:\Users\bkrunner\AppData\Local\Temp\* -ErrorAction SilentlyContinue

# Sysprep — generalize the image (VM will shut down)
& C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet
' --output json | jq -r '.value[0].message' 2>/dev/null || true

  echo "Waiting for VM to shut down after sysprep (up to 5 minutes)..."
  for i in $(seq 1 30); do
    state=$(az vm get-instance-view --resource-group "$RG" --name "$VM_NAME" \
      --query "instanceView.statuses[1].displayStatus" -o tsv 2>/dev/null)
    if [[ "$state" == *"stopped"* ]] || [[ "$state" == *"deallocated"* ]]; then
      echo "VM stopped."
      break
    fi
    echo "  [$i/30] State: $state"
    sleep 10
  done

  # Deallocate
  echo "Deallocating VM..."
  az vm deallocate --resource-group "$RG" --name "$VM_NAME"

  # Generalize
  echo "Generalizing VM..."
  az vm generalize --resource-group "$RG" --name "$VM_NAME"

  # Capture image
  echo "Capturing image as '$IMAGE_NAME'..."
  az image create \
    --resource-group "$RG" \
    --name "$IMAGE_NAME" \
    --source "$VM_NAME" \
    --os-type Windows \
    --hyper-v-generation V2 \
    --location "$LOCATION" \
    --output table

  echo ""
  echo "=== Golden image created: $IMAGE_NAME ==="
  echo "Image ID:"
  az image show --resource-group "$RG" --name "$IMAGE_NAME" --query id -o tsv

  echo ""
  echo "You can now delete the golden VM:"
  echo "  az vm delete --resource-group $RG --name $VM_NAME --yes"
else
  echo ">>> Skipping sysprep (--skip-sysprep)"
fi
