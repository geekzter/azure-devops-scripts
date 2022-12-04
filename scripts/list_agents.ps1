#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
 
.DESCRIPTION 
    
.EXAMPLE
#> 
<# TODO
    Exclude v3 agents
    Exclude Hosted pools
    Include (color coded?) guidance column (upgrade os, try v3 agent)
    Include pool url in output 
    Include agent url in output 

    Use whitelist file: https://raw.githubusercontent.com/microsoft/azure-pipelines-agent/master/src/Agent.Listener/net6.json
    Test pools?
    Use Kusto to get useragent test data
    Include semantic version (e.g. 'RHEL 6') column
#>

#Requires -Version 7.2

param ( 
    [parameter(Mandatory=$false,ParameterSetName="pool")]
    [string]
    $OrganizationUrl=$env:AZDO_ORG_SERVICE_URL,
    
    [parameter(Mandatory=$false,ParameterSetName="pool")]
    [int[]]
    $PoolId,
    
    [parameter(Mandatory=$false,ParameterSetName="pool")]
    [string]
    $Token=($env:AZURE_DEVOPS_EXT_PAT ?? $env:AZDO_PERSONAL_ACCESS_TOKEN),
    
    [parameter(Mandatory=$false,ParameterSetName="os")]
    [string[]]
    $OS,

    [parameter(Mandatory=$false)]
    [ValidateSet("V3Compatible", "V3CompatibilityIssues", "V3CompatibilityUnknown", "V3InCompatible", "All")]
    [string]
    $Filter="V3CompatibilityIssues"
) 

function Classify-OS (
    [parameter(Mandatory=$true)][string]$AgentOS,
    [parameter(Mandatory=$true)][psobject]$Agent
) {
    $v3AgentSupportsOS = Validate-OS -OSDescription $AgentOS
    $Agent | Add-Member -NotePropertyName V3AgentSupportsOS -NotePropertyValue $v3AgentSupportsOS
    if ($v3AgentSupportsOS -eq $null) {
        $osComment = "$($PSStyle.Formatting.Warning)Could not determine OS (version), v2 agent won't automatically upgrade to v3$($PSStyle.Reset)"
    } elseif ($v3AgentSupportsOS) {
        $osComment = "OS supported by v3 agent, v2 agent will automatically upgrade to v3"
    } else {
        $osComment = "$($PSStyle.Formatting.Error)OS not supported by v3 agent, v2 agent won't upgrade to v3$($PSStyle.Reset)"
    }
    $Agent | Add-Member -NotePropertyName OSComment -NotePropertyValue $osComment
}

function Filter-Agents (
    [parameter(Mandatory=$true,ValueFromPipeline=$true)][psobject[]]$Agents
) {
    begin {}
    process {
        switch ($Filter) {
            "V3Compatible" {
                $Agents | Where-Object -Property V3AgentSupportsOS -eq $true
            } 
            "V3CompatibilityIssues" {
                $Agents | Where-Object -Property V3AgentSupportsOS -ne $true
            } 
            "V3CompatibilityUnknown" {
                $Agents | Where-Object -Property V3AgentSupportsOS -eq $null
            } 
            "V3InCompatible" {
                $Agents | Where-Object -Property V3AgentSupportsOS -eq $false
            } 
            "All" {
                $Agents
            }
        }    
    }
    end {}
}

function Validate-OS (
    [parameter(Mandatory=$true)][string]$OSDescription
) {
    # Parse operating system header
    switch -regex ($OSDescription) {
        # Debian "Linux 4.9.0-16-amd64 #1 SMP Debian 4.9.272-2 (2021-07-19)"
        "(?im)^Linux.* Debian (?<Major>[\d]+)(\.(?<Minor>[\d]+))(\.(?<Build>[\d]+))?.*$"  {
            Write-Verbose "OS is Debian"
            [version]$kernelVersion = ("{0}.{1}" -f $Matches["Major"],$Matches["Minor"])
            Write-Verbose "Debian Linux Kernel $($kernelVersion.ToString())"
            [version]$minKernelVersion = '5.0' 

            return ($kernelVersion -ge $minKernelVersion)
        }
        # Fedora "Linux 5.11.22-100.fc32.x86_64 #1 SMP Wed May 19 18:58:25 UTC 2021"
        "(?im)^Linux.*\.fc(?<Major>[\d]+)\..*$"  {
            Write-Verbose "OS is Fedora"
            [int]$fedoraVersion = $Matches["Major"]
            Write-Verbose "Fedora ${fedoraVersion}"

            return ($fedoraVersion -ge 33)
        }
        # Red Hat / CentOS "Linux 4.18.0-425.3.1.el8.x86_64 #1 SMP Fri Sep 30 11:45:06 EDT 2022"
        "(?im)^Linux.*\.el(?<Major>[\d]+).*$"  {
            Write-Verbose "OS is Red Hat"
            $majorVersion = $Matches["Major"]
            Write-Verbose "Red Hat ${majorVersion}"

            return ($majorVersion -ge 7)
        }
        # Ubuntu "Linux 4.15.0-1113-azure #126~16.04.1-Ubuntu SMP Tue Apr 13 16:55:24 UTC 2021"
        "(?im)^Linux.*[^\d]+((?<Major>[\d]+)((\.(?<Minor>[\d]+))(\.(?<Build>[\d]+)))(\.(?<Revision>[\d]+))?)-Ubuntu.*$"  {
            Write-Verbose "OS is Ubuntu"
            [int]$majorVersion = $Matches["Major"]
            Write-Verbose "Ubuntu ${majorVersion}"

            if ($majorVersion -lt 16) {
                return $false
            }
            if (($majorVersion % 2) -ne 0) {
                return $null
            }
            return $true
        }
        # Ubuntu "Linux 3.19.0-26-generic #28-Ubuntu SMP Tue Aug 11 14:16:32 UTC 2015"
        # Ubuntu 22 "Linux 5.15.0-1023-azure #29-Ubuntu SMP Wed Oct 19 22:37:08 UTC 2022 x86_64 x86_64 x86_64 GNU/Linux"
        "(?im)^Linux (?<KernelMajor>[\d]+)(\.(?<KernelMinor>[\d]+)).*-Ubuntu.*$" {
            Write-Verbose "OS is Ubuntu, no version declared"
            [version]$kernelVersion = ("{0}.{1}" -f $Matches["KernelMajor"],$Matches["KernelMinor"])
            Write-Verbose "Ubuntu Linux Kernel $($kernelVersion.ToString())"
            [version]$minKernelVersion = '4.4' 

            if ($kernelVersion -lt $minKernelVersion ) {
                return $false
            }
            return $null
        }
        # macOS "Darwin 17.6.0 Darwin Kernel Version 17.6.0: Tue May  8 15:22:16 PDT 2018; root:xnu-4570.61.1~1/RELEASE_X86_64"
        "(?im)^Darwin (?<DarwinMajor>[\d]+)(\.(?<DarwinMinor>[\d]+)).*$" {
            Write-Verbose "OS is Darwin"
            [version]$darwinVersion = ("{0}.{1}" -f $Matches["DarwinMajor"],$Matches["DarwinMinor"])
            Write-Verbose "Darwin $($darwinVersion.ToString())"
            [version]$minDarwinVersion = '19.0' 

            return ($darwinVersion -ge $minDarwinVersion)
        }
        # Windows 10 / Server 2016+ "Microsoft Windows 10.0.20348"
        "(?im)^Microsoft Windows (?<Major>[\d]+)(\.(?<Minor>[\d]+))(\.(?<Build>[\d]+)).*$"  {
            [int]$windowsMajorVersion = $Matches["Major"]
            [int]$windowsMinorVersion = $Matches["Minor"]
            [int]$windowsBuild = $Matches["Build"]
            [version]$windowsVersion = ("{0}.{1}.{2}" -f $Matches["Major"],$Matches["Minor"],$Matches["Build"])
            Write-Verbose "OS is Windows"
            Write-Verbose "Windows $($windowsVersion.ToString())"
            if (($windowsMajorVersion -eq 6) -and ($windowsMinorVersion -eq 1)) {
                # Windows 7
                return ($windowsBuild -ge 7601)
            }
            if (($windowsMajorVersion -eq 6) -and ($windowsMinorVersion -eq 2)) {
                # Windows 8 / Windows Server 2012 R1
                return $false
            }
            if (($windowsMajorVersion -eq 6) -and ($windowsMinorVersion -eq 3)) {
                # Windows 8.1 / Windows Server 2012 R2
                return $true
            }
            if ($windowsMajorVersion -eq 10) {
                # Windows 10 / Windows Server 2016+
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

if ($OS) {
    # Process OS headers passed as input
    $OS | ForEach-Object {
        New-Object PSObject -Property @{
            OS = $_
        } | Set-Variable agent
        Classify-OS -AgentOS $_ -Agent $agent
        Write-Output $agent
    } | Set-Variable agents

    $agents | Filter-Agents | Format-Table -Property OS, OSComment

    exit
}

# Gather data from Azure DevOps, proceed to validate arguments required
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
    $poolUrl = ("{0}/_settings/agentpools?poolId={1}" -f $OrganizationUrl,$individualPoolId)
    Write-Verbose "Retrieving pool with id '${individualPoolId}' in (${OrganizationUrl})..."
    az pipelines pool show --id $individualPoolId `
                           --query "name" `
                           -o tsv `
                           | Set-Variable poolName
    
    Write-Host "Retrieving agents for pool '${poolName}' (${poolUrl})..."
    az pipelines agent list --pool-id $individualPoolId `
                            --include-capabilities `
                            --query "[?!starts_with(version,'3.')]" `
                            -o json `
                            | ConvertFrom-Json `
                            | Set-Variable agents
    $agents | ForEach-Object {
        Classify-OS -AgentOS $_.osDescription -Agent $_
        $agentUrl = "{0}/_settings/agentpools?agentId={2}&poolId={1}" -f $OrganizationUrl,$individualPoolId,$_.id
        $_ | Add-Member -NotePropertyName AgentUrl -NotePropertyValue $agentUrl
    } 
    if (!$All) {
        $agents | Where-Object -Property V3AgentSupportsOS -ne $true | Set-Variable agents
    }
    $agents | Filter-Agents | Format-Table -Property name, osDescription, OSComment, AgentUrl

    exit
}
