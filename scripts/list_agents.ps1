#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Predict whether agents will be able to upgrade frpm pipeline agent v2 to agent v3

.DESCRIPTION 
    Azure Pipeline agent v2 uses .NET 3.1 Core, while agent v3 runs on .NET 6. This means agent v3 will drop support for operating systems not supported by .NET 6 (https://github.com/dotnet/core/blob/main/release-notes/6.0/supported-os.md)
    This script will try to predict whether an agent will be able to upgrade, using the osDescription attribute of the agent. For Linux and macOS, this contains the output of 'uname -a`.
    Note the Pipeline agent has more context about the operating system of the host it is running un (e.g. 'lsb_release -a' output), and is able to make a better informed decision on whether to upgrade or not.
    Hence the output of this script is an indication wrt what the agent will do, but will include results where there is no sufficient information to include a prediction.

    This script requires a PAT token with read access on 'Agent Pools' scope.

    For more information, go to https://aka.ms/azdo-pipeline-agent-version.
.EXAMPLE
    ./list_agents.ps1 -PoolId 1234

.EXAMPLE
    ./list_agents.ps1 -PoolId 1234 -Filter V3InCompatible -Verbose
#> 

#Requires -Version 7.2

[CmdletBinding(DefaultParameterSetName="pool")]
param ( 
    [parameter(Mandatory=$false,ParameterSetName="pool")]
    [string]
    $OrganizationUrl=$env:AZDO_ORG_SERVICE_URL,
    
    [parameter(Mandatory=$false,ParameterSetName="pool")]
    [int[]]
    $PoolId,
    
    [parameter(Mandatory=$false,HelpMessage="PAT token with read access on 'Agent Pools' scope",ParameterSetName="pool")]
    [string]
    $Token=($env:AZURE_DEVOPS_EXT_PAT ?? $env:AZDO_PERSONAL_ACCESS_TOKEN),
    
    [parameter(Mandatory=$false,ParameterSetName="os")]
    [string[]]
    $OS,

    [parameter(Mandatory=$false)]
    [parameter(ParameterSetName="pool")]
    [parameter(ParameterSetName="os")]
    [ValidateSet("V3Compatible", "V3CompatibilityIssues", "V3CompatibilityUnknown", "V3InCompatible", "All")]
    [string]
    $Filter="V3CompatibilityIssues"
) 

function Classify-OS (
    [parameter(Mandatory=$false)][string]$AgentOS,
    [parameter(Mandatory=$true)][psobject]$Agent
) {
    Write-Debug "AgentOS: ${AgentOS}"
    if ($AgentOS) {
        $v3AgentSupportsOS = Validate-OS -OSDescription $AgentOS
        if ($v3AgentSupportsOS -eq $null) {
            $osComment = "$($PSStyle.Formatting.Warning)OS (version) unknown, v2 agent won't upgrade to v3 automatically$($PSStyle.Reset)"
        } elseif ($v3AgentSupportsOS) {
            $osComment = "OS supported by v3 agent, v2 agent will automatically upgrade to v3"
        } else {
            $osComment = "$($PSStyle.Formatting.Error)OS not supported by v3 agent, v2 agent won't upgrade to v3$($PSStyle.Reset)"
        }
    } else {
        $osComment = "$($PSStyle.Formatting.Warning)OS description missing$($PSStyle.Reset)"
    }
    $Agent | Add-Member -NotePropertyName V3AgentSupportsOS -NotePropertyValue $v3AgentSupportsOS
    $Agent | Add-Member -NotePropertyName OSComment -NotePropertyValue $osComment
}

function Filter-Agents (
    [parameter(Mandatory=$true,ValueFromPipeline=$true)][psobject[]]$Agents
) {
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
            default {
                $Agents
            }
        }    
    }
}

function Validate-OS (
    [parameter(Mandatory=$true)][string]$OSDescription
) {
    # Parse operating system header
    switch -regex ($OSDescription) {
        # Debian "Linux 4.9.0-16-amd64 #1 SMP Debian 4.9.272-2 (2021-07-19)"
        "(?im)^Linux.* Debian (?<Major>[\d]+)(\.(?<Minor>[\d]+))(\.(?<Build>[\d]+))?.*$"  {
            Write-Debug "Debian: '$OSDescription'"
            [version]$kernelVersion = ("{0}.{1}" -f $Matches["Major"],$Matches["Minor"])
            Write-Debug "Debian Linux Kernel $($kernelVersion.ToString())"
            [version]$minKernelVersion = '4.19' # https://wiki.debian.org/DebianBuster 

            if ($kernelVersion -ge $minKernelVersion) {
                Write-Debug "Supported Debian Linux kernel version: ${kernelVersion}"
                return $true
            } else {
                Write-Verbose "Unsupported Debian Linux kernel version: ${kernelVersion} (see https://wiki.debian.org/DebianReleases)"
                return $false
            }
        }
        # Fedora "Linux 5.11.22-100.fc32.x86_64 #1 SMP Wed May 19 18:58:25 UTC 2021"
        "(?im)^Linux.*\.fc(?<Major>[\d]+)\..*$"  {
            Write-Debug "Fedora: '$OSDescription'"
            [int]$fedoraVersion = $Matches["Major"]
            Write-Debug "Fedora ${fedoraVersion}"

            if ($fedoraVersion -ge 33) {
                Write-Debug "Supported Fedora version: ${fedoraVersion}"
                return $true
            } else {
                Write-Verbose "Unsupported Fedora version: ${fedoraVersion}"
                return $false
            }
        }
        # Red Hat / CentOS "Linux 4.18.0-425.3.1.el8.x86_64 #1 SMP Fri Sep 30 11:45:06 EDT 2022"
        "(?im)^Linux.*\.el(?<Major>[\d]+).*$"  {
            Write-Debug "Red Hat / CentOS / Oracle Linux: '$OSDescription'"
            [int]$majorVersion = $Matches["Major"]
            Write-Debug "Red Hat ${majorVersion}"

            if ($majorVersion -ge 7) {
                Write-Debug "Supported RHEL / CentOS / Oracle Linux version: ${majorVersion}"
                return $true
            } else {
                Write-Verbose "Unsupported RHEL / CentOS / Oracle Linux version: ${majorVersion}"
                return $false
            }
        }
        # Ubuntu "Linux 4.15.0-1113-azure #126~16.04.1-Ubuntu SMP Tue Apr 13 16:55:24 UTC 2021"
        "(?im)^Linux.*[^\d]+((?<Major>[\d]+)((\.(?<Minor>[\d]+))(\.(?<Build>[\d]+)))(\.(?<Revision>[\d]+))?)-Ubuntu.*$"  {
            Write-Debug "Ubuntu: '$OSDescription'"
            [int]$majorVersion = $Matches["Major"]
            Write-Debug "Ubuntu ${majorVersion}"

            if ($majorVersion -lt 16) {
                Write-Verbose "Unsupported Ubuntu version: ${majorVersion}"
                return $false
            }
            if (($majorVersion % 2) -ne 0) {
                Write-Verbose "non-LTS Ubuntu version: ${majorVersion}"
                return $null
            }
            Write-Debug "Supported Ubuntu version: ${majorVersion}"
            return $true
        }
        # Ubuntu "Linux 3.19.0-26-generic #28-Ubuntu SMP Tue Aug 11 14:16:32 UTC 2015"
        # Ubuntu 22 "Linux 5.15.0-1023-azure #29-Ubuntu SMP Wed Oct 19 22:37:08 UTC 2022 x86_64 x86_64 x86_64 GNU/Linux"
        "(?im)^Linux (?<KernelMajor>[\d]+)(\.(?<KernelMinor>[\d]+)).*-Ubuntu.*$" {
            Write-Debug "Ubuntu (no version declared): '$OSDescription'"
            [version]$kernelVersion = ("{0}.{1}" -f $Matches["KernelMajor"],$Matches["KernelMinor"])
            Write-Debug "Ubuntu Linux Kernel $($kernelVersion.ToString())"
            [version]$minKernelVersion = '4.4' # https://ubuntu.com/kernel/lifecycle

            if ($kernelVersion -lt $minKernelVersion ) {
                Write-Verbose "Unsupported Ubuntu Linux kernel version: ${kernelVersion} (see https://ubuntu.com/kernel/lifecycle)"
                return $false
            }
            Write-Verbose "Unknown Ubuntu version: '$OSDescription'"
            return $null
        }
        # macOS "Darwin 17.6.0 Darwin Kernel Version 17.6.0: Tue May  8 15:22:16 PDT 2018; root:xnu-4570.61.1~1/RELEASE_X86_64"
        "(?im)^Darwin (?<DarwinMajor>[\d]+)(\.(?<DarwinMinor>[\d]+)).*$" {
            Write-Debug "macOS (Darwin): '$OSDescription'"
            [version]$darwinVersion = ("{0}.{1}" -f $Matches["DarwinMajor"],$Matches["DarwinMinor"])
            Write-Debug "Darwin $($darwinVersion.ToString())"
            [version]$minDarwinVersion = '19.0' 

            if ($darwinVersion -ge $minDarwinVersion) {
                Write-Debug "Supported Darwin (macOS) version: ${darwinVersion}"
                return $true
            } else {
                Write-Verbose "Unsupported Darwin (macOS) version): ${darwinVersion} (see https://en.wikipedia.org/wiki/Darwin_(operating_system)"
                return $false
            }
        }
        # Windows 10 / Server 2016+ "Microsoft Windows 10.0.20348"
        "(?im)^(Microsoft Windows|Windows_NT) (?<Major>[\d]+)(\.(?<Minor>[\d]+))(\.(?<Build>[\d]+)).*$"  {
            [int]$windowsMajorVersion = $Matches["Major"]
            [int]$windowsMinorVersion = $Matches["Minor"]
            [int]$windowsBuild = $Matches["Build"]
            [version]$windowsVersion = ("{0}.{1}.{2}" -f $Matches["Major"],$Matches["Minor"],$Matches["Build"])
            Write-Debug "Windows: '$OSDescription'"
            Write-Debug "Windows $($windowsVersion.ToString())"
            if (($windowsMajorVersion -eq 6) -and ($windowsMinorVersion -eq 1)) {
                # Windows 7
                if ($windowsBuild -ge 7601) {
                    Write-Debug "Supported Windows 7 build: ${windowsVersion}"
                    return $true
                } else {
                    Write-Verbose "Unsupported Windows 7 build: ${windowsVersion}"
                    return $false
                }
            }
            if (($windowsMajorVersion -eq 6) -and ($windowsMinorVersion -eq 2)) {
                # Windows 8 / Windows Server 2012 R1
                Write-Verbose "Windows 8 is not supported: ${windowsVersion}"
                return $false
            }
            if (($windowsMajorVersion -eq 6) -and ($windowsMinorVersion -eq 3)) {
                # Windows 8.1 / Windows Server 2012 R2
                Write-Debug "Supported Windows 8.1 version: ${windowsVersion}"
                return $true
            }
            if ($windowsMajorVersion -eq 10) {
                # Windows 10 / Windows Server 2016+
                if ($windowsBuild -ge 14393) {
                    Write-Debug "Supported Windows 10 / Windows Server 2016+ build: ${windowsVersion}"
                    return $true
                } else {
                    Write-Verbose "Unsupported Windows 10 / Windows Server 2016+ build: ${windowsVersion}"
                    return $false
                }
            }
            Write-Verbose "Unknown Windows version: '${OSDescription}'"
            return $null
        }
        default {
            Write-Verbose "Unknown operating system: '$OSDescription'"
            return $null
        }
    }
}

if (!$OS -and !$OrganizationUrl) {
    Get-Help $MyInvocation.MyCommand.Definition
    return
}

if ($OS) {
    # Process OS parameter set
    $OS | ForEach-Object {
        New-Object PSObject -Property @{
            OS = $_
        } | Set-Variable agent
        Classify-OS -AgentOS $_ -Agent $agent
        Write-Output $agent
    } | Filter-Agents `
      | Format-Table -Property OS, OSComment `
      | Out-Host -Paging

    return
}

# Process pool parameter set
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

Write-Host "$($PSStyle.Formatting.FormatAccent)This script will process all self-hosted pools in organization '${OrganizationUrl}' to:$($PSStyle.Reset)"
Write-Host "$($PSStyle.Formatting.FormatAccent)- Create an aggregated list of agents filtered by '${Filter}' (list repeated at the end of script output) $($PSStyle.Reset)"
Write-Host "$($PSStyle.Formatting.FormatAccent)- Create a CSV export of that list$($PSStyle.Reset)"

Write-Host "Authenticating to organization ${OrganizationUrl}..."
$Token | az devops login --organization $OrganizationUrl
az devops configure --defaults organization=$OrganizationUrl

if (!$PoolId) {
    Write-Host "Retrieving self-hosted pools for organization ${OrganizationUrl}..."
    az pipelines pool list --query "[?!isHosted].id" `
                           -o tsv `
                           | Set-Variable PoolId
}
$PoolId | Measure-Object `
        | Select-Object -ExpandProperty Count `
        | Set-Variable totalNumberOfPools


$script:allAgents = [System.Collections.ArrayList]@()
# $script:allAgents = New-Object System.Collections.Generic.List[System.Management.Automation.PSCustomObject]
try {
    $poolIndex = 0;
    foreach ($individualPoolId in $PoolId) {
        $poolIndex++
        $OuterLoopProgressParameters = @{
            ID               = 0
            Activity         = "Processing pools"
            Status           = "Pool ${poolIndex} of ${totalNumberOfPools}"
            PercentComplete  =  ($poolIndex / $totalNumberOfPools) * 100
            CurrentOperation = 'OuterLoop'
        }
        Write-Progress @OuterLoopProgressParameters
        $agents = $null
        $poolUrl = ("{0}/_settings/agentpools?poolId={1}" -f $OrganizationUrl,$individualPoolId)
        Write-Verbose "Retrieving pool with id '${individualPoolId}' in (${OrganizationUrl})..."
        az pipelines pool show --id $individualPoolId `
                               --query "name" `
                               -o tsv `
                               | Set-Variable poolName
        
        Write-Host "Retrieving v2 agents for pool '${poolName}' (${poolUrl})..."
        az pipelines agent list --pool-id $individualPoolId `
                                --include-capabilities `
                                --query "[?starts_with(version,'2.')]" `
                                -o json `
                                | ConvertFrom-Json `
                                | Set-Variable agents
        if ($agents) {
            $agents | Measure-Object `
                    | Select-Object -ExpandProperty Count `
                    | Set-Variable totalNumberOfAgents
            $agentIndex = 0
            $agents | ForEach-Object {
                $agentIndex++
                $InnerLoopProgressParameters = @{
                    ID               = 1
                    Activity         = "Processing agents"
                    Status           = "Agent ${agentIndex} of ${totalNumberOfAgents} in pool ${poolIndex}"
                    PercentComplete  = ($agentIndex / $totalNumberOfAgents) * 100
                    CurrentOperation = 'InnerLoop'
                }
                Write-Progress @InnerLoopProgressParameters                
                $osConsolidated = $_.osDescription
                $capabilityOSDescription = ("{0} {1}" -f $_.systemCapabilities."Agent.OS",$_.systemCapabilities."Agent.OSVersion")
                if ($capabilityOSDescription -and !$osConsolidated) {
                    $osConsolidated = $capabilityOSDescription
                }
                Write-Debug "osConsolidated: ${osConsolidated}"
                Write-Debug "capabilityOSDescription: ${capabilityOSDescription}"
                Classify-OS -AgentOS $osConsolidated -Agent $_
                $agentUrl = "{0}/_settings/agentpools?agentId={2}&poolId={1}" -f $OrganizationUrl,$individualPoolId,$_.id
                $_ | Add-Member -NotePropertyName AgentUrl -NotePropertyValue $agentUrl
                $_ | Add-Member -NotePropertyName OS -NotePropertyValue $osConsolidated
                $_ | Add-Member -NotePropertyName PoolName -NotePropertyValue $poolName
            } 
            $agents | Filter-Agents `
                    | Format-Table -Property @{Label="Name"; Expression={$_.name}},`
                                             @{Label="Status"; Expression={$_.status}},`
                                             OS,`
                                             OSComment,`
                                             AgentUrl

            $script:allAgents.Add(($agents | Filter-Agents)) | Out-Null
        } else {
            Write-Host "There are no agents in pool '${poolName}' (${poolUrl})"
        }
    }
    Write-Progress Id 0 -Completed
    Write-Progress Id 1 -Completed
} finally {

    $exportFilePath = (Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::newguid().ToString()).csv")
    $script:allAgents | ForEach-Object {
                            # Flatten nested arrays 
                            $_ 
                        } `
                      | Select-Object -Property @{Label="Name"; Expression={$_.name}},`
                        OS,`
                        OSComment,`
                        PoolName,`
                        AgentUrl `
                        | Export-Csv -Path $exportFilePath
    Write-Host "Retrieved agents with filter '${Filter}' in organization (${OrganizationUrl}) have been saved to ${exportFilePath}, and are repeated below"
    $script:allAgents | Format-Table -Property @{Label="Name"; Expression={$_.name}},`
                        @{Label="Status"; Expression={$_.status}},`
                        OS,`
                        OSComment,`
                        PoolName,`
                        AgentUrl `
                      | Out-Host -Paging
                    
    Write-Host "Retrieved agents with filter '${Filter}' in organization (${OrganizationUrl}) have been saved to ${exportFilePath}"                    
}