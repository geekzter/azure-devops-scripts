#!/usr/bin/env pwsh

<# 
.SYNOPSIS 
    
 
.DESCRIPTION 

.EXAMPLE

#> 
#Requires -Version 7

param ( 
    [parameter(Mandatory=$true,HelpMessage="Name of the Managed Identity")]
    [string]
    [ValidateNotNullOrEmpty()]
    $IdentityName,

    [parameter(Mandatory=$true,HelpMessage="Name of the Azure Resource Group")]
    [string]
    [ValidateNotNullOrEmpty()]
    $ResourceGroupName,
    
    [parameter(Mandatory=$false,HelpMessage="Id of the Azure Subscription")]
    [guid]
    $SubscriptionId,

    [parameter(Mandatory=$false,HelpMessage="Url of the Azure DevOps Organization")]
    [uri]
    [ValidateNotNullOrEmpty()]
    $OrganizationUrl=($env:AZDO_ORG_SERVICE_URL || $env:SYSTEM_COLLECTIONURI),

    [parameter(Mandatory=$true,HelpMessage="Name of the Azure DevOps Project")]
    [string]
    [ValidateNotNullOrEmpty()]
    $Project
) 
$OrganizationUrl = $OrganizationUrl.ToString().Trim('/') # Strip trailing '/'
$organizationName = $OrganizationUrl.ToString().Split('/')[3]

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI is not installed. Please install it from https://docs.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

if (!(az account show 2>$null)) {
    az login -o none
}
if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
} else {
    $SubscriptionId = $(az account show --query id -o tsv)
}

az identity create -n $IdentityName `
                   -g $ResourceGroupName `
                   --subscription $SubscriptionId `
                   -o json `
                   | ConvertFrom-Json `
                   | Set-Variable identity
$identity | Format-List -Property id, clientId, tenantId

az role assignment create --assignee $identity.clientId `
                          --role Contributor `
                          --scope "/subscriptions/${SubscriptionId}" `
                          --subscription $SubscriptionId `
                          -o none

$federatedSubject = "sc://${organizationName}/${Project}/${IdentityName}"
az identity federated-credential create --name $IdentityName `
                                        --identity-name $IdentityName  `
                                        --resource-group $ResourceGroupName `
                                        --issuer https://app.vstoken.visualstudio.com `
                                        --subject $federatedSubject `
                                        --subscription $SubscriptionId

# az devops service-endpoint azurerm create --azure-rm-service-principal-id $identity.clientId `
#                                           --azure-rm-subscription-id $SubscriptionId `
#                                           --azure-rm-subscription-name $SubscriptionId `
#                                           --azure-rm-tenant-id $identity.tenantId `
#                                           --name $IdentityName `
#                                           --organization https://dev.azure.com/$env:SYSTEM_COLLECTIONURI `
#                                           --project $env:SYSTEM_TEAMPROJECT `
                                        