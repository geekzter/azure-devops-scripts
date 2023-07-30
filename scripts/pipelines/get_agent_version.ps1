#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Get latest version of agent
#> 
#Requires -Version 7.2
param ( 
    [parameter(Mandatory=$false)][switch]
    $ExcludeNode6,

    [parameter(Mandatory=$false)][string]
    [ValidateSet("Previous", "Current", "Prerelease")]
    $VersionPreference="Current",

    [parameter(Mandatory=$false)]
    [ValidateSet(2, 3)]
    [int]
    $MajorVersion=2
) 

. (Join-Path $PSScriptRoot functions.ps1)

$agentPackageUrl = Get-AgentPackageUrl -ExcludeNode6:$ExcludeNode6 `
                                       -VersionPreference $VersionPreference `
                                       -MajorVersion $MajorVersion

Write-Host "Agent package for this OS is at ${agentPackageUrl}"