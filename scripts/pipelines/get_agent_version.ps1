#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Get latest version of agent
#> 
#Requires -Version 7.2
param ( 
    [parameter(Mandatory=$false)][switch]
    $ExcludeEoLNode,

    [parameter(Mandatory=$false)][string]
    [ValidateSet("Previous", "Current", "Prerelease")]
    $VersionPreference="Current",

    [parameter(Mandatory=$false)]
    [ValidateSet(2, 3, 4)]
    [int]
    $MajorVersion=4
) 

. (Join-Path $PSScriptRoot .. functions.ps1)

$agentPackageUrl = Get-AgentPackageUrl -ExcludeEoLNode:$ExcludeEoLNode `
                                       -VersionPreference $VersionPreference `
                                       -MajorVersion $MajorVersion

Write-Host "Agent package for this OS is at ${agentPackageUrl}"