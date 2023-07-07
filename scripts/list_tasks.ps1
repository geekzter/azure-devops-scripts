#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Get Azure Pipeline task data from the Azure Pipelines task repo
#> 
#Requires -Version 7.2
param ( 
    [parameter(Mandatory=$false)]
    [string]
    $RepoDirectory,

    [parameter(Mandatory=$false)]
    [switch]
    $AzureTasksOnly,

    [parameter(Mandatory=$false)]
    [switch]
    $DeprecatedTasksOnly,

    [parameter(Mandatory=$false)]
    [string]
    [ValidateSet("Csv","Ids","Table")]
    $Format="Table",

    [parameter(Mandatory=$false)]
    [string[]]
    #$Property=@("directoryName","id","name","friendlyName","author","helpUrl","category","visibility","runsOn","version","preview","instanceNameFormat","groups","inputs","dataSourceBindings","execution","fullName","majorVersion")
    $Property=@("fullName","id","name","friendlyName","version","majorVersion")
) 

if (!$RepoDirectory) {
    # Try to find task repo directory
    $directoryElements = $PSScriptRoot.Split([IO.Path]::DirectorySeparatorChar)
    $directoryElements[0..($directoryElements.Length-4)] -join [IO.Path]::DirectorySeparatorChar `
                                                         | Set-Variable RepoBaseDirectory

    Join-Path $RepoBaseDirectory "microsoft" "azure-pipelines-tasks" | Set-Variable RepoDirectory
    if (!(Test-Path $RepoDirectory)) {
        Write-Warning "No RepoDirectory specifed"
        exit
    }
}

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
    Split-Path $taskJson -Parent | Split-Path -Leaf | Set-Variable taskJsonDirectoryName
    $task.Add("directoryName", $taskJsonDirectoryName) | Out-Null
    $task | Format-Table | Out-String | Write-Debug
    $tasks.Add($task) | Out-Null
}

# Filter tasks
$tasks | ForEach-Object {[PSCustomObject]$_} `
       | Where-Object {!$AzureTasksOnly -or ($_ | Select-Object -ExpandProperty inputs -ErrorAction SilentlyContinue | Where-Object -Property type -ieq 'connectedService:AzureRM')} `
       | Where-Object {!$DeprecatedTasksOnly -or $_.deprecated} `
       | Set-Variable tasks

# Format results
if ($Format -eq "Ids") {
    $tasks | Select-Object -ExpandProperty id `
           | Get-Unique `
           | Sort-Object `
           | Set-Variable tasks
} else {
    $tasks | ForEach-Object {
                "{0}@{1}" -f $_.name, $_.version.Major | Set-Variable fullName
                $_ | Add-Member -MemberType NoteProperty -Name fullName -Value $fullName
                $_ | Add-Member -MemberType NoteProperty -Name majorVersion -Value $_.version.Major
                $_.version = ("{0}.{1}.{2}" -f $_.version.Major, $_.version.Minor, $_.version.Patch)
                if ($_.deprecated -ne $true) {
                    $_ | Add-Member -MemberType NoteProperty -Name deprecated -Value $false
                }
                $_
           } `
           | Sort-Object -Property fullName `
           | Select-Object -Property $Property `
           | Set-Variable tasks
}

# Display results
$tasks | Format-Table

# Export results
if ($Format -eq "Csv") {
    $csvFullName = "$((New-TemporaryFile).FullName).csv"
    $tasks | Select-Object -ExcludeProperty description, helpMarkDown, releaseNotes `
           | Export-Csv -Path $csvFullName -UseQuotes Always
    Write-Host "Results exported to ${csvFullName}"
}