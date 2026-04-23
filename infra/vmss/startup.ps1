# startup.ps1 -- VMSS instance startup script
# Runs on every boot: verifies Key Vault access, downloads the runner loop script
# from blob storage, and launches it as a background process.
#
# This script is the Custom Script Extension (CSE) entry point.
# The runner-loop.ps1 (downloaded from blob) handles:
#   register -> run one job -> re-register -> run next job -> ...
#
# Prerequisites:
#   - VMSS has user-assigned managed identity with Key Vault secret read access
#   - Key Vault 'bk-arm64-kv-wu2' has secret 'github-pat' with a PAT (repo scope)
#   - GitHub Actions runner agent pre-installed at C:\actions-runner
#   - runner-loop.ps1 uploaded to bkarm64scriptswu2 blob storage

$ErrorActionPreference = "Stop"

$KeyVaultName = "bk-arm64-kv-wu2"
$SecretName = "github-pat"
$RunnerDir = "C:\actions-runner"
$LoopScriptUrl = "https://bkarm64scriptswu2.blob.core.windows.net/scripts/runner-loop.ps1?se=2028-04-23T00%3A00%3A00Z&sp=r&sv=2026-02-06&sr=b&sig=H1YcSXcNEyliB7tWobgPaycs3Qoli8JiooPc5WeDSwg%3D"
$ManagedIdentityClientId = "a3692d8c-22d5-4a8f-9179-7fedbc7cbcca"

# Log to file for debugging
$LogFile = "C:\actions-runner\startup.log"
function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $msg" | Tee-Object -FilePath $LogFile -Append
}

Log "=== VMSS Runner Startup ==="
Log "Hostname: $env:COMPUTERNAME"

# Step 1: Verify Key Vault access (user-assigned managed identity)
Log "Verifying Key Vault access..."
try {
    $tokenResponse = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net&client_id=$ManagedIdentityClientId" `
        -Headers @{Metadata="true"} -Method GET
    $kvUri = "https://$KeyVaultName.vault.azure.net/secrets/$SecretName" + "?api-version=7.4"
    $secretResponse = Invoke-RestMethod -Uri $kvUri `
        -Headers @{Authorization="Bearer $($tokenResponse.access_token)"} -Method GET
    Log "Key Vault access verified."
} catch {
    Log "ERROR: Failed to access Key Vault: $_"
    exit 1
}

# Step 2: Download runner-loop.ps1 from blob storage
Log "Downloading runner-loop.ps1 from blob storage..."
try {
    Invoke-WebRequest -Uri $LoopScriptUrl -OutFile "$RunnerDir\runner-loop.ps1" -UseBasicParsing
    Log "runner-loop.ps1 downloaded."
} catch {
    Log "ERROR: Failed to download runner-loop.ps1: $_"
    exit 1
}

# Step 3: Start the loop script as a background process so CSE can exit
Log "Starting runner loop (background)..."
Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-ExecutionPolicy", "Bypass", "-File", "$RunnerDir\runner-loop.ps1" `
    -WindowStyle Hidden
Log "Runner loop started. CSE exiting."
