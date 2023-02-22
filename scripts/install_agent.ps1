#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Installs and configures Azure Pipeline Agent, using AAD authentication instead of PAT
#> 
param ( 
    [parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]
    $AgentName=$env:COMPUTERNAME,
    
    [parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]
    $AgentPool='Default',
    
    [parameter(Mandatory=$false)]
    [ValidateSet(2, 3)]
    [int]
    $MajorVersion=3,

    [parameter(Mandatory=$false)][switch]
    $ExcludeNode6,

    [parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]
    $OrganizationUrl=$env:AZDO_ORG_SERVICE_URL
) 

. (Join-Path $PSScriptRoot functions.ps1)

if ($IsWindows) {
    Join-Path $env:ProgramFiles pipeline-agent | Set-Variable pipelineDirectory
    $pipelineWorkDirectory = "${env:ProgramData}\pipeline-agent\work"
}
if ($IsLinux) {
    $pipelineDirectory = "/opt/pipeline-agent"
    $pipelineWorkDirectory = "/var/opt/pipeline-agent/work"
}
if ($IsMacOS) {
    $pipelineDirectory = "~/pipeline-agent"
    $pipelineWorkDirectory = "~/pipeline-agent/work"
}

Get-AgentPackageUrl | Set-Variable agentPackageUrl
Write-Debug "Agent package URL: $agentPackageUrl"
$agentPackageUrl -Split "/" | Select-Object -Last 1 | Set-Variable agentPackage
Write-Debug "Agent package: $agentPackage"

New-Item -ItemType directory -Path $pipelineDirectory -Force -ErrorAction SilentlyContinue | Out-Null
if (Test-Path (Join-Path $pipelineDirectory .agent)) {
    Write-Host "Agent $AgentName already installed"
    exit 1
}
Push-Location $pipelineDirectory 

Write-Host "Retrieving agent from ${agentPackageUrl}..."
Invoke-Webrequest -Uri $agentPackageUrl -OutFile $agentPackage -UseBasicParsing

Write-Host "Extracting $agentPackage in ${pipelineDirectory}..."
if ($IsWindows) {
    Expand-Archive -Path $agentPackage -DestinationPath $pipelineDirectory
} else {
    tar zxf $agentPackage -C $pipelineDirectory
}
Write-Host "Extracted $agentPackage"

# Use work directory that does not contain spaces, and is located at the designated OS location for data
New-Item -ItemType Directory -Path $pipelineWorkDirectory -Force -ErrorAction SilentlyContinue | Out-Null
Join-Path $pipelineDirectory _work | Set-Variable pipelineWorkDirectoryLink
if (!(Test-Path $pipelineWorkDirectoryLink)) {
    New-Item -ItemType symboliclink -Path "${pipelineWorkDirectoryLink}" -Value "$pipelineWorkDirectory" -Force -ErrorAction SilentlyContinue | Out-Null
}

# Log in with Azure CLI (if not logged in yet)
Login-Az -DisplayMessages
az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 `
                            --query "accessToken" `
                            --output tsv `
                            | Set-Variable aadToken
if (!$aadToken) {
    Write-Warning "Could not obtain AAD token, exiting"
    exit 1
}
Write-Debug "AAD Token length: $($aadToken.Length)"

# # Configure agent
# Write-Host "Creating agent $AgentName and adding it to pool $AgentPool in organization $Organization..."
# .\${script}  --unattended `
#              --url $OrganizationUrl `
#              --auth pat --token $aadToken `
#              --pool $AgentPool `
#              --agent $AgentName --replace `
#              --acceptTeeEula `
#              --runAsService `
#              --work $pipelineWorkDirectory

Pop-Location