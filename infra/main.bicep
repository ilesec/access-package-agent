// --------------------------------------------------------------------------
// Bicep template: Deploys all Azure resources for the Access Package Agent
//
//   - Azure AI Search (Basic tier, vector-capable)
//   - Azure OpenAI with text-embedding-3-small deployment
//   - Azure Function App (Python 3.11, Flex Consumption plan)
//   - Storage account (identity-based auth, no shared keys)
//   - Application Insights
//   - Key Vault (for secrets)
//
// Usage:
//   az deployment group create \
//     --resource-group <rg-name> \
//     --template-file infra/main.bicep \
//     --parameters entraClientId=<app-id> entraClientSecret=<secret> entraTenantId=<tenant-id>
// --------------------------------------------------------------------------

targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Base name used for generating resource names')
param baseName string = 'accpkgagent'

@description('Azure region for OpenAI (must support text-embedding-3-small). Use swedencentral if your primary region does not.')
param openAiLocation string = 'swedencentral'

@description('Entra ID app registration client ID')
@secure()
param entraClientId string

@description('Entra ID app registration client secret')
@secure()
param entraClientSecret string

@description('Entra ID tenant ID')
param entraTenantId string

// ---------- Unique suffix (13 chars) ----------
var suffix = uniqueString(resourceGroup().id)
var shortSuffix = substring(suffix, 0, 8)
var searchName = '${baseName}srch${shortSuffix}'
var openAiName = '${baseName}oai${shortSuffix}'
var funcAppName = '${baseName}fn${shortSuffix}'
var storageName = toLower('${baseName}st${shortSuffix}')
var appInsightsName = '${baseName}ai${shortSuffix}'
var kvName = '${baseName}kv${shortSuffix}'
var hostingPlanName = '${baseName}plan${shortSuffix}'
var deployContainerName = 'app-package-${funcAppName}'

// ---------- Storage Account (identity-based, no shared keys) ----------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: false
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource deployContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: deployContainerName
}

// ---------- Application Insights ----------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Request_Source: 'rest'
  }
}

// ---------- Azure AI Search (Basic — supports vector) ----------
resource searchService 'Microsoft.Search/searchServices@2024-03-01-preview' = {
  name: searchName
  location: location
  sku: { name: 'basic' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    authOptions: {
      aadOrApiKey: {}
    }
  }
}

// ---------- Azure OpenAI (deployed to openAiLocation for model availability) ----------
resource openAi 'Microsoft.CognitiveServices/accounts@2024-04-01-preview' = {
  name: openAiName
  location: openAiLocation
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: openAiName
    publicNetworkAccess: 'Enabled'
  }
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-04-01-preview' = {
  parent: openAi
  name: 'text-embedding-3-small'
  sku: {
    name: 'GlobalStandard'
    capacity: 120
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-3-small'
      version: '1'
    }
  }
}

// ---------- Key Vault ----------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
  }
}

resource secretClientId 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'EntraClientId'
  properties: { value: entraClientId }
}

resource secretClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'EntraClientSecret'
  properties: { value: entraClientSecret }
}

// ---------- Flex Consumption Hosting Plan ----------
resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true // Linux
  }
}

// ---------- Azure Function App (Flex Consumption) ----------
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: funcAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}${deployContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: 'https://${storageName}.blob.${environment().suffixes.storage}' }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: 'https://${storageName}.queue.${environment().suffixes.storage}' }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: 'https://${storageName}.table.${environment().suffixes.storage}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'APP_TENANT_ID', value: entraTenantId }
        { name: 'APP_CLIENT_ID', value: entraClientId }
        { name: 'APP_CLIENT_SECRET', value: '@Microsoft.KeyVault(SecretUri=${secretClientSecret.properties.secretUri})' }
        { name: 'AZURE_OPENAI_ENDPOINT', value: 'https://${openAiName}.openai.azure.com/' }
        { name: 'AZURE_OPENAI_EMBEDDING_DEPLOYMENT', value: 'text-embedding-3-small' }
        { name: 'AZURE_SEARCH_ENDPOINT', value: 'https://${searchName}.search.windows.net' }
        { name: 'AZURE_SEARCH_INDEX_NAME', value: 'access-packages-index' }
      ]
    }
  }
}

// ---------- Role Assignments (Function App managed identity) ----------

// Storage Blob Data Owner (for deployment container + blob triggers)
resource storageBlobOwnerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Queue Data Contributor (for AzureWebJobsStorage queues)
resource storageQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor (for AzureWebJobsStorage tables)
resource storageTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// AI Search — Search Index Data Contributor
resource searchRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, functionApp.id, '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// AI Search — Search Service Contributor (required to create/update indexes)
resource searchServiceContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, functionApp.id, '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Azure OpenAI — Cognitive Services OpenAI User
resource openAiRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(openAi.id, functionApp.id, '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
  scope: openAi
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault — Key Vault Secrets User
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Outputs ----------
output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output searchServiceName string = searchService.name
output openAiEndpoint string = 'https://${openAiName}.openai.azure.com/'
output keyVaultName string = keyVault.name
