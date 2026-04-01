#!/usr/bin/env bash
# patch-golden-image.sh — Weekly security patching for the ARM64 runner golden image.
#
# Boots a temporary VM from the current golden image, applies Windows Updates,
# updates installed toolchains to latest versions, syspreps, and captures a new
# dated image. Updates the VMSS model and cleans up old images (keeps last 2).
#
# Prerequisites:
#   - Azure CLI authenticated
#   - Existing golden image 'bk-arm64-runner-image' in the resource group
#
# Usage:
#   ./patch-golden-image.sh [--sku SKU] [--notify WEBHOOK_URL] [--dry-run]
#
# Cron (Sunday 6am UTC):
#   0 6 * * 0 /home/rzlink/github/buildkit-arm64/infra/vmss/patch-golden-image.sh \
#     --notify "$(cat ~/.config/run-ci/teams.env | grep TEAMS_WEBHOOK_URL | cut -d= -f2-)" \
#     >> ~/.local/log/patch-image-$(date +\%Y\%m\%d).log 2>&1

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
RG="buildkit-arm64-runner-rg"
LOCATION="eastus2"
VM_NAME="bk-arm64-patch-$(date +%Y%m%d)"
VM_SIZE="Standard_D4pds_v6"
FALLBACK_SKUS=(Standard_D4ps_v6 Standard_D4pds_v5 Standard_D4plds_v6)
BASE_IMAGE_NAME="bk-arm64-runner-image"
NEW_IMAGE_NAME="bk-arm64-runner-image-$(date +%Y%m%d)"
VMSS_NAME="arm64-runner-ss"
ADMIN_USER="bkrunner"
IMAGES_TO_KEEP=2
WEBHOOK_URL=""
DRY_RUN=false

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sku)     VM_SIZE="$2"; shift 2 ;;
        --notify)  WEBHOOK_URL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *)         shift ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

notify() {
    local title="$1" detail="$2" color="${3:-Default}"
    [[ -z "$WEBHOOK_URL" ]] && return 0
    # Load from env file if variable is a path
    if [[ -f "$HOME/.config/run-ci/teams.env" ]] && [[ -z "$WEBHOOK_URL" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.config/run-ci/teams.env"
        WEBHOOK_URL="${TEAMS_WEBHOOK_URL:-}"
    fi
    [[ -z "$WEBHOOK_URL" ]] && return 0
    local payload
    payload=$(cat <<ENDJSON
{
  "type": "message",
  "attachments": [{
    "contentType": "application/vnd.microsoft.card.adaptive",
    "content": {
      "type": "AdaptiveCard",
      "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
      "version": "1.4",
      "msteams": {"width": "Full"},
      "body": [
        {"type":"TextBlock","text":"${title}","weight":"Bolder","size":"Medium","wrap":true,"color":"${color}"},
        {"type":"TextBlock","text":"${detail}","wrap":true,"spacing":"Small"},
        {"type":"FactSet","facts":[
          {"title":"Image","value":"${NEW_IMAGE_NAME}"},
          {"title":"SKU","value":"${VM_SIZE}"},
          {"title":"Time","value":"$(date -u '+%Y-%m-%d %H:%M UTC')"}
        ]}
      ]
    }
  }]
}
ENDJSON
)
    curl -s -o /dev/null -X POST "$WEBHOOK_URL" -H "Content-Type: application/json" -d "$payload" 2>/dev/null || true
}

cleanup_vm() {
    log "Cleaning up temporary VM ($VM_NAME)..."
    az vm delete --resource-group "$RG" --name "$VM_NAME" --yes --no-wait 2>/dev/null || true
    # Clean up associated resources (NIC, disk, NSG, public IP)
    sleep 10
    for res in $(az resource list --resource-group "$RG" --query "[?contains(name,'$VM_NAME')].id" -o tsv 2>/dev/null); do
        az resource delete --ids "$res" --no-wait 2>/dev/null || true
    done
}
trap cleanup_vm EXIT

run_command() {
    local desc="$1"
    local script="$2"
    log "$desc"
    az vm run-command invoke \
        --resource-group "$RG" \
        --name "$VM_NAME" \
        --command-id RunPowerShellScript \
        --scripts "$script" \
        --output json 2>/dev/null | jq -r '.value[0].message' 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
log "=== Golden Image Patching ==="
log "Base image: $BASE_IMAGE_NAME"
log "New image:  $NEW_IMAGE_NAME"
log "VM size:    $VM_SIZE"
log "Dry run:    $DRY_RUN"

if [[ "$DRY_RUN" == true ]]; then
    log "Dry run mode — exiting without making changes"
    exit 0
fi

# ─── Step 1: Verify base image exists ────────────────────────────────────────
log "Step 1: Verifying base image..."
IMAGE_ID=$(az image show --resource-group "$RG" --name "$BASE_IMAGE_NAME" --query id -o tsv 2>/dev/null) || {
    err "Base image '$BASE_IMAGE_NAME' not found"
    notify "⚠️ Image Patching Failed" "Base image not found: $BASE_IMAGE_NAME" "Attention"
    exit 1
}
log "Base image found: $IMAGE_ID"

# ─── Step 2: Create temporary VM from the golden image ───────────────────────
log "Step 2: Creating temporary VM..."

# Generate a random password
ADMIN_PASS="Patch$(openssl rand -hex 8)!"

# Try primary SKU, then fallbacks
VM_CREATED=false
ALL_SKUS=("$VM_SIZE" "${FALLBACK_SKUS[@]}")
for sku in "${ALL_SKUS[@]}"; do
    log "Trying SKU: $sku"
    if az vm create \
        --resource-group "$RG" \
        --name "$VM_NAME" \
        --image "$IMAGE_ID" \
        --size "$sku" \
        --admin-username "$ADMIN_USER" \
        --admin-password "$ADMIN_PASS" \
        --os-disk-size-gb 128 \
        --public-ip-sku Standard \
        --nsg-rule NONE \
        --location "$LOCATION" \
        --output none 2>&1; then
        VM_SIZE="$sku"
        VM_CREATED=true
        log "VM created with SKU: $sku"
        break
    else
        log "SKU $sku unavailable, trying next..."
        # Clean up partial resources
        az vm delete --resource-group "$RG" --name "$VM_NAME" --yes --no-wait 2>/dev/null || true
        sleep 15
    fi
done

if [[ "$VM_CREATED" != true ]]; then
    err "Failed to create VM with any SKU: ${ALL_SKUS[*]}"
    notify "⚠️ Image Patching Failed" "No ARM64 SKU available for patching (tried: ${ALL_SKUS[*]})" "Attention"
    exit 1
fi

log "Waiting 90s for Windows to fully boot..."
sleep 90

# ─── Step 3: Apply Windows Updates ───────────────────────────────────────────
log "Step 3: Applying Windows Updates..."
run_command "Installing PSWindowsUpdate module..." '
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false
Install-Module PSWindowsUpdate -Force -Confirm:$false
Write-Output "PSWindowsUpdate module installed."
'

run_command "Downloading and installing Windows Updates..." '
$ErrorActionPreference = "Stop"
Import-Module PSWindowsUpdate
$updates = Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -Confirm:$false 2>&1
$count = ($updates | Where-Object { $_ -match "Installed|Downloaded" }).Count
Write-Output "Windows Update complete: $count updates applied."
'

# ─── Step 4: Update toolchains ───────────────────────────────────────────────
log "Step 4: Updating toolchains..."
run_command "Updating Git, Go, Node, Python, Runner..." '
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path C:\temp | Out-Null

# --- Git: fetch latest ARM64 release ---
Write-Output "Checking Git updates..."
try {
    $gitReleases = Invoke-RestMethod "https://api.github.com/repos/git-for-windows/git/releases/latest" -UseBasicParsing
    $gitAsset = $gitReleases.assets | Where-Object { $_.name -match "Git-.*-arm64\.exe$" } | Select-Object -First 1
    if ($gitAsset) {
        $currentGit = & "C:\Program Files\Git\cmd\git.exe" --version 2>$null
        Write-Output "Current Git: $currentGit"
        Write-Output "Latest Git: $($gitAsset.name)"
        Invoke-WebRequest -Uri $gitAsset.browser_download_url -OutFile C:\temp\git.exe -UseBasicParsing
        Start-Process C:\temp\git.exe -ArgumentList "/VERYSILENT","/NORESTART","/NOCANCEL","/SP-" -Wait
        Write-Output "Git updated to: $(& "C:\Program Files\Git\cmd\git.exe" --version)"
    }
} catch { Write-Output "Git update skipped: $_" }

# --- Go: fetch latest stable ---
Write-Output "Checking Go updates..."
try {
    $goVersions = Invoke-RestMethod "https://go.dev/dl/?mode=json" -UseBasicParsing
    $latestGo = $goVersions[0].version
    $currentGo = & "C:\go\bin\go.exe" version 2>$null
    Write-Output "Current Go: $currentGo"
    Write-Output "Latest Go: $latestGo"
    $goUrl = "https://go.dev/dl/${latestGo}.windows-arm64.zip"
    Invoke-WebRequest -Uri $goUrl -OutFile C:\temp\go.zip -UseBasicParsing
    Remove-Item -Recurse -Force C:\go -ErrorAction SilentlyContinue
    Expand-Archive C:\temp\go.zip -DestinationPath C:\ -Force
    Write-Output "Go updated to: $(& "C:\go\bin\go.exe" version)"
} catch { Write-Output "Go update skipped: $_" }

# --- GitHub Actions Runner: fetch latest ARM64 ---
Write-Output "Checking Runner updates..."
try {
    $runnerReleases = Invoke-RestMethod "https://api.github.com/repos/actions/runner/releases/latest" -UseBasicParsing
    $runnerAsset = $runnerReleases.assets | Where-Object { $_.name -match "actions-runner-win-arm64-.*\.zip$" } | Select-Object -First 1
    if ($runnerAsset) {
        Write-Output "Latest runner: $($runnerAsset.name)"
        Invoke-WebRequest -Uri $runnerAsset.browser_download_url -OutFile C:\temp\runner.zip -UseBasicParsing
        # Preserve config but update binaries
        $preserve = @("_diag", ".credentials", ".runner", "runner-loop.ps1", "startup.log", "runner-loop.log")
        Get-ChildItem C:\actions-runner -Exclude $preserve | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive C:\temp\runner.zip -DestinationPath C:\actions-runner -Force
        Write-Output "Runner updated."
    }
} catch { Write-Output "Runner update skipped: $_" }

Remove-Item -Recurse -Force C:\temp -ErrorAction SilentlyContinue
Write-Output "Toolchain updates complete."
'

# ─── Step 5: Verify installations ────────────────────────────────────────────
log "Step 5: Verifying installations..."
run_command "Verification" '
Write-Output "Git: $(& "C:\Program Files\Git\cmd\git.exe" --version)"
Write-Output "Go: $(& "C:\go\bin\go.exe" version)"
Write-Output "Node: $(& "C:\nodejs\node.exe" --version)"
Write-Output "Python: $(& "C:\Program Files\Python312-arm64\python.exe" --version)"
Write-Output "Runner: $(Test-Path C:\actions-runner\run.cmd)"
Write-Output "Containers: $((Get-WindowsOptionalFeature -Online -FeatureName Containers).State)"
'

# ─── Step 6: Sysprep and capture ─────────────────────────────────────────────
log "Step 6: Running sysprep..."
az vm run-command invoke \
    --resource-group "$RG" \
    --name "$VM_NAME" \
    --command-id RunPowerShellScript \
    --scripts '
Remove-Item -Recurse -Force C:\Windows\Temp\* -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Users\bkrunner\AppData\Local\Temp\*" -ErrorAction SilentlyContinue
& C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet
' --output json 2>/dev/null | jq -r '.value[0].message' 2>/dev/null || true

log "Waiting for VM to shut down after sysprep (up to 5 minutes)..."
for i in $(seq 1 30); do
    state=$(az vm get-instance-view --resource-group "$RG" --name "$VM_NAME" \
        --query "instanceView.statuses[1].displayStatus" -o tsv 2>/dev/null)
    if [[ "$state" == *"stopped"* ]] || [[ "$state" == *"deallocated"* ]]; then
        log "VM stopped."
        break
    fi
    log "  [$i/30] State: $state"
    sleep 10
done

log "Deallocating VM..."
az vm deallocate --resource-group "$RG" --name "$VM_NAME"

log "Generalizing VM..."
az vm generalize --resource-group "$RG" --name "$VM_NAME"

log "Capturing image as '$NEW_IMAGE_NAME'..."
az image create \
    --resource-group "$RG" \
    --name "$NEW_IMAGE_NAME" \
    --source "$VM_NAME" \
    --os-type Windows \
    --hyper-v-generation V2 \
    --location "$LOCATION" \
    --output table

NEW_IMAGE_ID=$(az image show --resource-group "$RG" --name "$NEW_IMAGE_NAME" --query id -o tsv 2>/dev/null)
log "New image created: $NEW_IMAGE_ID"

# ─── Step 7: Update the canonical image alias ───────────────────────────────
log "Step 7: Updating canonical image '$BASE_IMAGE_NAME' → '$NEW_IMAGE_NAME'..."
# Delete old canonical image and recreate pointing to the new source
# (Azure managed images can't be "renamed", so we recreate the alias)
az image delete --resource-group "$RG" --name "$BASE_IMAGE_NAME" 2>/dev/null || true
az image create \
    --resource-group "$RG" \
    --name "$BASE_IMAGE_NAME" \
    --source "$VM_NAME" \
    --os-type Windows \
    --hyper-v-generation V2 \
    --location "$LOCATION" \
    --output none 2>/dev/null || log "Note: canonical alias update skipped (VM already generalized)"

# ─── Step 8: Update VMSS model to use new image ─────────────────────────────
log "Step 8: Updating VMSS model..."
az vmss update \
    --resource-group "$RG" \
    --name "$VMSS_NAME" \
    --set "virtualMachineProfile.storageProfile.imageReference.id=$NEW_IMAGE_ID" \
    --output none 2>/dev/null && log "VMSS model updated to $NEW_IMAGE_NAME" || {
    err "Failed to update VMSS model — manual update required"
    notify "⚠️ Image Patching — Manual Action Needed" "Image $NEW_IMAGE_NAME created but VMSS model update failed" "Warning"
}

# ─── Step 9: Clean up old dated images (keep last N) ─────────────────────────
log "Step 9: Cleaning up old images (keeping last $IMAGES_TO_KEEP)..."
OLD_IMAGES=$(az image list --resource-group "$RG" \
    --query "[?starts_with(name,'bk-arm64-runner-image-')].name" -o tsv 2>/dev/null \
    | sort -r | tail -n +$(( IMAGES_TO_KEEP + 1 )))

if [[ -n "$OLD_IMAGES" ]]; then
    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        log "  Deleting old image: $img"
        az image delete --resource-group "$RG" --name "$img" --no-wait 2>/dev/null || true
    done <<< "$OLD_IMAGES"
else
    log "  No old images to clean up"
fi

# ─── Done ────────────────────────────────────────────────────────────────────
# Disable the EXIT trap since we succeeded (cleanup_vm would try to delete)
trap - EXIT
# But we still want to clean up the temp VM
cleanup_vm

log "=== Image patching complete ==="
log "New image: $NEW_IMAGE_NAME"
log "VMSS updated: $VMSS_NAME"

notify "✅ Golden Image Patched" "Image $NEW_IMAGE_NAME created and VMSS updated successfully" "Good"
