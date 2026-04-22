#!/usr/bin/env bash
# patch-golden-image.sh — Weekly security patching for the ARM64 runner golden image.
#
# Boots a temporary VM from the current golden image (stored in a Shared Image
# Gallery), applies Windows Updates, updates installed toolchains to latest
# versions, syspreps, and captures a new gallery image version. Updates the VMSS
# model and cleans up old versions (keeps last 2).
#
# Prerequisites:
#   - Azure CLI authenticated
#   - Shared Image Gallery 'bkarm64gallery' with image definition 'bk-arm64-runner'
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
VM_NAME="bkpatch$(date +%Y%m%d)"
VM_SIZE="Standard_D4pds_v6"
FALLBACK_SKUS=(Standard_D4ps_v6 Standard_D4pds_v5 Standard_D4plds_v6)
GALLERY_NAME="bkarm64gallery"
IMAGE_DEF="bk-arm64-runner"
VMSS_NAME="arm64-runner-ss"
ADMIN_USER="bkrunner"
VERSIONS_TO_KEEP=2
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
          {"title":"Gallery","value":"${GALLERY_NAME}/${IMAGE_DEF}"},
          {"title":"Version","value":"${NEW_VERSION:-unknown}"},
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
log "Gallery:  $GALLERY_NAME/$IMAGE_DEF"
log "VM size:  $VM_SIZE"
log "Dry run:  $DRY_RUN"

if [[ "$DRY_RUN" == true ]]; then
    log "Dry run mode — exiting without making changes"
    exit 0
fi

# ─── Step 1: Find latest gallery image version ──────────────────────────────
log "Step 1: Finding latest gallery image version..."
LATEST_VERSION=$(az sig image-version list \
    --resource-group "$RG" \
    --gallery-name "$GALLERY_NAME" \
    --gallery-image-definition "$IMAGE_DEF" \
    --query "sort_by([].{name:name, date:publishingProfile.publishedDate}, &date)[-1].name" \
    -o tsv 2>/dev/null) || LATEST_VERSION=""

if [[ -z "$LATEST_VERSION" ]]; then
    err "No image versions found in $GALLERY_NAME/$IMAGE_DEF"
    notify "⚠️ Image Patching Failed" "No gallery image versions found" "Attention"
    exit 1
fi

IMAGE_ID="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.Compute/galleries/$GALLERY_NAME/images/$IMAGE_DEF/versions/$LATEST_VERSION"
log "Latest version: $LATEST_VERSION"
log "Image ID: $IMAGE_ID"

# Compute next version: increment the minor component (e.g., 1.0.0 → 1.1.0)
IFS='.' read -r V_MAJOR V_MINOR V_PATCH <<< "$LATEST_VERSION"
NEW_VERSION="${V_MAJOR}.$(( V_MINOR + 1 )).0"
log "New version will be: $NEW_VERSION"

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

SYSPREP_TIMEOUT=90  # 90 × 10s = 15 minutes
log "Waiting for VM to shut down after sysprep (up to 15 minutes)..."
SYSPREP_OK=false
for i in $(seq 1 "$SYSPREP_TIMEOUT"); do
    state=$(az vm get-instance-view --resource-group "$RG" --name "$VM_NAME" \
        --query "instanceView.statuses[1].displayStatus" -o tsv 2>/dev/null)
    if [[ "$state" == *"stopped"* ]] || [[ "$state" == *"deallocated"* ]]; then
        log "VM stopped after sysprep."
        SYSPREP_OK=true
        break
    fi
    log "  [$i/$SYSPREP_TIMEOUT] State: $state"
    sleep 10
done

if [[ "$SYSPREP_OK" != "true" ]]; then
    log "ERROR: Sysprep did not shut down VM within 15 minutes — aborting capture."
    log "Deleting temporary VM to avoid leaving broken resources..."
    az vm delete --resource-group "$RG" --name "$VM_NAME" --yes --no-wait 2>/dev/null || true
    exit 1
fi

log "Deallocating VM..."
az vm deallocate --resource-group "$RG" --name "$VM_NAME"

log "Generalizing VM..."
az vm generalize --resource-group "$RG" --name "$VM_NAME"

log "Capturing as gallery image version '$NEW_VERSION'..."
VM_ID=$(az vm show --resource-group "$RG" --name "$VM_NAME" --query id -o tsv)
az sig image-version create \
    --resource-group "$RG" \
    --gallery-name "$GALLERY_NAME" \
    --gallery-image-definition "$IMAGE_DEF" \
    --gallery-image-version "$NEW_VERSION" \
    --virtual-machine "$VM_ID" \
    --target-regions "$LOCATION" \
    --replica-count 1 \
    --output table

NEW_IMAGE_ID=$(az sig image-version show \
    --resource-group "$RG" \
    --gallery-name "$GALLERY_NAME" \
    --gallery-image-definition "$IMAGE_DEF" \
    --gallery-image-version "$NEW_VERSION" \
    --query id -o tsv 2>/dev/null)
log "New image version created: $NEW_IMAGE_ID"

# ─── Step 7: Update VMSS model to use new gallery version ───────────────────
log "Step 7: Updating VMSS model..."
az vmss update \
    --resource-group "$RG" \
    --name "$VMSS_NAME" \
    --set "virtualMachineProfile.storageProfile.imageReference.id=$NEW_IMAGE_ID" \
    --output none 2>/dev/null && log "VMSS model updated to version $NEW_VERSION" || {
    err "Failed to update VMSS model — manual update required"
    notify "⚠️ Image Patching — Manual Action Needed" "Version $NEW_VERSION created but VMSS update failed" "Warning"
}

# Smoke test: provision one instance to verify the image works
log "Smoke test: provisioning 1 VMSS instance to verify image..."
if az vmss scale --resource-group "$RG" --name "$VMSS_NAME" --new-capacity 1 --output none 2>/dev/null; then
    log "✓  Smoke test passed — image provisions correctly"
    az vmss scale --resource-group "$RG" --name "$VMSS_NAME" --new-capacity 0 --no-wait --output none 2>/dev/null
else
    log "ERROR: Smoke test FAILED — new image cannot provision VMs"
    log "Reverting VMSS to previous version $LATEST_VERSION..."
    PREV_IMAGE_ID=$(az sig image-version show \
        --resource-group "$RG" \
        --gallery-name "$GALLERY_NAME" \
        --gallery-image-definition "$IMAGE_DEF" \
        --gallery-image-version "$LATEST_VERSION" \
        --query id -o tsv 2>/dev/null)
    az vmss update --resource-group "$RG" --name "$VMSS_NAME" \
        --set "virtualMachineProfile.storageProfile.imageReference.id=$PREV_IMAGE_ID" \
        --output none 2>/dev/null
    az vmss scale --resource-group "$RG" --name "$VMSS_NAME" --new-capacity 0 --no-wait --output none 2>/dev/null
    log "VMSS reverted to version $LATEST_VERSION"
    notify "❌ Image Patching Failed" "Version $NEW_VERSION failed smoke test. VMSS reverted to $LATEST_VERSION." "Failure"
    exit 1
fi

# ─── Step 8: Clean up old gallery versions (keep last N) ─────────────────────
log "Step 8: Cleaning up old versions (keeping last $VERSIONS_TO_KEEP)..."
OLD_VERSIONS=$(az sig image-version list \
    --resource-group "$RG" \
    --gallery-name "$GALLERY_NAME" \
    --gallery-image-definition "$IMAGE_DEF" \
    --query "sort_by([].{name:name, date:publishingProfile.publishedDate}, &date)[:-${VERSIONS_TO_KEEP}].name" \
    -o tsv 2>/dev/null)

if [[ -n "$OLD_VERSIONS" ]]; then
    while IFS= read -r ver; do
        [[ -z "$ver" ]] && continue
        log "  Deleting old version: $ver"
        az sig image-version delete \
            --resource-group "$RG" \
            --gallery-name "$GALLERY_NAME" \
            --gallery-image-definition "$IMAGE_DEF" \
            --gallery-image-version "$ver" \
            --no-wait 2>/dev/null || true
    done <<< "$OLD_VERSIONS"
else
    log "  No old versions to clean up"
fi

# ─── Done ────────────────────────────────────────────────────────────────────
# Disable the EXIT trap since we succeeded (cleanup_vm would try to delete)
trap - EXIT
# But we still want to clean up the temp VM
cleanup_vm

log "=== Image patching complete ==="
log "New version: $GALLERY_NAME/$IMAGE_DEF:$NEW_VERSION"
log "VMSS updated: $VMSS_NAME"

notify "✅ Golden Image Patched" "Version $NEW_VERSION created and VMSS updated successfully" "Good"
