#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Find deprecated tasks used in Azure Pipelines

.DESCRIPTION 
    This script lists all deprecated tasks available in an Azure DevOps organization and then processes all pipelines in the organization for usage of those tasks.
    The script will output a CSV file with the deprecated task usage and a summary of the deprecated task usage in the organization.
    This script is intended to be used with the list-deprecated-tasks.yml pipeline

.EXAMPLE
    list_deprecated_tasks.ps1 -OrganizationUrl https://dev.azure.com/contoso -Project <project>

.EXAMPLE
    list_deprecated_tasks.ps1 -OrganizationUrl https://dev.azure.com/contoso -Project <project> -Token <PAT>

.EXAMPLE
    list_deprecated_tasks.ps1 -ListTasksOnly

#>
#Requires -Version 7.2
# TODO:
# - Find deprecated task usage in release pipelines

param ( 
    [parameter(Mandatory=$false,HelpMessage="Azure DevOps organization url (e.g. https://dev.azure.com/contoso)")]
    [ValidateNotNullOrEmpty()]
    [string]
    $OrganizationUrl=($env:AZDO_ORG_SERVICE_URL ?? $env:SYSTEM_COLLECTIONURI),
    
    [parameter(Mandatory=$false,HelpMessage="Azure DevOps project name")]
    [string]
    $Project=$env:AZDO_PROJECT,
    
    [parameter(Mandatory=$false,HelpMessage="Access token with Build, Environment, Release scopes")]
    [string]
    $Token=($env:AZDO_PERSONAL_ACCESS_TOKEN ?? $env:AZURE_DEVOPS_EXT_PAT ?? $env:SYSTEM_ACCESSTOKEN),

    [parameter(Mandatory=$false,HelpMessage="Path to export CSV file to")]
    [string]
    $ExportDirectory=($env:BUILD_ARTIFACTSTAGINGDIRECTORY ?? [System.IO.Path]::GetTempPath()),

    [parameter(Mandatory=$false,HelpMessage="Don't process pipelines to find task usage, only list deprecated tasks")]
    [switch]
    $ListTasksOnly=$false,

    [parameter(Mandatory=$false,HelpMessage="Show matches found as the script runs")]
    [switch]
    $StreamResults=($env:TF_BUILD -ieq 'true')
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
                Write-Error "Install Azure CLI (http://aka.ms/azure-cli) to log in to Azure DevOps"
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

    $apiResponse | Format-List | Out-String | Write-Debug
    return $apiResponse
}
function Write-ProgressMessage (
    [parameter(Mandatory=$true)]
    [string]
    $Message
) {
    if ($ProgressPreference -ieq 'SilentlyContinue') {
        Write-Host $Message
    } else {
        Write-Verbose $Message
    }
}


if ($env:SYSTEM_DEBUG -eq "true") {
    $InformationPreference = "Continue"
    $VerbosePreference = "Continue"
    $DebugPreference = "Continue"

    Get-ChildItem -Path Env: -Force -Recurse -Include * | Sort-Object -Property Name | Format-Table -AutoSize | Out-String
}
$apiVersion = "7.1"

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
                   | Set-Variable -Name deprecatedTasks

Write-Host "The following tasks available in organization '${OrganizationUrl}' are marked as deprecated:"
$deprecatedTasks | Format-Table -AutoSize -Property @{ Name='task'; Expression = 'fullName'; Width = 40 }, `
                                                    @{ Name='id'; Expression = 'id'; Width = 36 }, `
                                                    @{ Name='version'; Expression = 'version'; Width = 8 } `
                 | Out-String -Width 88

if ($ListTasksOnly) {
    exit 0
}

# Create list of projects to process
[System.Collections.ArrayList]$allDeprecatedTimelineTasks = @()
if ($Project) {
    $projectNames = @($Project)
} else {
    [System.Collections.ArrayList]$projectNames = @()
    do {
        "{0}/_apis/projects?`$top=200&continuationToken={1}&api-version={2}" -f $OrganizationUrl, $projectContinuationToken, $apiVersion `
                                                                             | Set-Variable -Name projectsRequestUrl
        Write-ProgressMessage "Retrieving projects for organization '${OrganizationUrl}'..."
        $projectNamesBatch = $null
        Invoke-AzDORestApi $projectsRequestUrl `
                           | Tee-Object -Variable projectsResponse `
                           | ConvertFrom-Json `
                           | Select-Object -ExpandProperty value `
                           | Select-Object -ExpandProperty name `
                           | Sort-Object `
                           | Set-Variable projectNamesBatch

        if ($projectNamesBatch.Count -eq 1) {
            $projectNames.Add($projectNamesBatch) | Out-Null
        } elseif ($projectNamesBatch.Count -gt 1) {
            $projectNames.AddRange($projectNamesBatch)
        }

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
            Status           = "${projectName} (${projectIndex} of $($projectNames.Count))"
            PercentComplete  =  ($projectIndex / $($projectNames.Count)) * 100
            CurrentOperation = 'ProjectLoop'
        }
        Write-Progress @projectLoopProgressParameters


        $projectUrl = "{0}/{1}" -f $OrganizationUrl, [uri]::EscapeUriString($projectName)
        $pipelineContinuationToken = $null

        Write-ProgressMessage "Retrieving pipelines for project '${projectName}'..."
        [System.Collections.ArrayList]$pipelines = @()
        do {
            # BUG: Continuation token is not working when the same pipeline name exists in more than <top> folders
            # BUG: orderBy is not working, $orderBy is
            # BUG: $orderBy does not order on 'folder asc'
            "{0}/_apis/pipelines?continuationToken={1}&api-version={2}&`$top=1000" -f $projectUrl, $pipelineContinuationToken, $apiVersion `
                                                                                   | Set-Variable -Name pipelinesRequestUrl
        
            $pipelinesBatch = $null
            Invoke-AzDORestApi $pipelinesRequestUrl `
                               | Tee-Object -Variable pipelinesResponse `
                               | ConvertFrom-Json `
                               | Select-Object -ExpandProperty value `
                               | Set-Variable pipelinesBatch
        
            if ($pipelinesBatch.Count -eq 1) {
                $pipelines.Add($pipelinesBatch) | Out-Null
            } elseif ($pipelinesBatch.Count -gt 1) {
                $pipelines.AddRange($pipelinesBatch)
            }
            Write-ProgressMessage "Retrieved $($pipelines.Count) pipelines for project '${projectName}' so far..."
            $pipelineContinuationToken = "$($pipelinesResponse.Headers.'X-MS-ContinuationToken')"
            Write-Debug "pipelineContinuationToken: ${pipelineContinuationToken}"
        } while ($pipelineContinuationToken)

        Write-ProgressMessage "Processing pipelines for project '${projectName}'..."
        $pipelineIndex = 0
        foreach ($pipeline in $pipelines) {
            $pipelineFullName = ("$($pipeline.folder)\$($pipeline.name)" -replace "[\\]+","\")
            $pipelineIndex++
            $pipelineLoopProgressParameters = @{
                ID               = 1
                Activity         = "Processing pipelines in '${projectName}'"
                Status           = "${pipelineFullName} (${pipelineIndex} of $($pipelines.Count))"
                PercentComplete  =  ($pipelineIndex / $($pipelines.Count)) * 100
                CurrentOperation = 'PipelineLoop'
            }
            Write-Progress @pipelineLoopProgressParameters
    
            Write-Debug "Pipeline run"
            $pipeline | Format-List | Out-String | Write-Debug
    
            "{0}/_apis/pipelines/{1}/runs?&api-version={2}&`$top=200" -f $projectUrl, $pipeline.id, $apiVersion `
                                                                        | Set-Variable -Name pipelineRunsRequestUrl
    
            $pipelineRun = $null
            Invoke-AzDORestApi $pipelineRunsRequestUrl `
                                | Tee-Object -Variable pipelineRunsResponse `
                                | ConvertFrom-Json `
                                | Select-Object -ExpandProperty value `
                                | Tee-Object -Variable pipelineRuns `
                                | Select-Object -First 1 `
                                | Set-Variable pipelineRun
    
            Write-Debug "Pipeline run:"
            $pipelineRun | Format-List | Out-String | Write-Debug

            if (!$pipelineRun) {
                Write-Debug "No pipeline runs found for pipeline $($pipeline.name)"
                continue
            }
    
            "{0}/_apis/build/builds/{1}/timeline?api-version={2}" -f $projectUrl, $pipelineRun.id, $apiVersion `
                                                                   | Set-Variable -Name timelineRequestUrl
            $timelineRecords = $null
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
                                | Set-Variable -Name timelineRecords
    
            if (!$timelineRecords) {
                Write-Verbose "No timeline records found for pipeline '${pipelineFullName}' run $($pipelineRun.id)"
                continue
            }

            $deprecatedTimelineTasks = @{}
            foreach ($task in $timelineRecords) {
                $deprecatedTask = $null
                $deprecatedTasks | Where-Object {$_.fullName -ieq $task.taskFullName} `
                                    | Set-Variable -Name deprecatedTask
                if ($deprecatedTask) {  
                    "{0}/_build/results?buildId={1}&view=logs&j={2}&t={3}" -f $projectUrl, $pipelineRun.id, $task.parentId, $task.id `
                                                                           | Set-Variable -Name timelineRecordUrl
                    if ($StreamResults) {
                        $timelineRecordUrl | Out-String -Width 200 | Write-Host
                    } else {
                        $timelineRecordUrl | Out-String -Width 200 | Write-Verbose
                    }
                                                                                        
                    $task | Add-Member -MemberType NoteProperty -Name organization -Value $organizationName
                    $task | Add-Member -MemberType NoteProperty -Name pipelineFolder -Value $pipeline.folder
                    $task | Add-Member -MemberType NoteProperty -Name pipelineFullName -Value $pipelineFullName
                    $task | Add-Member -MemberType NoteProperty -Name pipelineName -Value $pipeline.name
                    $task | Add-Member -MemberType NoteProperty -Name project -Value $projectName
                    $task | Add-Member -MemberType NoteProperty -Name runUrl -Value $timelineRecordUrl
                    $task | Format-List | Out-String | Write-Debug

                    # Use Hastable to track unique tasks per pipeline only
                    $deprecatedTimelineTasks[$task.taskFullName] = $task
                }
            }
            $allDeprecatedTimelineTasks.AddRange($deprecatedTimelineTasks.Values)
            $deprecatedTimelineTasks.Values | Format-Table name, fullName, version, runUrl | Out-String | Write-Debug                                                                                               
        }
        Write-Progress Id 1 -Completed    
    }
    Write-Progress Id 0 -Completed
} catch [System.Management.Automation.HaltCommandException] {
    Write-Warning "Skipped paging through results" 
} finally {
    if ($Project) {
        $exportFilePrefix = "${OrganizationName}-${Project}"
    } else {
        $exportFilePrefix = "${OrganizationName}"
    }
    $exportFilePath = (Join-Path $ExportDirectory "${exportFilePrefix}-$([DateTime]::Now.ToString('yyyyddhhmmss')).csv")
    $allDeprecatedTimelineTasks | Select-Object -Property organization, project, pipelineFolder, pipelineFullName, pipelineName, taskId, taskName, taskFullName, taskVersion, runUrl `
                                | Export-Csv -Path $exportFilePath

    if ($allDeprecatedTimelineTasks.Count -eq 0) {
        Write-Host "`nNo deprecated task usage found in '${OrganizationUrl}'"
        exit 0
    } else {
        $deprecationWarningMessage = "Deprecated task usage found in '${OrganizationUrl}'"
        if ($Project) {
            $deprecationWarningMessage += " for project '${Project}'"
        }
        Write-Warning ${deprecationWarningMessage}
        if ($env:TF_BUILD -ieq 'true') {
            Write-Host "##vso[task.logissue type=warning;]${deprecationWarningMessage}"
        }
    }

    Write-Host "`nDeprecated task usage in '${OrganizationUrl}':"
    $allDeprecatedTimelineTasks | Format-Table -Property @{ Name='task'; Expression = 'taskFullName'; Width = 40 }, `
                                                         @{ Name='pipeline'; Expression = 'runUrl'; Width = 200 } `
                                | Out-String -Width 256

    Write-Host "Deprecated task usage in '${OrganizationUrl}' has been saved to ${exportFilePath}"
}