#!/usr/bin/env pwsh
<# 
.SYNOPSIS 

.DESCRIPTION 

.EXAMPLE

#> 

#Requires -Version 7.3

[CmdletBinding(DefaultParameterSetName="pool")]
param ( 
    [string]
    $OrganizationUrl=($env:AZDO_ORG_SERVICE_URL ?? $env:SYSTEM_COLLECTIONURI),
    
    [string]
    $Project=$env:SYSTEM_TEAMPROJECT,

    [int]
    $BuildId,
    
    [parameter(Mandatory=$false,HelpMessage="PAT token with read access on 'Agent Pools' scope",ParameterSetName="pool")]
    [string]
    $Token=($env:AZURE_DEVOPS_EXT_PAT ?? $env:AZDO_PERSONAL_ACCESS_TOKEN)
    

    # [parameter(Mandatory=$false,HelpMessage="Do not ask for input to start processing",ParameterSetName="pool")]
    # [switch]
    # $Force=$false
) 
$OrganizationUrl = $OrganizationUrl.ToString().TrimEnd('/')

if ($Token) {
    Write-Debug "Using token from parameter"
    $base64AuthInfo = [Convert]::ToBase64String([System.Text.ASCIIEncoding]::ASCII.GetBytes(":${Token}"))
    $authHeader = "Basic ${base64AuthInfo}"
} else {
    if (!(Get-Command az)) {
        Write-Error "Azure CLI is not installed, get it at http://aka.ms/azure-cli"
        exit 1
    }
    if (!(az account show 2>$null)) {
        az login --allow-no-subscriptions
    }
    az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 `
                                -o tsv `
                                --query accessToken `
                                | Set-Variable aadToken
    $authHeader = "Bearer ${aadToken}"    
}

$headers = @{"Content-Type"="application/json"; "Accept"="application/json"}
$headers.Add("Authorization", $authHeader)
# $apiVersion = "7.1-preview.2"
$apiVersion = "7.1-preview.1"

"{0}/_apis/distributedtask/tasks?api-version={1}" -f $OrganizationUrl, $apiVersion `
                                                  | Set-Variable -Name tasksRequestUrl

Write-Debug $tasksRequestUrl
Invoke-WebRequest -Headers $headers `
                  -Uri $tasksRequestUrl `
                  -Method Get `
                  -Verbose `
                  -Debug `
                  | Select-Object -ExpandProperty Content `
                  | ConvertFrom-Json -AsHashtable `
                  | Select-Object -ExpandProperty value `
                  | Where-Object {$_.deprecated -ieq 'true'}
                  | ForEach-Object {[PSCustomObject]$_} `
                  | ForEach-Object {
                    $_ | Add-Member -MemberType NoteProperty -Name majorVersion -Value $_.version.major
                    $_ | Add-Member -MemberType NoteProperty -Name fullName -Value ("{0}@{1}" -f $_.name, $_.version.major)
                    $_
                    } `
                  | Sort-Object -Property name, version `
                  | Set-Variable -Name deprecatedTasks

$deprecatedTasks | Format-Table id, name, fullName, version

# "{0}/{1}/_apis/build/builds/{2}/timeline?api-version={3}" -f $OrganizationUrl, $Project, $BuildId, $apiVersion `
#                                                           | Set-Variable -Name timelineRequestUrl
# Write-Debug $timelineRequestUrl
# Invoke-RestMethod -Headers $headers `
#                   -Uri $timelineRequestUrl `
#                   -Method Get `
#                   -Verbose `
#                   -Debug `
#                   | Select-Object -ExpandProperty records `
#                   | Set-Variable -Name timelineRecords
# # $timelineRecords

# $timelineRecords | Where-Object {$_.type -ieq "Task"} `
#                  | Where-Object {$_.task.name -ieq "CodeQL3000Finalize"}
# CodeQL3000Finalize