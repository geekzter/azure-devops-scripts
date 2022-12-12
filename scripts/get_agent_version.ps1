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
    [ValidateSet("Stable", "Latest", "Prerelease")]
    $Channel="Latest",

    [parameter(Mandatory=$false)]
    [ValidateSet(2, 3)]
    [int]
    $MajorVersion=2
) 

(Invoke-RestMethod -Uri https://api.github.com/repos/microsoft/azure-pipelines-agent/releases) | Where-Object {!$_.draft} `
                                                                                               | Where-Object {$_.name -match "^v${MajorVersion}"} `
                                                                                               | Sort-Object -Property @{Expression = "created_at"; Descending = $true} `
                                                                                               | Set-Variable releases
switch ($Channel) {
    "Stable" {
        $releases | Where-Object {!$_.prerelease} `
                  | Select-Object -Skip 1 -First 1 `
                  | Set-Variable release
        break
    }
    default { # Latest
        $releases | Where-Object {!$_.prerelease} `
                  | Select-Object -Skip 0 -First 1 `
                  | Set-Variable release
        break
    }
    "Prerelease" {
        $releases | Select-Object -Skip 0 -First 1 `
                  | Set-Variable release
        break
    }
}

if (!$release) {
    Write-Warning "No agent release found for v${MajorVersion}, '${Channel}' channel"
    exit
}
Write-Debug "release: ${release}"
$release.name -replace "^v","" | Set-Variable agentVersion

if ($IsWindows) {
    $osString = [Environment]::Is64BitProcess ? "win-x64" : "win-x86"
    $extension = "zip"
}
if ($IsMacOS) {
    $osString = (($PSVersionTable.OS -imatch "ARM64") -and $MajorVersion -ge 3) ? "osx-arm64" : "osx-x64"
    $extension = "tar.gz"
}
if ($IsLinux) {
    $osString = "linux-"
    $arch = $(uname -m)
    if ($arch -in @("arm", "arm64")) {
        $osString += $arch
    } elseif ($arch -eq "x86_64") {
        $osString += "x64"
    } else {
        Write-Warning "Unknown architecture '${arch}', defaulting to x64"
        $osString += "x64"
    }
    $extension = "tar.gz"
}

$packagePrefix = $ExcludeNode6 ? "pipelines" : "vsts"
"{0}-agent-{1}-{2}.{3}" -f $packagePrefix, $osString, $agentVersion, $extension | Set-Variable agentPackage
"https://vstsagentpackage.azureedge.net/agent/{0}/{1}" -f $agentVersion, $agentPackage | Set-Variable packageUrl

try {
    Write-Verbose "Validating whether package exists at '${packageUrl}'..."
    Invoke-WebRequest -method HEAD $packageUrl | Set-Variable packageResponse
    $packageResponse | Format-List | Out-String | Write-Debug
    Write-Host "Agent package exists at url: ${packageUrl}"
} catch {
    Write-Warning "Could not access agent package url: ${packageUrl}. $($_.Exception.Message)"
}
