# runner-loop.ps1 -- Ephemeral runner re-registration loop
# Downloaded by startup.ps1 on VMSS instance boot.
#
# Workflow per iteration:
#   1. Get access token from managed identity (IMDS)
#   2. Fetch GitHub PAT from Key Vault
#   3. Request a runner registration token from GitHub API
#   4. Configure the runner (--ephemeral --replace)
#   5. Run the runner (run.cmd) -- exits after one job
#   6. If runner ran for <30s, wait 60s (likely no jobs available)
#   7. Repeat from step 1

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
        # Step 1: Get managed identity token for Key Vault
        $tokenResponse = Invoke-RestMethod `
            -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" `
            -Headers @{Metadata = "true"} -Method GET

        # Step 2: Get GitHub PAT from Key Vault
        $kvUri = "https://$KeyVaultName.vault.azure.net/secrets/$SecretName" + "?api-version=7.4"
        $secretResponse = Invoke-RestMethod -Uri $kvUri `
            -Headers @{Authorization = "Bearer $($tokenResponse.access_token)"} -Method GET
        $pat = $secretResponse.value

        # Step 3: Get runner registration token
        $regResponse = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$RepoOwner/$RepoName/actions/runners/registration-token" `
            -Headers @{Authorization = "token $pat"; Accept = "application/vnd.github+json"} `
            -Method POST
        $regToken = $regResponse.token
        Log "Got registration token."

        # Step 4: Configure runner (ephemeral, replace existing)
        Set-Location $RunnerDir
        & .\config.cmd --url "https://github.com/$RepoOwner/$RepoName" `
            --token $regToken `
            --name $env:COMPUTERNAME `
            --labels $RunnerLabels `
            --unattended --replace --ephemeral
        Log "Runner configured."

        # Step 5: Run the runner (blocks until job completes or no job available)
        $startTime = Get-Date
        Log "Starting run.cmd..."
        & .\run.cmd
        $elapsed = (Get-Date) - $startTime
        Log "run.cmd exited after $($elapsed.TotalSeconds)s"

        # Step 6: If runner exited very quickly, wait before retrying
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
