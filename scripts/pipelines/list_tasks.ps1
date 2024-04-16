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

    [parameter(Mandatory=$false, HelpMessage="Return only tasks that are using a Node runner")]
    [switch]
    $NodeTasksOnly,

    [parameter(Mandatory=$false)]
    [switch]
    $DeprecatedTasksOnly,

    [parameter(Mandatory=$false)]
    [string]
    [ValidateSet("Csv","Ids","Table")]
    $Format="Table",

    [parameter(Mandatory=$false)]
    [string[]]
    #$Property=@("directoryName","id","name","friendlyName","author","helpUrl","category","visibility","runsOn","version","preview","instanceNameFormat","groups","inputs","dataSourceBindings","execution","fullName","majorVersion","isAzureTask","usesNode","usesNode10","usesNode16","usesNode20")
    $Property=@("fullName","id","name","friendlyName","version","majorVersion")
) 

if (!$RepoDirectory) {
    # Try to find task repo directory
    $directoryElements = $PSScriptRoot.Split([IO.Path]::DirectorySeparatorChar)
    $directoryElements[0..($directoryElements.Length-5)] -join [IO.Path]::DirectorySeparatorChar `
                                                         | Set-Variable RepoBaseDirectory

    Join-Path $RepoBaseDirectory "microsoft" "azure-pipelines-tasks" | Set-Variable RepoDirectory
    if (!(Test-Path $RepoDirectory)) {
        Write-Warning "No RepoDirectory specifed"
        exit
    }
}

Get-ChildItem -Path $RepoDirectory `
              -Filter task.json `
              -Recurse -Force `
              -ErrorAction SilentlyContinue `
              | Where-Object DirectoryName -notmatch _generated `
              | Select-Object -ExpandProperty FullName `
              | Set-Variable taskJsonLocations

if (!$taskJsonLocations) {
    Write-Error "No task.json files found in ${RepoDirectory}, specify -RepoDirectory"
    exit 1
}
                                                     
[System.Collections.ArrayList]$tasks = @()
foreach ($taskJson in $taskJsonLocations) {
    Write-Debug $taskJson

    Split-Path $taskJson -Parent | Split-Path -Leaf | Set-Variable taskJsonDirectoryName
    Write-Verbose "Testing whether generated task.json file(s) exist(s)"
    $generatedTaskJson = $null
    Get-ChildItem -Path $RepoDirectory/_generated/${taskJsonDirectoryName}_Node*/task.json `
                  | Sort-Object -Property FullName `
                                -Descending `
                  | Select-Object -ExpandProperty FullName `
                                  -First 1
                  | Set-Variable generatedTaskJson
    if ($generatedTaskJson) {
        Write-Verbose "Found generated configuration at ${generatedTaskJson}"
        $taskJson = $generatedTaskJson
    }

    Write-Debug $taskJson
    Get-Content $taskJson | ConvertFrom-Json -AsHashtable | Set-Variable task
    $task.Add("directoryName", $taskJsonDirectoryName) | Out-Null
    $task | Format-Table | Out-String | Write-Debug
    $tasks.Add($task) | Out-Null
}

# Filter tasks
$tasks | ForEach-Object {[PSCustomObject]$_} `
       | ForEach-Object {
            # Azure
            $_ | Select-Object -ExpandProperty inputs -ErrorAction SilentlyContinue `
               | Where-Object -Property type -ieq 'connectedService:AzureRM' `
               | Set-Variable azureRmProperty
            $_ | Select-Object -ExpandProperty inputs -ErrorAction SilentlyContinue `
               | Where-Object -Property type -match 'connectedService' `
               | Select-Object -ExpandProperty type `
               | Set-Variable serviceConnections
            $_ | Add-Member -MemberType NoteProperty -Name serviceConnections -Value ($serviceConnections -join ",")
               if ($_ | Select-Object -ExpandProperty inputs -ErrorAction SilentlyContinue `
                   | Where-Object {($_.type -ieq 'connectedService:azurerm') -or ($_.type -ieq 'connectedService:dockerregistry') -or ($_.type -ieq 'connectedService:kubernetes') -or ($_.type -ieq 'connectedService:azureservicebus')} `
               ) {
                $_ | Add-Member -MemberType NoteProperty -Name isAzureTask -Value $true
            } else {
                $_ | Add-Member -MemberType NoteProperty -Name isAzureTask -Value $false
            }
            # Runner
            $_ | Add-Member -MemberType NoteProperty -Name usesNode6  -Value ($_.execution.Node6  -ne $null)
            $_ | Add-Member -MemberType NoteProperty -Name usesNode10 -Value ($_.execution.Node10 -ne $null)
            $_ | Add-Member -MemberType NoteProperty -Name usesNode16 -Value ($_.execution.Node16 -ne $null)
            $_ | Add-Member -MemberType NoteProperty -Name usesNode20 -Value ($_.execution.Node20 -ne $null)
            $_ | Add-Member -MemberType NoteProperty -Name usesNode   -Value ($_.usesNode6 -or $_.usesNode10 -or $_.usesNode16 -or $_.usesNode20)
            $_
         } `
       | Where-Object {!$AzureTasksOnly -or $_.isAzureTask} `
       | Where-Object {!$DeprecatedTasksOnly -or $_.deprecated} `
       | Where-Object {!$NodeTasksOnly -or $_.usesNode} `
       | Set-Variable tasks

# Add properties based on other parameters
if ($NodeTasksOnly) {
    [System.Collections.Generic.List[string]]$PropertyList = $Property
    $nodeProperties = @("usesNode","usesNode6","usesNode10","usesNode16","usesNode20")
    foreach ($nodeProperty in $nodeProperties) {
        if ($PropertyList -notcontains $nodeProperty) {
            $PropertyList.Add($nodeProperty)
        }
    }
    $Property = $PropertyList.ToArray()    
}

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

if ($NodeTasksOnly) {
    foreach ($nodeProperty in $nodeProperties) {
        $tasks | Group-Object -Property $nodeProperty `
               | Where-Object {$_.Name -eq 'True'} `
               | Select-Object -Property Count `
               | Add-Member -MemberType NoteProperty -Name NodeProperty -Value $nodeProperty -PassThru
    }
} else {
    $tasks | Measure-Object `
           | Select-Object -ExpandProperty Count `
           | Set-Variable taskCount
    Write-Host "${taskCount} tasks"
}

# Export results
if ($Format -eq "Csv") {
    $csvFullName = "$((New-TemporaryFile).FullName).csv"
    $tasks | Select-Object -ExcludeProperty description, helpMarkDown, releaseNotes `
           | Export-Csv -Path $csvFullName -UseQuotes Always
    Write-Host "Results exported to ${csvFullName}"
}