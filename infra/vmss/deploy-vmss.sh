#!/usr/bin/env bash
# deploy-vmss.sh — Create Azure Key Vault and VMSS for ephemeral GitHub Actions runners.
#
# Prerequisites:
#   - Azure CLI authenticated to CoreOS_DPLAT_WCCT_Demo subscription
#   - Golden image 'bk-arm64-runner-image' created (see create-golden-image.sh)
#   - A GitHub PAT with 'repo' scope
#
# Usage: ./deploy-vmss.sh

set -euo pipefail

RG="buildkit-arm64-runner-rg"
LOCATION="eastus2"
KV_NAME="bk-arm64-kv"
VMSS_NAME="arm64-runner-ss"
IMAGE_NAME="bk-arm64-runner-image"
VM_SIZE="Standard_D4pds_v6"
ADMIN_USER="bkrunner"
MIN_INSTANCES=0
MAX_INSTANCES=12

# Parse optional flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sku) VM_SIZE="$2"; shift 2 ;;
    *)     shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== VMSS Ephemeral Runner Deployment ==="
echo "RG: $RG | VMSS: $VMSS_NAME | Image: $IMAGE_NAME"
echo "Size: $VM_SIZE | Min: $MIN_INSTANCES | Max: $MAX_INSTANCES"
echo ""

# Step 1: Verify golden image exists
echo ">>> Step 1: Verifying golden image..."
IMAGE_ID=$(az image show --resource-group "$RG" --name "$IMAGE_NAME" --query id -o tsv 2>/dev/null) || {
  echo "ERROR: Golden image '$IMAGE_NAME' not found. Run create-golden-image.sh first."
  exit 1
}
echo "Image found: $IMAGE_ID"

# Step 2: Create Key Vault
echo ""
echo ">>> Step 2: Creating Key Vault '$KV_NAME'..."
if az keyvault show --name "$KV_NAME" --resource-group "$RG" &>/dev/null; then
  echo "Key Vault already exists."
else
  az keyvault create \
    --resource-group "$RG" \
    --name "$KV_NAME" \
    --location "$LOCATION" \
    --enable-rbac-authorization false \
    --output table
  echo "Key Vault created."
fi

# Step 3: Store GitHub PAT in Key Vault
echo ""
echo ">>> Step 3: Storing GitHub PAT..."
read -sp "Enter GitHub PAT (repo scope): " GITHUB_PAT
echo ""
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name "github-pat" \
  --value "$GITHUB_PAT" \
  --output none
echo "PAT stored in Key Vault."

# Step 4: Create VMSS
echo ""
echo ">>> Step 4: Creating VMSS '$VMSS_NAME'..."
read -sp "Enter admin password for $ADMIN_USER: " ADMIN_PASS
echo ""

az vmss create \
  --resource-group "$RG" \
  --name "$VMSS_NAME" \
  --image "$IMAGE_ID" \
  --vm-sku "$VM_SIZE" \
  --instance-count "$MIN_INSTANCES" \
  --admin-username "$ADMIN_USER" \
  --admin-password "$ADMIN_PASS" \
  --upgrade-policy-mode manual \
  --single-placement-group false \
  --platform-fault-domain-count 1 \
  --orchestration-mode Uniform \
  --os-disk-size-gb 128 \
  --assign-identity '[system]' \
  --location "$LOCATION" \
  --output table

echo "VMSS created."

# Step 5: Grant VMSS managed identity access to Key Vault
echo ""
echo ">>> Step 5: Granting VMSS identity Key Vault access..."
VMSS_IDENTITY=$(az vmss identity show \
  --resource-group "$RG" \
  --name "$VMSS_NAME" \
  --query principalId -o tsv)

az keyvault set-policy \
  --name "$KV_NAME" \
  --object-id "$VMSS_IDENTITY" \
  --secret-permissions get \
  --output none

echo "VMSS identity ($VMSS_IDENTITY) granted Key Vault secret read access."

# Step 6: Install Custom Script Extension
echo ""
echo ">>> Step 6: Installing startup script extension..."

# Encode startup script as base64 for inline delivery
STARTUP_B64=$(base64 -w0 "$SCRIPT_DIR/startup.ps1")

az vmss extension set \
  --resource-group "$RG" \
  --vmss-name "$VMSS_NAME" \
  --name CustomScriptExtension \
  --publisher Microsoft.Compute \
  --version 1.10 \
  --settings "{
    \"commandToExecute\": \"powershell -ExecutionPolicy Bypass -EncodedCommand $STARTUP_B64\"
  }" \
  --output table

echo "Startup script extension configured."

# Step 7: Configure auto-scaling (basic CPU-based, as fallback to webhook)
echo ""
echo ">>> Step 7: Configuring auto-scale rules..."
az monitor autoscale create \
  --resource-group "$RG" \
  --resource "$VMSS_NAME" \
  --resource-type Microsoft.Compute/virtualMachineScaleSets \
  --name "${VMSS_NAME}-autoscale" \
  --min-count "$MIN_INSTANCES" \
  --max-count "$MAX_INSTANCES" \
  --count "$MIN_INSTANCES" \
  --output none 2>/dev/null || echo "Note: autoscale may need manual setup for webhook-based scaling."

echo ""
echo "=== VMSS Deployment Complete ==="
echo ""
echo "VMSS: $VMSS_NAME (0 instances, ready to scale)"
echo "Key Vault: $KV_NAME (PAT stored)"
echo ""
echo "To manually scale up for testing:"
echo "  az vmss scale --resource-group $RG --name $VMSS_NAME --new-capacity 2"
echo ""
echo "To scale back to 0:"
echo "  az vmss scale --resource-group $RG --name $VMSS_NAME --new-capacity 0"
echo ""
echo "Next steps:"
echo "  1. Scale up to 1-2 instances and verify runners appear at:"
echo "     https://github.com/rzlink/buildkit/settings/actions/runners"
echo "  2. Dispatch a test CI run"
echo "  3. Set up webhook-based scaling (see scale-func/)"
echo "  4. Delete temporary VMs after validation"
