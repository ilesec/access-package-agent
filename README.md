# Access Package Assistant — Microsoft 365 Copilot Declarative Agent

An AI assistant that helps users discover and request Entra ID access packages using natural language, powered by Azure AI Search (vector + full-text hybrid search) and Microsoft Graph Entitlement Management API.

## Architecture

```
Microsoft 365 Copilot (Declarative Agent)
  └─ plugin.json → openapi.yaml
       └─ Azure Function (Python 3.11, Flex Consumption)
            ├─ POST /api/searchPackages  → Azure OpenAI (embed) → Azure AI Search
            ├─ GET  /api/packageDetails/{id} → Microsoft Graph API (OBO)
            └─ POST /api/requestPackage  → Microsoft Graph API (OBO)

Timer trigger (every 6 hours)
  └─ Graph API → Azure OpenAI (embed) → Azure AI Search (upsert)
```

## Prerequisites

- Azure subscription
- Microsoft 365 Copilot license
- Azure CLI (`az`)
- Python 3.11+ with `pip`
- Node.js / npm (for the ATK CLI)
- Microsoft 365 Agents Toolkit CLI (`npm i -g @microsoft/m365agentstoolkit-cli@latest`)

## Deployment

### 1. Create the Entra ID app registration

```powershell
cd infra
.\entra-app-registration.ps1
```

Save the output values (Tenant ID, Application ID, Client Secret).

### 2. Configure your environment

```powershell
Copy-Item env\.env.dev.example env\.env.dev
```

Edit `env/.env.dev` with the values from step 1 and your Azure settings (subscription ID, resource group, etc.).

### 3. Deploy infrastructure and code

```powershell
.\deploy.ps1 -Environment dev
```

This command:
- Creates the resource group
- Deploys all Azure resources via Bicep (AI Search, OpenAI, Function App on Flex Consumption, Key Vault)
- Installs Python packages locally for Linux and creates a deployment zip
- Publishes the Function App code (zip deploy to Flex Consumption blob storage)
- Updates the Entra app redirect URIs
- Triggers the initial access package sync (populates the search index with embeddings)

> **Note:** The Function App uses Flex Consumption plan with identity-based storage (no shared keys). The managed identity is granted Storage Blob Data Owner, Queue Data Contributor, and Table Data Contributor roles automatically by Bicep.

### 4. Grant admin consent

Go to **Azure Portal → Entra ID → App Registrations → Access Package Agent → API Permissions → Grant admin consent**.

This grants the `EntitlementManagement.ReadWrite.All` application permission needed by the sync pipeline to read access packages from Graph API.

### 5. Register Entra SSO in Teams Developer Portal

This step enables single sign-on so users don't need to separately sign in when using the Copilot agent.

1. Open [Teams Developer Portal → Tools → Microsoft Entra SSO client ID registration](https://dev.teams.microsoft.com/tools)
2. Click **Register client ID** (or **New client registration** if you have existing registrations)
3. Fill in:
   - **Registration name**: `access-package-agent-sso`
   - **Base URL**: Your Azure Function App URL (e.g., `https://<func-app>.azurewebsites.net`)
   - **Client ID**: The `AZURE_CLIENT_ID` from `env/.env.dev`
4. Click **Save** — this generates an **SSO registration ID** and an **Application ID URI**
5. Add the SSO registration ID to `env/.env.dev`:
   ```
   SSO_CONFIGURATION_ID=<sso-registration-id>
   ```

6. Add the generated **Application ID URI** to the Entra app registration:
   - Go to **Azure Portal → Entra ID → App Registrations → Access Package Agent → Manifest**
   - Add the new URI to the `identifierUris` array (keep the existing `api://<client-id>` URI):
     ```json
     "identifierUris": [
       "api://<client-id>",
       "<new-uri-from-sso-registration>"
     ]
     ```

### 6. Provision the Copilot agent

Authenticate ATK to both M365 and Azure:

```bash
atk auth login m365
atk auth login azure
```

Then provision:

```bash
atk provision --env dev -i false
```

This registers the app in the Teams Developer Portal and extends it to M365 Copilot. The `TEAMS_APP_ID` and `M365_APP_ID` are written to `env/.env.dev`.

> **Note:** The ATK provision step registers both OAuth (for API plugin authentication via `OAuthPluginVault` in `plugin.json`) and SSO (configured in step 5 for seamless single sign-on). OAuth handles how M365 Copilot authenticates to the Azure Function API, while SSO ensures users aren't prompted to sign in separately. The first time a user calls `packageDetails` or `requestPackage`, they may be prompted to consent to Graph permissions (one-time only).

### 7. Open in M365 Copilot

```
https://m365.cloud.microsoft/chat/entity1-d870f6cd-4aa5-4d42-9626-ab690c041429/<M365_APP_ID>?auth=2&developerMode=Basic
```

Replace `<M365_APP_ID>` with the value from `env/.env.dev`.

### Redeployment (code changes only)

```powershell
.\deploy.ps1 -Environment dev -SkipInfra
```

To update the Copilot agent registration after manifest changes:

```bash
atk provision --env dev -i false
```

## How Embeddings and Search Work

The `syncAccessPackages` timer function runs every 6 hours and populates the Azure AI Search vector index:

1. **Fetch** — Calls Microsoft Graph API to retrieve all access packages (with resources and assignment policies)
2. **Embed** — For each package, composes a text string: `"{displayName}. {description}. Resources: {resources}"` and sends it to Azure OpenAI `text-embedding-3-small` to produce a 1536-dimension vector
3. **Upsert** — Uploads documents (with the `contentVector` field) into the `access-packages-index` in Azure AI Search, which uses an HNSW cosine similarity profile
4. **Auto-creates index** — If the index doesn't exist yet, `ensure_index_exists()` creates it with the correct schema and vector search configuration

When a user asks a question, `/api/searchPackages` runs a **hybrid search** — combining full-text search on the query string with vector similarity on the embedding — and returns the top matching packages.

### Manually triggering a sync

The initial sync is triggered automatically by `deploy.ps1`. To trigger it manually:

```powershell
$funcKey = az functionapp keys list --name <FUNCTION_APP_NAME> --resource-group <RESOURCE_GROUP> --query "masterKey" --output tsv

Invoke-RestMethod -Uri "https://<FUNCTION_APP_DOMAIN>/admin/functions/syncAccessPackages" `
    -Method Post `
    -Headers @{ "x-functions-key" = $funcKey; "Content-Type" = "application/json" } `
    -Body '{"input":""}'
```

## CI/CD (GitHub Actions)

Two workflows are provided in `.github/workflows/`:

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `deploy-infra.yml` | Manual (workflow_dispatch) | Deploys Azure resources via Bicep |
| `deploy-func.yml` | Push to `main` or manual | Publishes Function App code + triggers sync |

**Required GitHub secrets:** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `ENTRA_CLIENT_ID`, `ENTRA_CLIENT_SECRET`
**Required GitHub variables:** `RESOURCE_GROUP`, `LOCATION`, `FUNCTION_APP_NAME`

> **Note:** `AZURE_CLIENT_ID` is the service principal used for GitHub OIDC login (`az login`). `ENTRA_CLIENT_ID` / `ENTRA_CLIENT_SECRET` are the access-package-agent app registration credentials passed to Bicep.

## API Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/api/searchPackages` | POST | OAuth | Hybrid vector+text search for access packages |
| `/api/packageDetails/{id}` | GET | OAuth (OBO) | Get package details, resources, policies |
| `/api/requestPackage` | POST | OAuth (OBO) | Submit access package assignment request |

> **Note:** All endpoints use anonymous function-level auth (`AuthLevel.ANONYMOUS`). Authentication is handled by M365 Copilot via Entra ID SSO (single sign-on). The `packageDetails` and `requestPackage` endpoints additionally use the bearer token for On-Behalf-Of (OBO) flow to call Microsoft Graph.

## Configuration

Function App settings are deployed via Bicep. All Azure service connections use managed identity (no API keys needed):

| Setting | Description |
|---------|-------------|
| `APP_TENANT_ID` | Entra ID tenant ID |
| `APP_CLIENT_ID` | App registration client ID |
| `APP_CLIENT_SECRET` | App registration client secret (stored in Key Vault) |
| `AZURE_OPENAI_ENDPOINT` | Azure OpenAI endpoint URL |
| `AZURE_OPENAI_EMBEDDING_DEPLOYMENT` | Embedding model deployment name (`text-embedding-3-small`) |
| `AZURE_SEARCH_ENDPOINT` | Azure AI Search endpoint URL |
| `AZURE_SEARCH_INDEX_NAME` | Search index name (`access-packages-index`) |
| `AzureWebJobsStorage__credential` | Set to `managedidentity` (no storage keys) |
| `AzureWebJobsStorage__blobServiceUri` | Storage blob endpoint |
| `AzureWebJobsStorage__queueServiceUri` | Storage queue endpoint |
| `AzureWebJobsStorage__tableServiceUri` | Storage table endpoint |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Application Insights connection string |

## Project Structure

```
access-package-agent/
├── appPackage/
│   ├── manifest.json                    # M365 app manifest (template with ${{}} vars)
│   ├── declarativeAgent.json            # Agent instructions & conversation starters
│   ├── plugin.json                      # API plugin (auth, functions, adaptive cards)
│   ├── color.png                        # App icon (color)
│   ├── outline.png                      # App icon (outline)
│   └── apiSpecificationFile/
│       └── openapi.yaml                 # OpenAPI 3.0 spec for the Azure Function endpoints
├── src/
│   ├── __init__.py                      # Package init
│   ├── embedding_client.py              # Azure OpenAI embedding helper
│   ├── search_client.py                 # Azure AI Search index & query helper
│   ├── graph_client.py                  # Microsoft Graph API helper (OBO, app tokens)
│   ├── sync_access_packages.py          # Timer-triggered sync pipeline
│   ├── search_packages.py               # /api/searchPackages handler
│   ├── package_details.py               # /api/packageDetails handler
│   └── request_package.py               # /api/requestPackage handler
├── infra/
│   ├── main.bicep                       # Bicep template (Flex Consumption, identity-based storage)
│   └── entra-app-registration.ps1       # PowerShell script for Entra app setup
├── env/
│   └── .env.dev.example                 # Environment config template
├── .github/workflows/
│   ├── deploy-infra.yml                 # CI/CD: infrastructure deployment
│   └── deploy-func.yml                  # CI/CD: Function App deployment
├── function_app.py                      # Azure Functions entry point
├── requirements.txt                     # Python dependencies
├── host.json                            # Functions host configuration
├── m365agents.yml                       # ATK lifecycle config (provision + deploy)
├── deploy.ps1                           # Unified deployment script (infra + code)
├── build-apppackage.ps1                 # Teams app package builder
└── .gitignore
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| **403 on Graph API calls** | Admin consent not granted. Go to Azure Portal → App Registrations → API Permissions → Grant admin consent. |
| **Key Vault access denied** | Function App managed identity needs "Key Vault Secrets User" role. Re-run the Bicep deployment. |
| **Redirect URI mismatch** | Run `deploy.ps1` again — it auto-updates redirect URIs. Or check the Entra app registration manually. |
| **Empty search results** | Sync hasn't run yet or admin consent is missing. Check: 1) Admin consent granted for `EntitlementManagement.ReadWrite.All` application permission (Step 4). 2) Access packages exist in Entra ID → Identity Governance → Entitlement Management. 3) Application Insights logs for sync errors. 4) AI Search index document count > 0. Trigger sync manually (see below) or redeploy with `deploy.ps1`. |
| **App package variables not replaced** | Run `.\build-apppackage.ps1 -Environment dev` or `atk provision --env dev -i false` — don't manually edit files in `appPackage/build/`. |
| **ATK provision fails with schema error** | Check `m365agents.yml` against the schema. Run `atk provision --env dev -i false` and read the error details. |
| **401 on sync trigger** | Ensure you're using the master key from `az functionapp keys list`. The sync is a timer trigger, not HTTP — use the `/admin/functions/` endpoint with `{"input":""}` body. |
| **Storage shared key errors** | The deployment uses identity-based storage (`allowSharedKeyAccess: false`). Ensure managed identity RBAC roles are assigned (Bicep handles this automatically). |
| **Sync fails with Forbidden on AI Search** | The Search service must have RBAC auth enabled (`aadOrApiKey`). Bicep handles this, but if the service was created with `apiKeyOnly`, fix it: `az rest --method patch --url "https://management.azure.com<SEARCH_RESOURCE_ID>?api-version=2024-03-01-preview" --headers "Content-Type=application/json" --body '{\"properties\":{\"authOptions\":{\"aadOrApiKey\":{}}}}'` |
| **Soft-deleted OpenAI resource blocks deploy** | Purge it first: `az cognitiveservices account purge --name <NAME> --resource-group <RG> --location <LOCATION>` |
| **AADSTS50194: not configured as multi-tenant** | The app registration must use `signInAudience: AzureADMultipleOrgs` because M365 Copilot uses the `/common` OAuth endpoint. Run: `az ad app update --id <CLIENT_ID> --sign-in-audience AzureADMultipleOrgs` |
| **AADSTS50011: redirect URI mismatch** | Ensure both `https://teams.microsoft.com/api/platform/v1.0/oAuthConsentRedirect` and `https://teams.microsoft.com/api/platform/v1.0/oAuthRedirect` are registered as redirect URIs. Run `deploy.ps1` to auto-update them. |
| **User prompted to sign in separately** | Switch to Entra SSO auth (see Step 5). Ensure the SSO registration in Teams Developer Portal is configured and `SSO_CONFIGURATION_ID` is set in `env/.env.dev`. Re-provision with `atk provision --env dev -i false`. |
| **No access packages in Entra audit logs** | Admin consent for the `EntitlementManagement.ReadWrite.All` *application* permission is likely missing. Grant it in Azure Portal → App Registrations → API Permissions. Then trigger a sync manually. |
