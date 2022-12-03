#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
 
.DESCRIPTION 
    
.EXAMPLE
#> 
<# TODO
    Exclude v3 agents
    Exclude Hosted pools

    Flatten agent json
    Use whitelist file: https://raw.githubusercontent.com/microsoft/azure-pipelines-agent/master/src/Agent.Listener/net6.json
    Test pools?
    Use Kusto to get useragent test data
    Include semantic version (e.g. 'RHEL 6') column
    Include (color coded?) guidance column (upgrade os, try v3 agent)
    Include, agent url in output 
#>

#Requires -Version 7.2

param ( 
    [parameter(Mandatory=$false)][string]$OrganizationUrl=$env:AZDO_ORG_SERVICE_URL,
    [parameter(Mandatory=$false)][int[]]$PoolId,
    [parameter(Mandatory=$false)][string]$Token=$env:AZURE_DEVOPS_EXT_PAT ?? $env:AZDO_PERSONAL_ACCESS_TOKEN
) 

function Validate-OS (
    [parameter(Mandatory=$true)][string]$OS
) {
    # Parse operating system header
    switch -regex ($OS) {
        # Debian "Linux 4.9.0-16-amd64 #1 SMP Debian 4.9.272-2 (2021-07-19)"
        "(?im)^Linux.* Debian (?<Major>[\d]+)(\.(?<Minor>[\d]+))(\.(?<Build>[\d]+))?.*$"  {
            Write-Verbose "OS is Debian"
            [version]$kernelVersion = ("{0}.{1}" -f $Matches["Major"],$Matches["Minor"])
            Write-Verbose "Debian Linux Kernel $($kernelVersion.ToString())"
            [version]$minKernelVersion = '5.0' 

            return ($kernelVersion -ge $minKernelVersion)
        }
        # Red Hat "Linux 4.18.0-425.3.1.el8.x86_64 #1 SMP Fri Sep 30 11:45:06 EDT 2022"
        "(?im)^Linux.*\.el(?<Major>[\d]+).*$"  {
            Write-Verbose "OS is Red Hat"
            $majorVersion = $Matches["Major"]
            Write-Verbose "Red Hat ${majorVersion}"

            return ($majorVersion -ge 7)
        }
        # Ubuntu "Linux 4.15.0-1113-azure #126~16.04.1-Ubuntu SMP Tue Apr 13 16:55:24 UTC 2021"
        "(?im)^Linux.*[^\d]+((?<Major>[\d]+)(\.(?<Minor>[\d]+))(\.(?<Build>[\d]+))(\.(?<Revision>[\d]+))?)-Ubuntu.*$"  {
            Write-Verbose "OS is Ubuntu"
            $majorVersion = $Matches["Major"]
            Write-Verbose "Ubuntu ${majorVersion}"

            return ($majorVersion -ge 16)
        }
        # Windows 10 / Server 2016+ "Microsoft Windows 10.0.20348"
        "(?im)^Microsoft Windows (?<Major>[\d]+)(\.(?<Minor>[\d]+))(\.(?<Build>[\d]+)).*$"  {
            [int]$windowsMajorVersion = $Matches["Major"]
            [int]$windowsMinorVersion = $Matches["Minor"]
            [int]$windowsBuild = $Matches["Build"]
            [version]$windowsVersion = ("{0}.{1}.{2}" -f $Matches["Major"],$Matches["Minor"],$Matches["Build"])
            Write-Verbose "OS is Windows"
            Write-Verbose "Windows $($windowsVersion.ToString())"
            if ($windowsMajorVersion -le 6) {
                return $false
            }
            if ($windowsMajorVersion -eq 7) {
                return ($windowsBuild -ge 7601)
            }
            if ($windowsMajorVersion -eq 8) {
                return ($windowsMinorVersion -ge 1)
            }
            if ($windowsMajorVersion -eq 10) {
                return ($windowsBuild -ge 14393)
            }
            return $null
        }
        default {
            Write-Verbose "'$OS' is not a recognized OS format, skipping"
            return $null
        }
    }
}

$apiVersion = "7.1-preview"

# Validation & Parameter processing
if (!$OrganizationUrl) {
    Write-Warning "OrganizationUrl is required. Please specify -OrganizationUrl or set the AZDO_ORG_SERVICE_URL environment variable."
    exit 1
}
$OrganizationUrl = $OrganizationUrl -replace "/$","" # Strip trailing '/'
if (!$Token) {
    Write-Warning "No access token found. Please specify -Token or set the AZURE_DEVOPS_EXT_PAT or AZDO_PERSONAL_ACCESS_TOKEN environment variable."
    exit 1
}
if (!(Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Warning "Azure CLI not found. Please install it."
    exit 1
}
if (!(az extension list --query "[?name=='azure-devops'].version" -o tsv)) {
    Write-Host "Adding Azure CLI extension 'azure-devops'..."
    az extension add -n azure-devops -y
}

Write-Host "Authenticating to organization ${OrganizationUrl}..."
$Token | az devops login --organization $OrganizationUrl
az devops configure --defaults organization=$OrganizationUrl

if (!$PoolId) {
    Write-Host "Retrieving self-hosted pools for organization ${OrganizationUrl}..."
    az pipelines pool list --query "[?!isHosted].id" `
                           -o tsv `
                           | Set-Variable PoolId
}

foreach ($individualPoolId in $PoolId) {
    Write-Verbose "Retrieving pool with id '${individualPoolId}' in ${OrganizationUrl}..."
    az pipelines pool show --id $individualPoolId `
                           --query "name" `
                           -o tsv `
                           | Set-Variable poolName
    
    Write-Host "Retrieving agents for pool '${poolName}' in ${OrganizationUrl}..."
    # az pipelines agent list --pool-id $individualPoolId `
    #                         --include-capabilities `
    #                         --query "[?!starts_with(version,'3.')]" `
    #                         -o json 

    # exit
    az pipelines agent list --pool-id $individualPoolId `
                            --include-capabilities `
                            --query "[?!starts_with(version,'3.')]" `
                            -o json `
                            | ConvertFrom-Json `
                            | Set-Variable agents
    $agents | ForEach-Object {
        $v3AgentSupportsOS = Validate-OS -OS $_.osDescription
        $_ | Add-Member -NotePropertyName V3AgentSupportsOS -NotePropertyValue $v3AgentSupportsOS
        if ($v3AgentSupportsOS -eq $null) {
            $osComment = "$($PSStyle.Formatting.Warning)Could not detect OS$($PSStyle.Reset)"
        } elseif ($v3AgentSupportsOS) {
            $osComment = "OS supported by v3 agent"
        } else {
            $osComment = "$($PSStyle.Formatting.Error)OS not supported by v3 agent$($PSStyle.Reset)"
        }
        $_ | Add-Member -NotePropertyName OSComment -NotePropertyValue $osComment
    } 
    $agents | Format-Table -Property name, osDescription, V3AgentSupportsOS, OSComment

    exit
}
