# Azure ARM64 Windows Testing Setup

This guide describes how to set up Azure infrastructure for running BuildKit CI
tests on Windows ARM64 virtual machines. The setup uses Azure OIDC (Workload
Identity Federation) for secure, secretless authentication from GitHub Actions.

## Overview

Since GitHub Actions does not offer ARM64 Windows runners, BuildKit CI
provisions Azure Windows 11 ARM64 VMs on-demand for each test shard. The
workflow:

1. Cross-compiles `windows/arm64` binaries via Docker Buildx (on Linux)
2. Provisions an Azure Windows 11 ARM64 VM per test matrix entry
3. Copies source and binaries to the VM
4. Runs `gotestsum` on the VM via `az vm run-command`
5. Collects test reports and destroys the VM

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and authenticated
- An Azure subscription with permission to create VMs and app registrations
- [GitHub CLI](https://cli.github.com/) (optional, for setting secrets via CLI)
- Owner or User Access Administrator role on the target subscription

## Step 1: Create an Azure AD App Registration

Create an app registration that GitHub Actions will authenticate as:

```bash
az ad app create \
  --display-name "buildkit-ci-arm64-tests" \
  --service-management-reference "<your-service-management-reference-uuid>"
```

> **Note**: The `--service-management-reference` parameter may be required by
> your organization's Azure AD policy. Find it by checking existing app
> registrations in your tenant:
>
> ```bash
> az ad app list --query "[].{name:displayName, smr:serviceManagementReference}" -o table
> ```

Save the `appId` from the output — this is your **Client ID**.

```bash
APP_ID="<appId from output>"
```

Then create a service principal for the app:

```bash
az ad sp create --id $APP_ID
```

Save the `id` from this output — this is the **Service Principal Object ID**.

```bash
SP_OBJECT_ID="<id from output>"
```

## Step 2: Add OIDC Federated Credentials

Configure trust between GitHub Actions and your Azure AD app so that GitHub
can request tokens without storing any secrets.

### For the upstream repository (moby/buildkit)

```bash
# Master branch pushes
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-actions-master",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:moby/buildkit:ref:refs/heads/master",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "GitHub Actions OIDC for master branch"
}'

# Pull requests (only from same-repo branches, not forks)
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-actions-pr",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:moby/buildkit:pull_request",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "GitHub Actions OIDC for pull requests"
}'
```

### For a fork (e.g., rzlink/buildkit)

If testing on a fork, add credentials for that repo too:

```bash
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-actions-fork-master",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/buildkit:ref:refs/heads/master",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "GitHub Actions OIDC for fork master branch"
}'

az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-actions-fork-pr",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/buildkit:pull_request",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "GitHub Actions OIDC for fork PRs"
}'
```

### For release branches

Azure AD does not support wildcards in the `subject` field, so you must add one
credential per release branch:

```bash
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-actions-v0-18",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:moby/buildkit:ref:refs/heads/v0.18",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "GitHub Actions OIDC for v0.18 branch"
}'
```

> **Limit**: Azure AD allows up to 20 federated credentials per app
> registration. If you need more, consider using the `environment` subject
> filter instead of per-branch entries.

### Verify credentials

```bash
az ad app federated-credential list --id $APP_ID -o table
```

## Step 3: Grant Azure Permissions

The service principal needs Contributor access to create resource groups, VMs,
and storage accounts:

```bash
SUBSCRIPTION_ID="<your-subscription-id>"

az role assignment create \
  --assignee-object-id $SP_OBJECT_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

> **Least-privilege alternative**: If you prefer tighter scoping, create a
> dedicated resource group and assign Contributor there. However, the CI
> scripts create per-job resource groups dynamically, which requires
> subscription-level permissions.

## Step 4: Add GitHub Repository Secrets

Add three secrets to the GitHub repository that runs the workflow. You can use
the GitHub web UI (**Settings → Secrets and variables → Actions**) or the CLI:

```bash
REPO="<owner>/buildkit"  # e.g., moby/buildkit or rzlink/buildkit

echo "<appId>" | gh secret set AZURE_CLIENT_ID --repo $REPO
echo "<tenantId>" | gh secret set AZURE_TENANT_ID --repo $REPO
echo "<subscriptionId>" | gh secret set AZURE_SUBSCRIPTION_ID --repo $REPO
```

To find the tenant and subscription IDs:

```bash
az account show --query "{tenantId:tenantId, subscriptionId:id}" -o table
```

> **Security**: These are not sensitive secrets (they are UUIDs, not passwords).
> The actual authentication uses short-lived OIDC tokens that are generated
> per-workflow-run and cannot be reused.

## Step 5: Verify ARM64 VM Quota

Check that you have sufficient Dpsv6-series vCPU quota. The CI runs up to 21
parallel VMs at 4 vCPUs each (84 vCPUs total):

```bash
az vm list-usage --location eastus2 \
  --query "[?contains(name.value, 'Dpsv6')]" -o table
```

If the limit is less than 84, request an increase:

1. Go to **Azure Portal → Subscriptions → \<your sub\> → Usage + quotas**
2. Search for `Dpsv6`
3. Click **Request increase** and set the new limit to at least 100

## Step 6: Verify Windows 11 ARM64 Image Availability

Confirm that Windows 11 ARM64 images are available in your target region:

```bash
az vm image list \
  --publisher MicrosoftWindowsDesktop \
  --offer windows11preview-arm64 \
  --location eastus2 \
  --all \
  --query "[?architecture=='Arm64'].{sku:sku, version:version}" \
  -o table
```

If no images are listed, try a different region (e.g., `westus3`,
`northeurope`, `uksouth`). Update `AZURE_LOCATION` in the workflow to match.

## Workflow Configuration

The `test-windows-arm64` job in `.github/workflows/test-os.yml` uses these
secrets and the `azure/login@v2` action:

```yaml
test-windows-arm64:
  if: ${{ github.repository == 'moby/buildkit' }}
  runs-on: ubuntu-24.04
  permissions:
    contents: read
    id-token: write  # Required for OIDC
  steps:
    - uses: azure/login@v2
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    # ... VM provisioning and test steps
```

Key settings in the workflow:

| Variable | Default | Description |
|---|---|---|
| `AZURE_LOCATION` | `eastus2` | Azure region for VM provisioning |
| `AZURE_VM_SIZE` | `Standard_D4ps_v6` | VM size (4 vCPUs, 16GB, ARM64) |
| `GO_VERSION` | `1.26` | Go version installed on the VM |

## Replicating to Another Subscription

To replicate this setup on a different Azure subscription:

1. Log in to the target subscription:
   ```bash
   az account set --subscription "<new-subscription-id>"
   ```

2. Repeat **Steps 1–2** (app registration and federated credentials can be
   reused across subscriptions if in the same Azure AD tenant; otherwise create
   a new app).

3. Repeat **Step 3** with the new subscription ID:
   ```bash
   az role assignment create \
     --assignee-object-id $SP_OBJECT_ID \
     --assignee-principal-type ServicePrincipal \
     --role "Contributor" \
     --scope "/subscriptions/<new-subscription-id>"
   ```

4. Update `AZURE_SUBSCRIPTION_ID` in GitHub secrets.

5. Repeat **Steps 5–6** to verify quota and image availability in the new
   subscription's target region.

## Cleanup

To remove all resources created by this setup:

```bash
# Delete federated credentials
az ad app federated-credential list --id $APP_ID --query "[].id" -o tsv | \
  while read cred_id; do
    az ad app federated-credential delete --id $APP_ID --federated-credential-id "$cred_id"
  done

# Delete the service principal
az ad sp delete --id $APP_ID

# Delete the app registration
az ad app delete --id $APP_ID

# Remove any leftover CI resource groups
az group list --tag purpose=buildkit-ci --query "[].name" -o tsv | \
  while read rg; do
    az group delete --name "$rg" --yes --no-wait
  done
```

## Troubleshooting

### OIDC login fails with "No matching federated identity record found"

- Verify the `subject` field matches exactly. Check with:
  ```bash
  az ad app federated-credential list --id $APP_ID -o table
  ```
- For PRs from forks: OIDC is not available. This is a GitHub security
  restriction.
- The `subject` format differs by trigger:
  - Push: `repo:<owner>/<repo>:ref:refs/heads/<branch>`
  - PR: `repo:<owner>/<repo>:pull_request`
  - Tag: `repo:<owner>/<repo>:ref:refs/tags/<tag>`

### VM creation fails with "SkuNotAvailable"

The ARM64 VM size may not be available in your region. Check availability:

```bash
az vm list-skus --location eastus2 --size Standard_D4ps_v6 -o table
```

Try alternative regions or VM sizes (`Standard_D2ps_v6` for 2 vCPUs).

### VM creation fails with "QuotaExceeded"

Request a quota increase for the `Standard DPSv6 Family vCPUs` in your target
region (see Step 5).

### "ServiceManagementReference field is required" error

Your Azure AD tenant requires this field. Find it from existing app
registrations:

```bash
az ad app list --query "[?serviceManagementReference!=null].{name:displayName, smr:serviceManagementReference}" -o table
```
