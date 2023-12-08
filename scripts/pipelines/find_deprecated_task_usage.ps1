#!/usr/bin/env pwsh
# TODO:
# - Export CSV
# - Enumerate all projects
# - Encode project names
# - Support release pipelines
# - Progress bars

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
    
    [parameter(Mandatory=$false,HelpMessage="PAT token with read access on 'Agent Pools' scope",ParameterSetName="pool")]
    [string]
    $Token=($env:AZURE_DEVOPS_EXT_PAT ?? $env:AZDO_PERSONAL_ACCESS_TOKEN)
    

    # [parameter(Mandatory=$false,HelpMessage="Do not ask for input to start processing",ParameterSetName="pool")]
    # [switch]
    # $Force=$false
) 
$organizationName = $OrganizationUrl.Split('/')[3]
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
# $apiVersion = "7.1-preview.1"
$apiVersion = "7.1"
# $apiVersion = "7.2-preview.1"

"{0}/_apis/distributedtask/tasks?api-version={1}" -f $OrganizationUrl, $apiVersion `
                                                  | Set-Variable -Name tasksRequestUrl

Write-Debug $tasksRequestUrl
Invoke-WebRequest -Headers $headers `
                  -Uri $tasksRequestUrl `
                  -Method Get `
                  | Select-Object -ExpandProperty Content `
                  | ConvertFrom-Json -AsHashtable `
                  | Select-Object -ExpandProperty value `
                  | ForEach-Object {[PSCustomObject]$_} `
                  | Where-Object {$_.deprecated -ieq 'true'}
                  | ForEach-Object {
                        $_ | Add-Member -MemberType NoteProperty -Name majorVersion -Value $_.version.major
                        $_ | Add-Member -MemberType NoteProperty -Name fullName -Value ("{0}@{1}" -f $_.name, $_.version.major)
                        $_ | Add-Member -MemberType NoteProperty -Name FullVersion -Value (New-Object -TypeName System.Version -ArgumentList $_.version.major, $_.version.minor, $_.version.patch)
                        $_.version = $_.FullVersion.ToString(3)
                        $_
                    } `
                  | Sort-Object -Property name, version `
                  | Set-Variable -Name deprecatedTasks -Scope global

$deprecatedTasks | Format-Table id, name, fullName, version | Out-String | Write-Debug

[System.Collections.ArrayList]$allDeprecatedTimelineTasks = @()
$exportFilePath = (Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::newguid().ToString()).csv")

try {
    do {
        "{0}/{1}/_apis/pipelines?continuationToken={2}&api-version={3}&`$top=200" -f $OrganizationUrl, $Project, $pipelineContinuationToken, $apiVersion `
                                                                                  | Set-Variable -Name pipelinesRequestUrl
    
        Write-Debug $pipelinesRequestUrl
        Invoke-WebRequest -Headers $headers `
                          -Uri $pipelinesRequestUrl `
                          -Method Get `
                          | Tee-Object -Variable pipelinesResponse `
                          | ConvertFrom-Json `
                          | Select-Object -ExpandProperty value `
                          | Set-Variable pipelines
    
        $pipelineContinuationToken = "$($pipelinesResponse.Headers.'X-MS-pipelineContinuationToken')"
        Write-Debug "pipelineContinuationToken: ${pipelineContinuationToken}"
    
        foreach ($pipeline in $pipelines) {
            Write-Debug "Pipeline run"
            $pipeline | Format-List | Out-String | Write-Debug
    
            # GET https://dev.azure.com/{organization}/{project}/_apis/pipelines/{pipelineId}/runs?api-version=7.2-preview.1
            "{0}/{1}/_apis/pipelines/{2}/runs?&api-version={4}&`$top=200" -f $OrganizationUrl, $Project, $pipeline.id, $pipelineRunContinuationToken, $apiVersion `
                                                                                                       | Set-Variable -Name pipelineRunsRequestUrl
    
            Write-Debug $pipelineRunsRequestUrl
            Invoke-WebRequest -Headers $headers `
                              -Uri $pipelineRunsRequestUrl `
                              -Method Get `
                              | Tee-Object -Variable pipelineRunsResponse `
                              | ConvertFrom-Json `
                              | Select-Object -ExpandProperty value `
                              | Tee-Object -Variable pipelineRuns `
                              | Select-Object -First 1 `
                              | Set-Variable pipelineRun
            Write-Debug "timelineResponse: ${pipelineRunsResponse}"
    
            Write-Debug "Pipeline run:"
            $pipelineRun | Format-List | Out-String | Write-Debug
    
            "{0}/{1}/_apis/build/builds/{2}/timeline?api-version={3}" -f $OrganizationUrl, $Project, $pipelineRun.id, $apiVersion `
                                                                      | Set-Variable -Name timelineRequestUrl
            Write-Debug $timelineRequestUrl
            Invoke-WebRequest -Headers $headers `
                              -Uri $timelineRequestUrl `
                              -Method Get `
                              | Tee-Object -Variable timelineResponse `
                              | ConvertFrom-Json `
                              | Select-Object -ExpandProperty records `
                              | Where-Object {$_.type -ieq "Task"} `
                              | Where-Object {![String]::IsNullOrEmpty($_.task.name)}
                              | ForEach-Object {
                                  $_ | Add-Member -MemberType NoteProperty -Name taskId -Value $_.task.id
                                  $_ | Add-Member -MemberType NoteProperty -Name taskName -Value $_.task.name
                                  $_ | Add-Member -MemberType NoteProperty -Name taskFullName -Value ("{0}@{1}" -f $_.task.name, $_.task.version.Substring(0,1))
                                  $_ | Add-Member -MemberType NoteProperty -Name taskVersion -Value $_.task.version
                                  $_
                              } `
                              | Set-Variable -Name timelineRecords -Scope global
            Write-Debug "timelineResponse: ${timelineResponse}"
    
            if (!$timelineRecords) {
                Write-Warning "No timeline records found for pipeline run $($pipelineRun.id)"
                continue
            }
    
            $timelineRecords | Where-Object {$_.type -ieq "Task"} `
                             | Where-Object {![String]::IsNullOrEmpty($_.task.name)}
                             | Select-Object -ExpandProperty task `
                             | ForEach-Object {
                                $_ | Add-Member -MemberType NoteProperty -Name fullName -Value ("{0}@{1}" -f $_.name, $_.version.Substring(0,1))
                                $_
                             } `
                             | Sort-Object -Property name, version `
                             | Set-Variable -Name timelineTasks -Scope global

            $deprecatedTimelineTasks = @{}
            foreach ($task in $timelineRecords) {
                $deprecatedTask = $null
                $deprecatedTasks | Where-Object {$_.fullName -ieq $task.taskFullName} `
                                 | Set-Variable -Name deprecatedTask
                if ($deprecatedTask) {  
                    # Write-Warning "Task $($deprecatedTask.fullName) is deprecated, please update to a newer version"
                    # $deprecatedTimelineTasks.Add($task) | Out-Null
                    "{0}/{1}/_build/results?buildId={2}&view=logs&j={3}&t={4}&api-version={5}" -f $OrganizationUrl, $Project, $pipelineRun.id, $task.parentId, $task.id, $apiVersion `
                                                                                               | Set-Variable -Name timelineRecordUrl
                    $task | Add-Member -MemberType NoteProperty -Name runUrl -Value $timelineRecordUrl
                    $task | Format-List | Out-String | Write-Debug
                    # Use Hastable to track unuque tasks per pipeline
                    $deprecatedTimelineTasks[$task.taskFullName] = $task
                }
            }
            $allDeprecatedTimelineTasks.AddRange($deprecatedTimelineTasks.Values)
            $deprecatedTimelineTasks.Values | Format-Table name, fullName, version, runUrl | Out-String | Write-Debug                                                                                               
        }
    } while ($pipelineContinuationToken)
} catch [System.Management.Automation.HaltCommandException] {
    Write-Warning "Skipped paging through results" 
} finally {
    $allDeprecatedTimelineTasks | ForEach-Object {
                                    $_ | Add-Member -MemberType NoteProperty -Name organization -Value $organizationName
                                    $_ | Add-Member -MemberType NoteProperty -Name project -Value $Project
                                    $_ | Add-Member -MemberType NoteProperty -Name pipeline -Value $pipeline.name
                                    $_
                                } 
                                | Select-Object -Property organization, project, pipeline, taskId, taskName, taskFullName, taskVersion, runUrl `
                                | Export-Csv -Path $exportFilePath
    $allDeprecatedTimelineTasks | Format-Table -Property taskFullName, runUrl
    Write-Host "`Deprecated task usage in '${OrganizationUrl}/${Project}' has been saved to ${exportFilePath}"
}
