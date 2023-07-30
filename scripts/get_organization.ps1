#!/usr/bin/env pwsh
#Requires -Version 7
param ( 
    [parameter(Mandatory=$true,ParameterSetName="Organization",HelpMessage="Url of the Azure DevOps Organization")]
    [ValidateNotNullOrEmpty()]
    [uri]
    $OrganizationUrl=($env:AZDO_ORG_SERVICE_URL ?? $env:SYSTEM_COLLECTIONURI)
) 

$OrganizationUrl = $OrganizationUrl.ToString().TrimEnd('/')
if ($OrganizationUrl -match "^https://dev.azure.com/(\w+)|^https://(\w+).visualstudio.com/") {
  $organizationName = ($Matches[1] ?? $Matches[2])
} else {
  Write-Error "Invalid organization url. Please provide a valid url of the form https://dev.azure.com/{organization} or https://{organization}.visualstudio.com"
  exit 1
}

Write-Host "Retrieving member information from profile REST API..."
$profileUrl = "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1-preview.1"
Write-Debug $profileUrl
az rest --method get `
        --uri $profileUrl `
        --resource 499b84ac-1321-427f-aa17-267ca6975798 `
        -o json `
        | Tee-Object -Variable profileJson `
        | ConvertFrom-Json `
        | Set-Variable profile
$profileJson | Write-Debug

Write-Host "Retrieving organization from accounts REST API..."
$accountsUrl = "https://app.vssps.visualstudio.com/_apis/accounts?api-version=7.1-preview.1&memberId=$($profile.id)"
Write-Debug $accountsUrl
az rest --method get `
        --uri $accountsUrl `
        --resource 499b84ac-1321-427f-aa17-267ca6975798 `
        --query "value[?accountName=='${organizationName}'] | [0]" `
        -o json `
        | Tee-Object -Variable accountsJson `
        | ConvertFrom-Json `
        | Set-Variable account

if (!$account -eq $null) {
  Write-Error "Could not find account for organization '${organizationName}'"
  exit 2
}
$accountsJson | Write-Debug
Add-Member -InputObject $account -NotePropertyName issuerUrl -NotePropertyValue "https://vstoken.dev.azure.com/$($account.accountId)"
$account | Format-List