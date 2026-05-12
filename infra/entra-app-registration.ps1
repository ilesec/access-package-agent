<#
.SYNOPSIS
    Creates and configures the Entra ID app registration for the Access Package Agent.

.DESCRIPTION
    - Registers a new Entra ID application
    - Configures delegated and application API permissions for Microsoft Graph
    - Exposes an API scope (access_as_user)
    - Authorizes the Microsoft 365 Copilot first-party app as a pre-authorized client
    - Creates a client secret

.PARAMETER DisplayName
    Display name for the app registration. Default: "Access Package Agent"

.PARAMETER FunctionAppUrl
    The URL of the Azure Function App for redirect URIs. Defaults to https://localhost:7071 for local development.
    Update the redirect URI after deploying the Function App (see README step 8).

.EXAMPLE
    .\entra-app-registration.ps1
#>

param(
    [string]$DisplayName = "Access Package Agent",
    [string]$FunctionAppUrl = "https://localhost:7071"
)

# Ensure Microsoft Graph PowerShell module is available
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Write-Host "Installing Microsoft.Graph module..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

Import-Module Microsoft.Graph.Applications

# Connect with the required scopes
Connect-MgGraph -Scopes "Application.ReadWrite.All","DelegatedPermissionGrant.ReadWrite.All" -ErrorAction Stop
Write-Host "Connected to Microsoft Graph." -ForegroundColor Green

$tenantId = (Get-MgContext).TenantId

# ---- Microsoft Graph resource app ID (well-known) ----
$graphResourceAppId = "00000003-0000-0000-c000-000000000000"

# ---- Permission IDs (well-known GUIDs) ----
# Delegated: EntitlementManagement.ReadWrite.All
$delegatedEntMgmtRW = "ae7a573d-b112-45c3-8b18-ca5c1a2024b7"
# Delegated: User.Read
$delegatedUserRead = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
# Application: EntitlementManagement.ReadWrite.All
$appEntMgmtRW = "9acd699f-1e81-4958-b717-d9eb0b15be70"

# ---- Create the app registration ----
Write-Host "Creating app registration '$DisplayName'..." -ForegroundColor Cyan

$requiredResourceAccess = @(
    @{
        ResourceAppId = $graphResourceAppId
        ResourceAccess = @(
            @{ Id = $delegatedEntMgmtRW; Type = "Scope" }
            @{ Id = $delegatedUserRead; Type = "Scope" }
            @{ Id = $appEntMgmtRW; Type = "Role" }
        )
    }
)

$app = New-MgApplication -DisplayName $DisplayName `
    -SignInAudience "AzureADMultipleOrgs" `
    -RequiredResourceAccess $requiredResourceAccess `
    -Web @{
        RedirectUris = @(
            "$FunctionAppUrl/.auth/login/aad/callback"
            "https://teams.microsoft.com/api/platform/v1.0/oAuthConsentRedirect"
            "https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect"
        )
        ImplicitGrantSettings = @{
            EnableAccessTokenIssuance = $false
            EnableIdTokenIssuance = $true
        }
    }

$appId = $app.AppId
$objectId = $app.Id
Write-Host "App registered: AppId=$appId, ObjectId=$objectId" -ForegroundColor Green

# ---- Expose an API scope ----
Write-Host "Configuring API scope..." -ForegroundColor Cyan

$scopeId = [guid]::NewGuid().ToString()

Update-MgApplication -ApplicationId $objectId `
    -IdentifierUris @("api://$appId") `
    -Api @{
        RequestedAccessTokenVersion = 2
        Oauth2PermissionScopes = @(
            @{
                Id = $scopeId
                AdminConsentDescription = "Allow the Copilot agent to access the Access Package API on behalf of the signed-in user"
                AdminConsentDisplayName = "Access as user"
                UserConsentDescription = "Allow this app to access the Access Package API on your behalf"
                UserConsentDisplayName = "Access as user"
                IsEnabled = $true
                Type = "User"
                Value = "access_as_user"
            }
        )
    }

# ---- Pre-authorize Microsoft 365 Copilot first-party apps ----
Write-Host "Pre-authorizing Microsoft 365 Copilot client apps..." -ForegroundColor Cyan

# Known M365 Copilot / Teams first-party app IDs
$preAuthorizedClients = @(
    "ab3be6b7-f5df-413d-ac2d-abf1e3fd9c0b"  # Microsoft Teams
    "27922004-5251-4030-b22d-91ecd9a37ea4"  # Microsoft 365 Copilot
    "4765445b-32c6-49b0-83e6-1d93765276ca"  # Microsoft 365 web
    "d3590ed6-52b3-4102-aeff-aad2292ab01c"  # Microsoft Office
)

$preAuthApps = $preAuthorizedClients | ForEach-Object {
    @{
        AppId = $_
        DelegatedPermissionIds = @($scopeId)
    }
}

Update-MgApplication -ApplicationId $objectId -Api @{
    PreAuthorizedApplications = $preAuthApps
    Oauth2PermissionScopes = @(
        @{
            Id = $scopeId
            AdminConsentDescription = "Allow the Copilot agent to access the Access Package API on behalf of the signed-in user"
            AdminConsentDisplayName = "Access as user"
            UserConsentDescription = "Allow this app to access the Access Package API on your behalf"
            UserConsentDisplayName = "Access as user"
            IsEnabled = $true
            Type = "User"
            Value = "access_as_user"
        }
    )
}

# ---- Create a client secret ----
Write-Host "Creating client secret..." -ForegroundColor Cyan

$secret = Add-MgApplicationPassword -ApplicationId $objectId -PasswordCredential @{
    DisplayName = "Access Package Agent Secret"
    EndDateTime = (Get-Date).AddYears(1)
}

# ---- Create a service principal ----
Write-Host "Creating service principal..." -ForegroundColor Cyan
$sp = New-MgServicePrincipal -AppId $appId

# ---- Output ----
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " App Registration Complete" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Tenant ID:       $tenantId"
Write-Host "Application ID:  $appId"
Write-Host "Object ID:       $objectId"
Write-Host "Client Secret:   $($secret.SecretText)"
Write-Host "API Scope:       api://$appId/access_as_user"
Write-Host ""
Write-Host "IMPORTANT: Save the client secret now -- it will not be shown again." -ForegroundColor Yellow
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Grant admin consent: Go to Azure Portal -> App Registrations -> $DisplayName -> API Permissions -> Grant admin consent"
Write-Host "  2. Update env/.env.dev with the values above"
Write-Host "  3. Update appPackage templates with AZURE_CLIENT_ID=$appId"
Write-Host ""

# Disconnect
Disconnect-MgGraph | Out-Null
