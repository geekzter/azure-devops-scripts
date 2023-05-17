#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Get task ID's
#> 
#Requires -Version 7.2
param ( 
    [parameter(Mandatory=$false)][string]
    [ValidateNotNull()]
    $RepoDirectory=(Get-Location).Path,

    [parameter(Mandatory=$false)]
    [switch]
    $DeprecatedTasksOnly,

    [parameter(Mandatory=$false)]
    [switch]
    $ShowTaskIdsOnly    
) 

Get-ChildItem -Path (Join-Path $RepoDirectory task.json) -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
                                                                                                       | Set-Variable taskJsonLocations

if (!$taskJsonLocations) {
    Write-Error "No task.json files found in ${RepoDirectory}, specify -RepoDirectory"
    exit 1
}
                                                     
[System.Collections.ArrayList]$tasks = @()
foreach ($taskJson in $taskJsonLocations) {
    Write-Debug $taskJson
    Get-Content $taskJson | ConvertFrom-Json -AsHashtable | Set-Variable task
    $task | Format-Table | Out-String | Write-Debug
    $tasks.Add($task) | Out-Null
}

$tasks | ForEach-Object {[PSCustomObject]$_} `
       | Where-Object {!$DeprecatedTasksOnly -or $_.deprecated} `
       | ForEach-Object {
    "{0}@{1}" -f $_.name, $_.version.Major | Set-Variable fullName
    $_ | Add-Member -MemberType NoteProperty -Name fullName -Value $fullName
    $_
} | Set-Variable tasks

if ($ShowTaskIdsOnly) {
    $tasks | Select-Object -ExpandProperty id | Get-Unique
} else {
    $tasks | Format-Table -Property fullName, `
                                    id, `
                                    deprecated, `
                                    friendlyName, `
                                    description, `
                                    version, `
                                    @{Label="version"; Expression={$_.version.ToString()}}, `
                                    author
}
