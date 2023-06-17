#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Create a Service Connection in Azure DevOps that uses a Managed Identity and Workload Identity fderation to authenticate to Azure.

.DESCRIPTION 
    Creates a Managed Identiy, sets up a federation subject on the Managed Identity for a Service Connection, creates the Service Connection, and grants the Managed Identity the Contributor role on the subscription.

.EXAMPLE
    ./create_msi_oidc_service_connection.ps1 -Project MyProject -OrganizationUrl https://dev.azure.com/MyOrg
#> 
#Requires -Version 7

param ( 
    [parameter(Mandatory=$false,HelpMessage="Name of the Managed Identity")]
    [string]
    $IdentityName,

    [parameter(Mandatory=$false,HelpMessage="Name of the Azure Resource Group")]
    [string]
    $ResourceGroupName,
    
    [parameter(Mandatory=$false,HelpMessage="Id of the Azure Subscription")]
    [guid]
    $SubscriptionId,

    [parameter(Mandatory=$false,HelpMessage="Location of the Managed Identity")]
    [string]
    $Location,

    [parameter(Mandatory=$false,HelpMessage="Name of the Service Connection")]
    [string]
    $ServiceConnectionName,

    [parameter(Mandatory=$true,HelpMessage="Name of the Azure DevOps Project")]
    [string]
    [ValidateNotNullOrEmpty()]
    $Project,

    [parameter(Mandatory=$false,HelpMessage="Url of the Azure DevOps Organization")]
    [uri]
    [ValidateNotNullOrEmpty()]
    $OrganizationUrl=$env:AZDO_ORG_SERVICE_URL
) 
Write-Verbose $MyInvocation.line 
. (Join-Path $PSScriptRoot functions.ps1)
$apiVersion = "7.1-preview.4"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI is not installed. Please install it from https://docs.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

# Log in to Azure
az account show -o json 2>$null | ConvertFrom-Json | Set-Variable subscription
if (!$subscription) {
    az login -o json | ConvertFrom-Json | Set-Variable subscription
}
$subscription | Format-List | Out-String | Write-Debug
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId -o none
    az account show -o json 2>$null | ConvertFrom-Json | Set-Variable subscription
} else {
    $SubscriptionId = $subscription.id
}

# Process parameters, making sure they're not empty
$OrganizationUrl = $OrganizationUrl.ToString().Trim('/')
$organizationName = $OrganizationUrl.ToString().Split('/')[3]
if (!$ResourceGroupName) {
    az config get defaults.group --query value -o tsv | Set-Variable ResourceGroupName
    $ResourceGroupName ??= "VS-${organizationName}-Group" # Billing group convention
}
az group show -g $ResourceGroupName -o json 2>$null | ConvertFrom-Json | Set-Variable resourceGroup
if ($resourceGroup) {
    if (!$Location) {
        $Location = $resourceGroup.location
    }
} else {
    if (!$Location) {
        az config get defaults.location --query value -o tsv | Set-Variable Location
        $Location ??= "southcentralus" # Azure location doesn't really matter for MI; the object is in AAD 
    }
    az group create -g $ResourceGroupName -l $Location -o json | ConvertFrom-Json | Set-Variable resourceGroup
}
if (!$ServiceConnectionName) {
    $ServiceConnectionName = $subscription.name
}
if (!$IdentityName) {
    $IdentityName = "${organizationName}-${Project}-${ServiceConnectionName}"
}

az identity create -n $IdentityName `
                   -g $ResourceGroupName `
                   -l $Location `
                   --subscription $SubscriptionId `
                   -o json `
                   | ConvertFrom-Json `
                   | Set-Variable identity

$federatedSubject = "sc://${organizationName}/${Project}/${ServiceConnectionName}"
az identity federated-credential create --name $IdentityName `
                                        --identity-name $IdentityName  `
                                        --resource-group $ResourceGroupName `
                                        --issuer https://app.vstoken.visualstudio.com `
                                        --subject $federatedSubject `
                                        --subscription $SubscriptionId `
                                        -o none
$identity | Add-Member -NotePropertyName federatedSubject -NotePropertyValue $federatedSubject
$identity | Add-Member -NotePropertyName subscriptionId   -NotePropertyValue $SubscriptionId
$identity | Format-List -Property id, subscriptionId, clientId, federatedSubject, tenantId
$identity | Format-List | Out-String | Write-Debug

az role assignment create --assignee-object-id $identity.principalId `
                          --assignee-principal-type ServicePrincipal `
                          --role Contributor `
                          --scope "/subscriptions/${SubscriptionId}" `
                          --subscription $SubscriptionId `
                          -o none

# Log in to Azure DevOps
az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 `
                            --query "accessToken" `
                            --output tsv `
                            | Tee-Object -Variable accessToken `
                            | az devops login --organization $OrganizationUrl
az devops project show --project $Project --query id -o tsv | Set-Variable projectId
if (!$projectId) {
    Write-Error "Project '${Project}' not found in organization '${OrganizationUrl}"
    exit 1
}

az devops service-endpoint list -p $Project `
                                --query "[?name=='${ServiceConnectionName}'].id" `
                                -o tsv `
                                | Set-Variable serviceEndpointId

# TODO: Create the service connection (Azure CLI)
# az devops service-endpoint azurerm create --azure-rm-service-principal-id $identity.clientId `
#                                           --azure-rm-subscription-id $SubscriptionId `
#                                           --azure-rm-subscription-name $SubscriptionId `
#                                           --azure-rm-tenant-id $identity.tenantId `
#                                           --name $IdentityName `
#                                           --organization $OrganizationUrl `
#                                           --project $Project `
                                        
# Prepare service connection REST API request body
Get-Content -Path (Join-Path $PSScriptRoot serviceEndpointRequest.json) `
            | ConvertFrom-Json `
            | Set-Variable serviceEndpointRequest

$serviceEndpointRequest.authorization.parameters.servicePrincipalId = $identity.clientId
$serviceEndpointRequest.authorization.parameters.tenantId = $identity.tenantId
$serviceEndpointRequest.data.subscriptionId = $SubscriptionId
$serviceEndpointRequest.data.subscriptionName = $subscription.name
$serviceEndpointRequest.name = $ServiceConnectionName
$serviceEndpointRequest.serviceEndpointProjectReferences[0].description = "Created with $($MyInvocation.MyCommand.Name)"
$serviceEndpointRequest.serviceEndpointProjectReferences[0].name = $ServiceConnectionName
$serviceEndpointRequest.serviceEndpointProjectReferences[0].projectReference.id = $projectId
$serviceEndpointRequest.serviceEndpointProjectReferences[0].projectReference.name = $Project
$serviceEndpointRequest | ConvertTo-Json -Depth 4 | Set-Variable body

$apiUri = "${OrganizationUrl}/_apis/serviceendpoint/endpoints"
if (!$serviceEndpointId) {
    Write-Verbose "Creating service connection '$($serviceEndpointRequest.name)'..."
} else {
    $apiUri += "/${serviceEndpointId}"
    Write-Verbose "Updating service connection '$($serviceEndpointRequest.name)' (${serviceEndpointId})..."
}
$apiUri += "?api-version=${apiVersion}"

$headers = @{
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer $accessToken"
}
Invoke-RestMethod -Uri $apiUri `
                  -Method ($serviceEndpointId ? 'PUT' : 'POST') `
                  -Headers $headers `
                  -Body $body `
                  | Set-Variable response

$response | ConvertTo-Json