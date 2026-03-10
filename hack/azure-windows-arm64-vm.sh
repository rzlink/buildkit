#!/usr/bin/env bash

# hack/azure-windows-arm64-vm.sh
#
# Manages Azure Windows ARM64 VM lifecycle for BuildKit CI testing.
# Uses Azure CLI and az vm run-command for remote execution.
#
# Usage:
#   ./hack/azure-windows-arm64-vm.sh create   - Provision a Windows 11 ARM64 VM
#   ./hack/azure-windows-arm64-vm.sh setup    - Install Go, containerd, gotestsum on VM
#   ./hack/azure-windows-arm64-vm.sh destroy  - Delete resource group and all resources
#
# Required environment variables:
#   AZURE_VM_RG_NAME       - Resource group name (must be unique per job)
#   AZURE_LOCATION         - Azure region (default: eastus2)
#
# Set by 'create' and consumed by other commands:
#   AZURE_VM_NAME          - VM name (set during create, or override)
#
# Optional:
#   AZURE_VM_SIZE          - VM size (default: Standard_D4ps_v6)
#   AZURE_VM_IMAGE         - VM image URN (default: auto-detected Windows 11 ARM64)
#   GO_VERSION             - Go version to install (default: 1.23)
#   AZURE_VM_ADMIN_USER    - VM admin username (default: buildkit)
#   AZURE_VM_ADMIN_PASS    - VM admin password (auto-generated if not set)

set -o errexit
set -o nounset
set -o pipefail

: "${AZURE_VM_RG_NAME:?Environment variable AZURE_VM_RG_NAME must be set}"
: "${AZURE_LOCATION:=eastus2}"
: "${AZURE_VM_SIZE:=Standard_D4ps_v6}"
: "${AZURE_VM_NAME:=buildkit-arm64-${AZURE_VM_RG_NAME##*-}}"
: "${AZURE_VM_ADMIN_USER:=buildkit}"
: "${GO_VERSION:=1.23}"

# State file to persist VM details between commands
STATE_DIR="${ARTIFACTS:-/tmp}/azure-vm-state"

log() {
  echo "$(date -Iseconds): $1"
}

generate_password() {
  # Generate a password that meets Azure complexity requirements
  # Must have uppercase, lowercase, digit, and special char
  local pass
  pass="Bk$(openssl rand -base64 24 | tr -d '/+=' | head -c 20)#1"
  echo "$pass"
}

save_state() {
  mkdir -p "$STATE_DIR"
  echo "$1=$2" >> "$STATE_DIR/vm.env"
}

load_state() {
  if [ -f "$STATE_DIR/vm.env" ]; then
    # shellcheck disable=SC1091
    source "$STATE_DIR/vm.env"
  fi
}

cmd_create() {
  log "Creating resource group: $AZURE_VM_RG_NAME in $AZURE_LOCATION"
  az group create \
    --name "$AZURE_VM_RG_NAME" \
    --location "$AZURE_LOCATION" \
    --tags "purpose=buildkit-ci" "createdAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --output none

  # Auto-generate password if not provided
  if [ -z "${AZURE_VM_ADMIN_PASS:-}" ]; then
    AZURE_VM_ADMIN_PASS=$(generate_password)
  fi
  save_state "AZURE_VM_ADMIN_PASS" "$AZURE_VM_ADMIN_PASS"

  # Determine Windows 11 ARM64 image
  local vm_image="${AZURE_VM_IMAGE:-}"
  if [ -z "$vm_image" ]; then
    log "Finding Windows 11 ARM64 image..."
    vm_image=$(az vm image list \
      --publisher MicrosoftWindowsDesktop \
      --offer windows11preview-arm64 \
      --sku win11-24h2-pro \
      --location "$AZURE_LOCATION" \
      --all \
      --query "[?architecture=='Arm64'] | sort_by(@, &version) | [-1].urn" \
      --output tsv 2>/dev/null || true)

    if [ -z "$vm_image" ]; then
      # Fallback: try other Windows 11 ARM64 SKUs
      vm_image=$(az vm image list \
        --publisher MicrosoftWindowsDesktop \
        --offer windows11preview-arm64 \
        --location "$AZURE_LOCATION" \
        --all \
        --query "[?architecture=='Arm64'] | sort_by(@, &version) | [-1].urn" \
        --output tsv 2>/dev/null || true)
    fi

    if [ -z "$vm_image" ]; then
      log "ERROR: Could not find a Windows 11 ARM64 image in $AZURE_LOCATION"
      exit 1
    fi
    log "Using image: $vm_image"
  fi
  save_state "AZURE_VM_IMAGE" "$vm_image"

  # Accept image terms if needed (marketplace images)
  az vm image terms accept --urn "$vm_image" 2>/dev/null || true

  log "Creating Windows ARM64 VM: $AZURE_VM_NAME (size: $AZURE_VM_SIZE)"
  az vm create \
    --resource-group "$AZURE_VM_RG_NAME" \
    --name "$AZURE_VM_NAME" \
    --image "$vm_image" \
    --size "$AZURE_VM_SIZE" \
    --admin-username "$AZURE_VM_ADMIN_USER" \
    --admin-password "$AZURE_VM_ADMIN_PASS" \
    --nsg-rule NONE \
    --public-ip-address "" \
    --output none

  save_state "AZURE_VM_NAME" "$AZURE_VM_NAME"
  save_state "AZURE_VM_RG_NAME" "$AZURE_VM_RG_NAME"

  log "VM created successfully: $AZURE_VM_NAME"

  # Wait for VM agent to be ready
  log "Waiting for VM agent to be ready..."
  local retries=0
  local max_retries=30
  while [ $retries -lt $max_retries ]; do
    local agent_status
    agent_status=$(az vm get-instance-view \
      --resource-group "$AZURE_VM_RG_NAME" \
      --name "$AZURE_VM_NAME" \
      --query "instanceView.vmAgent.statuses[0].displayStatus" \
      --output tsv 2>/dev/null || echo "")
    if [ "$agent_status" = "Ready" ]; then
      log "VM agent is ready"
      return 0
    fi
    retries=$((retries + 1))
    log "VM agent not ready yet (attempt $retries/$max_retries)..."
    sleep 10
  done

  log "WARNING: VM agent readiness check timed out, proceeding anyway"
}

run_on_vm() {
  local script="$1"
  local description="${2:-Run script on VM}"
  load_state

  log "Running on VM: $description"
  az vm run-command invoke \
    --resource-group "$AZURE_VM_RG_NAME" \
    --name "$AZURE_VM_NAME" \
    --command-id RunPowerShellScript \
    --scripts "$script" \
    --output json
}

cmd_setup() {
  load_state
  log "Setting up VM environment..."

  # Install Go
  log "Installing Go ${GO_VERSION} (ARM64)..."
  run_on_vm "
    \$ErrorActionPreference = 'Stop'
    \$goVersion = '${GO_VERSION}'
    \$goUrl = \"https://go.dev/dl/go\${goVersion}.windows-arm64.zip\"
    \$goZip = \"C:\\tmp\\go.zip\"
    \$goRoot = \"C:\\go\"

    Write-Output \"Downloading Go \${goVersion} for ARM64...\"
    New-Item -ItemType Directory -Force -Path C:\\tmp | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri \$goUrl -OutFile \$goZip -UseBasicParsing

    Write-Output \"Extracting Go...\"
    if (Test-Path \$goRoot) { Remove-Item -Recurse -Force \$goRoot }
    Expand-Archive -Path \$goZip -DestinationPath C:\\ -Force

    # Set system-wide environment variables
    [Environment]::SetEnvironmentVariable('GOROOT', \$goRoot, 'Machine')
    [Environment]::SetEnvironmentVariable('GOPATH', 'C:\\gopath', 'Machine')
    \$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (\$machinePath -notlike \"*\$goRoot\\bin*\") {
      [Environment]::SetEnvironmentVariable('Path', \"\$goRoot\\bin;C:\\gopath\\bin;\$machinePath\", 'Machine')
    }

    New-Item -ItemType Directory -Force -Path C:\\gopath\\bin | Out-Null
    Write-Output \"Go installed successfully\"
    & \$goRoot\\bin\\go.exe version
  " "Install Go"

  # Install gotestsum
  log "Installing gotestsum..."
  run_on_vm "
    \$ErrorActionPreference = 'Stop'
    \$env:GOROOT = 'C:\\go'
    \$env:GOPATH = 'C:\\gopath'
    \$env:Path = \"C:\\go\\bin;C:\\gopath\\bin;\$env:Path\"

    Write-Output 'Installing gotestsum...'
    go install gotest.tools/gotestsum@latest
    Write-Output 'gotestsum installed'
    gotestsum --version
  " "Install gotestsum"

  # Create working directories
  log "Creating working directories..."
  run_on_vm "
    \$ErrorActionPreference = 'Stop'
    New-Item -ItemType Directory -Force -Path C:\\buildkit | Out-Null
    New-Item -ItemType Directory -Force -Path C:\\buildkit\\bin | Out-Null
    New-Item -ItemType Directory -Force -Path C:\\buildkit\\testreports | Out-Null
    New-Item -ItemType Directory -Force -Path C:\\tmp | Out-Null
    Write-Output 'Working directories created'
  " "Create directories"

  log "VM setup complete"
}

cmd_copy_source() {
  load_state
  local source_dir="${1:-.}"
  local blob_container="buildkit-source-${AZURE_VM_RG_NAME##*-}"

  log "Copying source and binaries to VM..."

  # Use az vm run-command to download from the GitHub Actions artifact
  # The caller is responsible for making the binaries available at a URL
  # or using a different transfer mechanism.
  #
  # For GitHub Actions, we use a storage account or direct SCP via bastion.
  # The simplest approach: tar the source, upload to a blob, download on VM.

  log "Source copy is handled by the workflow via az vm run-command"
}

cmd_destroy() {
  load_state
  local rg="${AZURE_VM_RG_NAME:-}"

  if [ -z "$rg" ]; then
    log "No resource group to delete"
    return 0
  fi

  log "Deleting resource group: $rg (async)"
  az group delete \
    --name "$rg" \
    --yes \
    --no-wait \
    --force-deletion-types Microsoft.Compute/virtualMachines \
    2>/dev/null || true

  log "Resource group deletion initiated: $rg"

  # Clean up state
  rm -rf "$STATE_DIR" 2>/dev/null || true
}

# Main dispatcher
case "${1:-}" in
  create)
    cmd_create
    ;;
  setup)
    cmd_setup
    ;;
  destroy)
    cmd_destroy
    ;;
  run-on-vm)
    shift
    run_on_vm "$@"
    ;;
  *)
    echo "Usage: $0 {create|setup|destroy|run-on-vm}"
    echo ""
    echo "Commands:"
    echo "  create     - Provision a Windows 11 ARM64 VM in Azure"
    echo "  setup      - Install Go, gotestsum, and create working directories"
    echo "  destroy    - Delete the resource group and all resources"
    echo "  run-on-vm  - Run a PowerShell script on the VM"
    echo ""
    echo "Required environment variables:"
    echo "  AZURE_VM_RG_NAME  - Resource group name"
    echo "  AZURE_LOCATION    - Azure region (default: eastus2)"
    exit 1
    ;;
esac
