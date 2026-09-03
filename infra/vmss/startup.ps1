# startup.ps1 -- VMSS instance startup script (self-contained)
# Runs on every boot via Custom Script Extension.
# Downloaded from blob storage using VMSS managed identity (no SAS/shared key).
#
# Flow:
#   1. Verify Key Vault access via managed identity
#   2. Write runner-loop.ps1 to disk (embedded below)
#   3. Launch runner loop as independent process so CSE can exit
#
# Prerequisites:
#   - VMSS has system-assigned managed identity with Key Vault secret read access
#   - Key Vault 'bk-arm64-kv' has secret 'github-pat' with a PAT (repo scope)
#   - GitHub Actions runner agent pre-installed at C:\actions-runner

$ErrorActionPreference = "Stop"

$KeyVaultName = "bk-arm64-kv"
$SecretName = "github-pat"
$RunnerDir = "C:\actions-runner"

$LogFile = "$RunnerDir\startup.log"
function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $msg" | Tee-Object -FilePath $LogFile -Append
}

Log "=== VMSS Runner Startup ==="
Log "Hostname: $env:COMPUTERNAME"

# Step 1: Verify Key Vault access
Log "Verifying Key Vault access..."
try {
    $tokenResponse = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" `
        -Headers @{Metadata="true"} -Method GET
    $kvUri = "https://$KeyVaultName.vault.azure.net/secrets/$SecretName" + "?api-version=7.4"
    $secretResponse = Invoke-RestMethod -Uri $kvUri `
        -Headers @{Authorization="Bearer $($tokenResponse.access_token)"} -Method GET
    Log "Key Vault access verified."
} catch {
    Log "ERROR: Failed to access Key Vault: $_"
    exit 1
}

# Step 2: Write runner-loop.ps1 to disk (self-contained, no blob download needed)
$loopScript = @'
$ErrorActionPreference = "Stop"

$KeyVaultName = "bk-arm64-kv"
$SecretName = "github-pat"
$RunnerDir = "C:\actions-runner"
$RepoOwner = "rzlink"
$RepoName = "buildkit"
$RunnerLabels = "windows-arm64-selfhosted"

$LogFile = "$RunnerDir\runner-loop.log"
function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $msg" | Tee-Object -FilePath $LogFile -Append
}

Log "=== Runner Loop Started on $env:COMPUTERNAME ==="

while ($true) {
    try {
        # Get managed identity token for Key Vault
        $tokenResponse = Invoke-RestMethod `
            -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" `
            -Headers @{Metadata = "true"} -Method GET

        # Get GitHub PAT from Key Vault
        $kvUri = "https://$KeyVaultName.vault.azure.net/secrets/$SecretName" + "?api-version=7.4"
        $secretResponse = Invoke-RestMethod -Uri $kvUri `
            -Headers @{Authorization = "Bearer $($tokenResponse.access_token)"} -Method GET
        $pat = $secretResponse.value

        # Get runner registration token
        $regResponse = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$RepoOwner/$RepoName/actions/runners/registration-token" `
            -Headers @{Authorization = "token $pat"; Accept = "application/vnd.github+json"} `
            -Method POST
        $regToken = $regResponse.token
        Log "Got registration token."

        # Configure runner (ephemeral, replace existing)
        Set-Location $RunnerDir
        & .\config.cmd --url "https://github.com/$RepoOwner/$RepoName" `
            --token $regToken `
            --name $env:COMPUTERNAME `
            --labels $RunnerLabels `
            --unattended --replace --ephemeral
        Log "Runner configured."

        # Run the runner (blocks until job completes)
        $startTime = Get-Date
        Log "Starting run.cmd..."
        & .\run.cmd
        $elapsed = (Get-Date) - $startTime
        Log "run.cmd exited after $($elapsed.TotalSeconds)s"

        # If runner exited very quickly, wait before retrying
        if ($elapsed.TotalSeconds -lt 30) {
            Log "Runner exited quickly -- no jobs likely. Waiting 60s..."
            Start-Sleep -Seconds 60
        }

    } catch {
        Log "ERROR in runner loop: $_"
        Log "Retrying in 60s..."
        Start-Sleep -Seconds 60
    }
}
'@

$loopScriptPath = "$RunnerDir\runner-loop.ps1"
Set-Content -Path $loopScriptPath -Value $loopScript -Encoding UTF8
Log "runner-loop.ps1 written to $loopScriptPath"

# Step 3: Start the loop script as an independent process so CSE can exit
Log "Starting runner loop (background)..."
Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-ExecutionPolicy", "Bypass", "-File", "$loopScriptPath" `
    -WindowStyle Hidden
Log "Runner loop started. CSE exiting."
