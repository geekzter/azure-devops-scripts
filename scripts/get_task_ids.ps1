#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Get latest version of agent
#> 
#Requires -Version 7.2
param ( 
    [parameter(Mandatory=$false)][string]
    [ValidateNotNull()]
    $RepoDirectory=(Get-Location).Path,

    [parameter(Mandatory=$false)]
    [switch]
    $TaskIds=$false    
) 

Get-ChildItem -Path (Join-Path $RepoDirectory task.json) -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
                                                                                                       | Set-Variable taskJsonLocations
                                                                                                       
[System.Collections.ArrayList]$tasks = @()
foreach ($taskJson in $taskJsonLocations) {
    Write-Debug $taskJson
    Get-Content $taskJson | ConvertFrom-Json -AsHashtable | Set-Variable task
    $tasks.Add($task) | Out-Null
}

if ($TaskIds) {
    $tasks | Select-Object -ExpandProperty id | Get-Unique
} else {
    # $tasks[0]
    $tasks | ForEach-Object {[PSCustomObject]$_} `
           | Format-Table -Property name, `
                                    id, `
                                    friendlyName, `
                                    description, `
                                    version, `
                                    @{Label="version"; Expression={$_.version.ToString()}}, `
                                    author
}
