<#
.SYNOPSIS
    Builds the Teams app package from templates, substituting environment values.

.DESCRIPTION
    Reads values from env/.env.<Environment>, replaces ${{...}} placeholders
    in manifest.json, plugin.json, and openapi.yaml, copies icons, and produces
    a ready-to-sideload .zip package in appPackage/build/.

.PARAMETER Environment
    Environment name (dev or prod). Loads settings from env/.env.<Environment>.

.EXAMPLE
    .\build-apppackage.ps1 -Environment dev
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "prod")]
    [string]$Environment
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ProjectRoot "appPackage"))) {
    $ProjectRoot = $PSScriptRoot
}

$appPackageDir = Join-Path $ProjectRoot "appPackage"
$buildDir      = Join-Path $appPackageDir "build"

# ---------- Load environment file ----------
$envFile = Join-Path (Join-Path $ProjectRoot "env") ".env.$Environment"
if (-not (Test-Path $envFile)) {
    Write-Error "Environment file not found: $envFile. Copy env/.env.$Environment.example and fill in your values."
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

# Build the substitution map
$teamsAppId       = $envVars["TEAMS_APP_ID"]
$clientId         = $envVars["AZURE_CLIENT_ID"]
$functionDomain   = $envVars["AZURE_FUNCTION_DOMAIN"]
$functionAppName  = $envVars["AZURE_FUNCTION_APP_NAME"]

if (-not $clientId) {
    Write-Error "AZURE_CLIENT_ID is required in $envFile."
    exit 1
}
if (-not $functionDomain -and $functionAppName) {
    $functionDomain = "$functionAppName.azurewebsites.net"
}
if (-not $functionDomain) {
    Write-Error "AZURE_FUNCTION_DOMAIN (or AZURE_FUNCTION_APP_NAME) is required in $envFile."
    exit 1
}

$functionUrl = "https://$functionDomain"

if (-not $teamsAppId) {
    # Generate a new GUID if not provided
    $teamsAppId = [guid]::NewGuid().ToString()
    Write-Host "Generated new TEAMS_APP_ID: $teamsAppId" -ForegroundColor Yellow
    Write-Host "Add TEAMS_APP_ID=$teamsAppId to $envFile to keep it stable." -ForegroundColor Yellow
}

$substitutions = @{
    '${{TEAMS_APP_ID}}'          = $teamsAppId
    '${{AZURE_CLIENT_ID}}'       = $clientId
    '${{AZURE_FUNCTION_DOMAIN}}' = $functionDomain
    '${{AZURE_FUNCTION_URL}}'    = $functionUrl
}

# ---------- Clean and create build dir ----------
if (Test-Path $buildDir) {
    Remove-Item -Recurse -Force $buildDir
}
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

# ---------- Helper: substitute placeholders ----------
function Replace-Placeholders {
    param([string]$Content)
    foreach ($key in $substitutions.Keys) {
        $Content = $Content.Replace($key, $substitutions[$key])
    }
    return $Content
}

# ---------- Process text files ----------
$textFiles = @(
    @{ Source = "manifest.json";                              Dest = "manifest.json" },
    @{ Source = "plugin.json";                                Dest = "plugin.json" },
    @{ Source = "declarativeAgent.json";                      Dest = "declarativeAgent.json" },
    @{ Source = "apiSpecificationFile\openapi.yaml";          Dest = "apiSpecificationFile\openapi.yaml" }
)

foreach ($file in $textFiles) {
    $srcPath = Join-Path $appPackageDir $file.Source
    $dstPath = Join-Path $buildDir $file.Dest

    if (-not (Test-Path $srcPath)) {
        Write-Warning "Source file not found, skipping: $srcPath"
        continue
    }

    $dstDir = Split-Path -Parent $dstPath
    if (-not (Test-Path $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }

    $content = Get-Content -Path $srcPath -Raw
    $content = Replace-Placeholders -Content $content
    Set-Content -Path $dstPath -Value $content -NoNewline
    Write-Host "  Processed: $($file.Source)" -ForegroundColor Gray
}

# ---------- Copy icon files ----------
foreach ($icon in @("color.png", "outline.png")) {
    $srcIcon = Join-Path $appPackageDir $icon
    if (Test-Path $srcIcon) {
        Copy-Item $srcIcon (Join-Path $buildDir $icon)
        Write-Host "  Copied: $icon" -ForegroundColor Gray
    }
}

# ---------- Create ZIP ----------
# Use .NET ZipFile API instead of Compress-Archive to ensure forward-slash
# path separators in the archive (required by the ZIP spec and Teams Admin Center).
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath = Join-Path $buildDir "AccessPackageAssistant.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
Get-ChildItem -Path $buildDir -Recurse -File | Where-Object { $_.FullName -ne $zipPath } | ForEach-Object {
    $relativePath = $_.FullName.Substring($buildDir.Length + 1).Replace('\', '/')
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $relativePath) | Out-Null
    Write-Host "  Zipped: $relativePath" -ForegroundColor Gray
}
$zip.Dispose()
Write-Host ""
Write-Host "App package built: $zipPath" -ForegroundColor Green
Write-Host ""
Write-Host "Substitutions applied:" -ForegroundColor Cyan
Write-Host "  TEAMS_APP_ID         = $teamsAppId"
Write-Host "  AZURE_CLIENT_ID      = $clientId"
Write-Host "  AZURE_FUNCTION_DOMAIN= $functionDomain"
Write-Host "  AZURE_FUNCTION_URL   = $functionUrl"
Write-Host ""
Write-Host "Next: Sideload $zipPath via M365 Agents Toolkit or Teams Admin Center."
