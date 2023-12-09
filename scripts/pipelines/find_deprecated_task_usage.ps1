#!/usr/bin/env pwsh
# TODO:
# - Support release pipelines
# - Run from pipeline

<# 
.SYNOPSIS 

.DESCRIPTION 

.EXAMPLE

#> 

#Requires -Version 7.3

param ( 
    [string]
    $OrganizationUrl=($env:AZDO_ORG_SERVICE_URL ?? $env:SYSTEM_COLLECTIONURI),
    
    [string]
    $Project=$env:SYSTEM_TEAMPROJECT,
    
    [parameter(Mandatory=$false,HelpMessage="PAT token with read access on 'Agent Pools' scope",ParameterSetName="pool")]
    [string]
    $Token=($env:AZURE_DEVOPS_EXT_PAT ?? $env:AZDO_PERSONAL_ACCESS_TOKEN ?? $env:SYSTEM_ACCESSTOKEN)
) 
function Invoke-AzDORestApi (
    [parameter(Mandatory=$true)]
    [string]
    $Url,

    [parameter(Mandatory=$false)]
    [string]
    $Method="Get"
) {
    $aadTokenExpired = ($script:aadTokenExpiresOn -and ($script:aadTokenExpiresOn -le [DateTime]::Now))
    if (!$script:headers -or $aadTokenExpired) {
        if ($Token) {
            Write-Debug "Using token from parameter"
            $base64AuthInfo = [Convert]::ToBase64String([System.Text.ASCIIEncoding]::ASCII.GetBytes(":${Token}"))
            $authHeader = "Basic ${base64AuthInfo}"
        } else {
            if (!(Get-Command az)) {
                Write-Error "Azure CLI is not installed, get it at http://aka.ms/azure-cli"
                exit 1
            }
            if (!$script:aadTokenExpiresOn -or $aadTokenExpired) {
                if (!(az account show 2>$null)) {
                    az login --allow-no-subscriptions
                }
                az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 `
                                            -o json `
                                             | ConvertFrom-Json `
                                            | Set-Variable aadTokenResponse
                $authHeader = "Bearer $($aadTokenResponse.accessToken)"
                $script:aadTokenExpiresOn = [DateTime]::Parse($aadTokenResponse.expiresOn)    
            }
        }
        
        $script:headers = @{"Content-Type"="application/json"; "Accept"="application/json"}
        $script:headers.Add("Authorization", $authHeader)
    }

    Write-Debug "Api request: ${Url}"
    Invoke-WebRequest -Headers $script:headers `
                      -Method $Method `
                      -MaximumRetryCount 5 `
                      -RetryIntervalSec 1 `
                      -Uri $Url `
                      | Set-Variable -Name apiResponse

    Write-Debug "Api response: ${Url}"
    $apiResponse | Format-List | Out-String | Write-Debug
    return $apiResponse
}
# $apiVersion = "7.1-preview.2"
# $apiVersion = "7.1-preview.1"
$apiVersion = "7.1"
# $apiVersion = "7.2-preview.1"



$organizationName = $OrganizationUrl.Split('/')[3]
$OrganizationUrl = $OrganizationUrl.ToString().TrimEnd('/')


"{0}/_apis/distributedtask/tasks?api-version={1}" -f $OrganizationUrl, $apiVersion `
                                                  | Set-Variable -Name tasksRequestUrl

Write-Debug $tasksRequestUrl
Invoke-AzDORestApi $tasksRequestUrl `
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

Write-Verbose "Retrieving projects for organization '${OrganizationUrl}'..."
if ($Project) {
    $projectNames = @($Project)
} else {
    do {
        "{0}/_apis/projects?`$top=200&continuationToken={1}&api-version={2}" -f $OrganizationUrl, $projectContinuationToken, $apiVersion `
                                                                             | Set-Variable -Name projectsRequestUrl
        Write-Debug $projectsRequestUrl
        Invoke-AzDORestApi $projectsRequestUrl `
                           | Tee-Object -Variable projectsResponse `
                           | ConvertFrom-Json `
                           | Select-Object -ExpandProperty value `
                           | Select-Object -ExpandProperty name `
                           | Sort-Object `
                           | Set-Variable projectNames

        $projectContinuationToken = "$($projectsResponse.Headers.'X-MS-ContinuationToken')"
    } while ($projectContinuationToken)
}

# Try finally block to anticipate cancelation or timeout errors
try {
    $projectIndex = 0
    foreach ($projectName in $projectNames) {
        $projectIndex++
        $projectLoopProgressParameters = @{
            ID               = 0
            Activity         = "Processing projects"
            Status           = "${projectName} (${projectIndex} of $($projectNames.Length))"
            PercentComplete  =  ($projectIndex / $($projectNames.Length)) * 100
            CurrentOperation = 'ProjectLoop'
        }
        Write-Progress @projectLoopProgressParameters


        $projectUrl = "{0}/{1}" -f $OrganizationUrl, [uri]::EscapeUriString($projectName)
        $pipelineContinuationToken = $null

        do {
            "{0}/_apis/pipelines?continuationToken={1}&api-version={2}&`$top=200" -f $projectUrl, $pipelineContinuationToken, $apiVersion `
                                                                                  | Set-Variable -Name pipelinesRequestUrl
        
            Write-Verbose "Retrieving pipelines for project '${projectUrl}'..."
            Write-Debug $pipelinesRequestUrl
            $pipelines = $null
            Invoke-AzDORestApi $pipelinesRequestUrl `
                               | Tee-Object -Variable pipelinesResponse `
                               | ConvertFrom-Json `
                               | Select-Object -ExpandProperty value `
                               | Set-Variable pipelines
        
            $pipelineContinuationToken = "$($pipelinesResponse.Headers.'X-MS-ContinuationToken')"
            Write-Debug "pipelineContinuationToken: ${pipelineContinuationToken}"
        
            $pipelineIndex = 0
            foreach ($pipeline in $pipelines) {
                $pipelineIndex++
                $pipelineLoopProgressParameters = @{
                    ID               = 1
                    Activity         = "Processing pipelines in '${projectName}'"
                    Status           = "$($pipeline.name) (${pipelineIndex} of $($pipelines.Length))"
                    PercentComplete  =  ($pipelineIndex / $($pipelines.Length)) * 100
                    CurrentOperation = 'PipelineLoop'
                }
                Write-Progress @pipelineLoopProgressParameters
        

                Write-Debug "Pipeline run"
                $pipeline | Format-List | Out-String | Write-Debug
        
                # GET https://dev.azure.com/{organization}/{project}/_apis/pipelines/{pipelineId}/runs?api-version=7.2-preview.1
                "{0}/_apis/pipelines/{1}/runs?&api-version={2}&`$top=200" -f $projectUrl, $pipeline.id, $apiVersion `
                                                                          | Set-Variable -Name pipelineRunsRequestUrl
        
                Write-Debug $pipelineRunsRequestUrl
                Invoke-AzDORestApi $pipelineRunsRequestUrl `
                                   | Tee-Object -Variable pipelineRunsResponse `
                                   | ConvertFrom-Json `
                                   | Select-Object -ExpandProperty value `
                                   | Tee-Object -Variable pipelineRuns `
                                   | Select-Object -First 1 `
                                   | Set-Variable pipelineRun
                Write-Debug "timelineResponse: ${pipelineRunsResponse}"
        
                Write-Debug "Pipeline run:"
                $pipelineRun | Format-List | Out-String | Write-Debug

                if (!$pipelineRun) {
                    Write-Debug "No pipeline runs found for pipeline $($pipeline.name)"
                    continue
                }
        
                "{0}/_apis/build/builds/{1}/timeline?api-version={2}" -f $projectUrl, $pipelineRun.id, $apiVersion `
                                                                      | Set-Variable -Name timelineRequestUrl
                Write-Debug $timelineRequestUrl
                Invoke-AzDORestApi $timelineRequestUrl `
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
                        "{0}/_build/results?buildId={1}&view=logs&j={2}&t={3}&api-version={4}" -f $projectUrl, $pipelineRun.id, $task.parentId, $task.id, $apiVersion `
                                                                                               | Set-Variable -Name timelineRecordUrl
                        $task | Add-Member -MemberType NoteProperty -Name organization -Value $organizationName
                        $task | Add-Member -MemberType NoteProperty -Name pipeline -Value $pipeline.name
                        $task | Add-Member -MemberType NoteProperty -Name project -Value $projectName
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
        Write-Progress Id 1 -Completed    
    }
    Write-Progress Id 0 -Completed
} catch [System.Management.Automation.HaltCommandException] {
    Write-Warning "Skipped paging through results" 
} finally {
    $exportFilePath = (Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::newguid().ToString()).csv")
    $allDeprecatedTimelineTasks | Select-Object -Property organization, project, pipeline, taskId, taskName, taskFullName, taskVersion, runUrl `
                                | Export-Csv -Path $exportFilePath
    $allDeprecatedTimelineTasks | Format-Table -Property taskFullName, runUrl
    Write-Host "`Deprecated task usage in '${OrganizationUrl}/${Project}' has been saved to ${exportFilePath}"
}
