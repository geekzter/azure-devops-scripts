#!/usr/bin/env pwsh
#Requires -Version 7
[CmdletBinding(DefaultParameterSetName = 'AAD')]
param ( 
    [parameter(Mandatory=$true,HelpMessage="Url of the Azure DevOps Organization")]
    [ValidateNotNullOrEmpty()]
    [uri]
    $OrganizationUrl=($env:AZDO_ORG_SERVICE_URL ?? $env:SYSTEM_COLLECTIONURI),
    
    [parameter(Mandatory=$false,HelpMessage="PAT token with read access on 'User Profile' scope",ParameterSetName='Token')]
    [string]
    $Token=($env:AZURE_DEVOPS_EXT_PAT ?? $env:AZDO_PERSONAL_ACCESS_TOKEN),

    [parameter(Mandatory=$false,HelpMessage="Azure Active Directory tenant id",ParameterSetName='AAD')]
    [guid]
    $TenantId=($env:ARM_TENANT_ID ?? $env:AZURE_TENANT_ID ?? [guid]::Empty)
) 
$ErrorActionPreference = 'Stop'
Write-Debug $MyInvocation.line
. (Join-Path $PSScriptRoot functions.ps1)

$OrganizationUrl = $OrganizationUrl.ToString().TrimEnd('/')
if ($OrganizationUrl -match "^https://dev.azure.com/(\w+)|^https://(\w+).visualstudio.com/") {
  $organizationName = ($Matches[1] ?? $Matches[2])
} else {
  Write-Error "Invalid organization url. Please provide a valid url of the form https://dev.azure.com/{organization} or https://{organization}.visualstudio.com"
  exit 1
}

if ($Token) {
  "Basic {0}" -f [Convert]::ToBase64String([System.Text.ASCIIEncoding]::ASCII.GetBytes(":${Token}")) `
              | Set-Variable authHeader
} else {
  Login-Az -TenantId $TenantId
  az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 `
                              --query "accessToken" `
                              --output tsv `
                              | Set-Variable aadToken
  $authHeader = "Bearer ${aadToken}"
}
Write-Debug $authHeader

Write-Host "Retrieving member information from profile REST API..."
$profileUrl = "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1-preview.1"
Write-Debug $profileUrl
Invoke-WebRequest -Uri $profileUrl `
                  -Headers @{
                      Accept         = "application/json"
                      Authorization  = $authHeader
                      "Content-Type" = "application/json"
                  } `
                  -Method Get `
                  | Tee-Object -Variable profileResponse `
                  | Select-Object -ExpandProperty Content `
                  | Tee-Object -Variable profileJson `
                  | ConvertFrom-Json `
                  | Set-Variable profile
if (!$profile) {
  Write-Error "Could not find profile"
  exit 2
}
$profileResponse | Format-List | Out-String | Write-Debug
$profileJson | ConvertFrom-Json -Depth 4 | ConvertTo-Json -Depth 4 | Write-Debug
$profile | Format-List | Out-String | Write-Debug

Write-Host "Retrieving organization from accounts REST API..."
$accountsUrl = "https://app.vssps.visualstudio.com/_apis/accounts?api-version=7.1-preview.1&memberId=$($profile.id)"
Write-Debug $accountsUrl
Invoke-WebRequest -Uri $accountsUrl `
                  -Headers @{
                      Accept         = "application/json"
                      Authorization  = $authHeader
                      "Content-Type" = "application/json"
                  } `
                  -Method Get `
                  | Tee-Object -Variable accountsResponse `
                  | Select-Object -ExpandProperty Content `
                  | Tee-Object -Variable accountsJson `
                  | ConvertFrom-Json `
                  | Select-Object -ExpandProperty value `
                  | Tee-Object -Variable accounts `
                  | Where-Object { $_.accountName -eq $organizationName } `
                  | Set-Variable account
$accountsResponse | Format-List | Out-String | Write-Debug
$accountsJson | ConvertFrom-Json -Depth 4 | ConvertTo-Json -Depth 4 | Write-Debug
$accounts | Format-Table | Out-String | Write-Debug
if (!$account) {
  Write-Error "Could not find account for organization '${organizationName}'"
  exit 2
}

Add-Member -InputObject $account -NotePropertyName issuerUrl -NotePropertyValue "https://vstoken.dev.azure.com/$($account.accountId)"
$account | Format-List