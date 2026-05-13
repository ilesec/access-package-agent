<#
.SYNOPSIS
    Unified deployment script for the Access Package Agent.

.DESCRIPTION
    Orchestrates the full deployment:
      1. Creates the resource group (if needed)
      2. Deploys Azure infrastructure via Bicep
      3. Publishes the Function App code
      4. Updates Entra ID app registration redirect URIs
      5. Triggers the initial access package sync

.PARAMETER Environment
    Environment name (dev or prod). Loads settings from env/.env.<Environment>.

.PARAMETER SkipInfra
    Skip Bicep infrastructure deployment (only publish code).

.PARAMETER SkipSync
    Skip triggering the initial sync after deployment.

.EXAMPLE
    .\deploy.ps1 -Environment dev
    .\deploy.ps1 -Environment prod -SkipSync
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    [switch]$SkipInfra,
    [switch]$SkipSync
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectRoot "function_app.py"))) {
    $ProjectRoot = $PSScriptRoot
}

# ---------- Load environment file ----------
$envFile = Join-Path (Join-Path $ProjectRoot "env") ".env.$Environment"
if (-not (Test-Path $envFile)) {
    Write-Error "Environment file not found: $envFile. Copy env/.env.$Environment.example to env/.env.$Environment and fill in your values."
    exit 1
}

Write-Host "Loading environment from $envFile" -ForegroundColor Cyan
$envVars = @{}
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $parts = $line -split "=", 2
        if ($parts.Length -eq 2 -and $parts[1].Trim()) {
            $envVars[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
}

$resourceGroup   = $envVars["RESOURCE_GROUP"]
$location         = $envVars["LOCATION"]
$tenantId         = $envVars["AZURE_TENANT_ID"]
$clientId         = $envVars["AZURE_CLIENT_ID"]
$clientSecret     = $envVars["AZURE_CLIENT_SECRET"]
$baseName         = $envVars["BASE_NAME"]

if (-not $resourceGroup -or -not $tenantId -or -not $clientId -or -not $clientSecret) {
    Write-Error "Missing required values in $envFile. Ensure RESOURCE_GROUP, AZURE_TENANT_ID, AZURE_CLIENT_ID, and AZURE_CLIENT_SECRET are set."
    exit 1
}

# ---------- Check prerequisites ----------
if (-not (Get-Command "az" -ErrorAction SilentlyContinue)) {
    Write-Error "'az' (Azure CLI) is not installed or not in PATH. See https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

# ---------- 1. Create resource group ----------
Write-Host ""
Write-Host "=== Step 1: Ensure resource group '$resourceGroup' exists ===" -ForegroundColor Green
$loc = if ($location) { $location } else { "swedencentral" }
az group create --name $resourceGroup --location $loc --output none
Write-Host "Resource group ready."

# ---------- 2. Deploy infrastructure ----------
if (-not $SkipInfra) {
    Write-Host ""
    Write-Host "=== Step 2: Deploy Azure infrastructure (Bicep) ===" -ForegroundColor Green
    $bicepFile = Join-Path (Join-Path $ProjectRoot "infra") "main.bicep"

    $deployOutput = az deployment group create `
        --resource-group $resourceGroup `
        --template-file $bicepFile `
        --parameters `
            entraClientId=$clientId `
            entraClientSecret=$clientSecret `
            entraTenantId=$tenantId `
            baseName=$(if ($baseName) { $baseName } else { "accpkgagent" }) `
        --query "properties.outputs" `
        --output json | ConvertFrom-Json

    $functionAppName = $deployOutput.functionAppName.value
    $functionAppUrl  = $deployOutput.functionAppUrl.value
    $searchName      = $deployOutput.searchServiceName.value
    $openAiEndpoint  = $deployOutput.openAiEndpoint.value
    $keyVaultName    = $deployOutput.keyVaultName.value

    if (-not $functionAppName) {
        Write-Error "Bicep deployment failed or returned no outputs. Fix the errors above and retry."
        exit 1
    }

    Write-Host ""
    Write-Host "Deployment outputs:" -ForegroundColor Cyan
    Write-Host "  Function App:   $functionAppName ($functionAppUrl)"
    Write-Host "  Search Service: $searchName"
    Write-Host "  OpenAI:         $openAiEndpoint"
    Write-Host "  Key Vault:      $keyVaultName"
} else {
    Write-Host ""
    Write-Host "=== Step 2: Skipping infrastructure deployment ===" -ForegroundColor Yellow
    $functionAppName = $envVars["AZURE_FUNCTION_APP_NAME"]
    if (-not $functionAppName) {
        Write-Error "AZURE_FUNCTION_APP_NAME must be set in $envFile when using -SkipInfra."
        exit 1
    }
    $functionAppUrl = "https://$functionAppName.azurewebsites.net"
}

# ---------- 3. Publish Function App code ----------
Write-Host ""
Write-Host "=== Step 3: Publish Function App code ===" -ForegroundColor Green

$zipPath = Join-Path $ProjectRoot "funcapp.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# Install pip packages locally for Linux x86_64
Write-Host "Installing Python packages for Linux target..."
$pkgDir = Join-Path $ProjectRoot ".python_packages\lib\site-packages"
if (Test-Path (Join-Path $ProjectRoot ".python_packages")) {
    Remove-Item (Join-Path $ProjectRoot ".python_packages") -Recurse -Force
}
pip install -r (Join-Path $ProjectRoot "requirements.txt") `
    --target $pkgDir `
    --platform manylinux2014_x86_64 `
    --python-version 3.11 `
    --only-binary=:all: `
    --quiet

if ($LASTEXITCODE -ne 0) {
    Write-Error "pip install failed."
    exit 1
}

# Create zip with source code + pre-installed packages
Write-Host "Creating deployment package..."
Push-Location $ProjectRoot
try {
    Compress-Archive -Path "function_app.py", "host.json", "requirements.txt", "src", ".python_packages" `
        -DestinationPath $zipPath -Force
} finally {
    Pop-Location
}

Write-Host "Deploying to $functionAppName (Flex Consumption)..."
# Use az functionapp deploy which uploads via the management plane (ARM)
# and does not require shared key access on the storage account.
az functionapp deploy `
    --resource-group $resourceGroup `
    --name $functionAppName `
    --src-path $zipPath `
    --type zip `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed."
    exit 1
}

# Clean up
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $ProjectRoot ".python_packages") -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Function App code published."

# ---------- 4. Update Entra app redirect URIs ----------
Write-Host ""
Write-Host "=== Step 4: Update Entra app registration redirect URIs ===" -ForegroundColor Green

$redirectUris = @(
    "$functionAppUrl/.auth/login/aad/callback",
    "https://teams.microsoft.com/api/platform/v1.0/oAuthConsentRedirect",
    "https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect"
)

az ad app update `
    --id $clientId `
    --web-redirect-uris @($redirectUris)

Write-Host "Redirect URIs updated for app $clientId"

# ---------- 5. Trigger initial sync ----------
if (-not $SkipSync) {
    Write-Host ""
    Write-Host "=== Step 5: Trigger initial access package sync ===" -ForegroundColor Green

    $funcKey = az functionapp keys list `
        --name $functionAppName `
        --resource-group $resourceGroup `
        --query "masterKey" `
        --output tsv

    # Timer-triggered functions are invoked via /admin/functions/{name} with {"input":""}
    # After remote build deployment, the app may take a minute to become ready
    $syncUrl = "$functionAppUrl/admin/functions/syncAccessPackages"
    $maxAttempts = 6
    $delaySeconds = 30
    $syncSuccess = $false

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $syncUrl -Method Post `
                -Headers @{ "x-functions-key" = $funcKey; "Content-Type" = "application/json" } `
                -Body '{"input":""}' 
            Write-Host "Sync triggered successfully."
            $syncSuccess = $true
            break
        } catch {
            if ($attempt -lt $maxAttempts) {
                Write-Host "  Attempt $attempt/$maxAttempts failed (app may still be building). Retrying in ${delaySeconds}s..."
                Start-Sleep -Seconds $delaySeconds
            } else {
                Write-Warning "Sync trigger failed after $maxAttempts attempts: $($_.Exception.Message). You can trigger it manually later."
            }
        }
    }
} else {
    Write-Host ""
    Write-Host "=== Step 5: Skipping sync ===" -ForegroundColor Yellow
}

# ---------- Summary ----------
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " Deployment Complete ($Environment)" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Function App URL: $functionAppUrl"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Grant admin consent: Azure Portal -> App Registrations -> Access Package Agent -> API Permissions -> Grant admin consent"
Write-Host "  2. Provision the Copilot agent: atk provision --env dev -i false"
Write-Host "  3. Open in M365 Copilot using the M365_APP_ID from env/.env.dev"
Write-Host ""

# Update env file with discovered values
if ($functionAppName -and -not $envVars["AZURE_FUNCTION_APP_NAME"]) {
    Write-Host "TIP: Add this to your ${envFile}:" -ForegroundColor Yellow
    Write-Host "  AZURE_FUNCTION_APP_NAME=$functionAppName"
}
