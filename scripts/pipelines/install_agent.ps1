#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Installs and configures Azure Pipeline Agent
.DESCRIPTION 
    Installs and configures Azure Pipeline Agent. 
    All arguments are optional, as this script tries to infer as much as possible from the environment.
#> 
[CmdLetBinding(DefaultParameterSetName='Pool')]
param ( 
    [parameter(Mandatory=$false,ParameterSetName='Pool')]
    [parameter(Mandatory=$false,ParameterSetName='DeploymentGroup')]
    [ValidateNotNullOrEmpty()]
    [string]
    $AgentName=[environment]::MachineName,
    
    [parameter(Mandatory=$false,ParameterSetName='Pool')]
    [ValidateNotNullOrEmpty()]
    [string]
    $AgentPool='Default',
    
    [parameter(Mandatory=$true,ParameterSetName='DeploymentGroup')]
    [ValidateNotNullOrEmpty()]
    [string]
    $DeploymentGroup,
    
    [parameter(Mandatory=$true,ParameterSetName='Environment')]
    [ValidateNotNullOrEmpty()]
    [string]
    $Environment,
    
    [parameter(Mandatory=$true,ParameterSetName='DeploymentGroup')]
    [parameter(Mandatory=$true,ParameterSetName='Environment')]
    [ValidateNotNullOrEmpty()]
    [string]
    $Project,
    
    [parameter(Mandatory=$false)]
    [ValidateSet(2, 3, 4)]
    [int]
    $MajorVersion=4,

    [parameter(Mandatory=$false)][switch]
    $ExcludeEoLNode,

    [parameter(Mandatory=$false,HelpMessage="Azure DevOps token, if not provided will be inferred from environment")]
    [string]
    $Token,

    [parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]
    $OrganizationUrl=$env:AZDO_ORG_SERVICE_URL,

    [parameter(Mandatory=$false)]
    [switch]
    $UseAzureCliSession,

    [parameter(Mandatory=$false,ParameterSetName='Remove')]
    [switch]
    $Remove,

    [parameter(Mandatory=$false)][string]
    [ValidateSet("Previous", "Current", "Prerelease")]
    $VersionPreference="Current"
) 
Write-Verbose $MyInvocation.line 
. (Join-Path $PSScriptRoot .. functions.ps1)

if ($IsWindows) {
    Join-Path $env:ProgramFiles pipeline-agent | Set-Variable pipelineDirectory
    $pipelineWorkDirectory = "${env:ProgramData}\pipeline-agent\work"
    $script = "config.cmd"
}
if ($IsLinux) {
    $pipelineDirectory = "/opt/pipeline-agent"
    $pipelineWorkDirectory = "/var/opt/pipeline-agent/work"
    $script = "config.sh"
}
if ($IsMacOS) {
    Join-Path $env:HOME pipeline-agent | Set-Variable pipelineDirectory
    Join-Path $env:HOME pipeline-agent/work | Set-Variable pipelineWorkDirectory
    $script = "config.sh"
}
Write-Debug "Pipeline agent directory: '${pipelineDirectory}'"
Write-Debug "Pipeline agent work directory: '${pipelineWorkDirectory}'"
Write-Debug "Pipeline agent script: '${script}'"

if ($Remove) {
    if (!(Test-Path $pipelineDirectory)) {
        Write-Warning "Pipeline agent not found in expected location '${pipelineDirectory}', exiting"
        exit 1
    }
    try {
        Push-Location $pipelineDirectory 
        if (!(Test-Path $script)) {
            Write-Warning "Script '${script}' not found in expected location '${pipelineDirectory}', exiting"
            exit 1
        }


        Write-Verbose "Removing agent..."
        if ($UseAzureCliSession) {
            Get-AccessToken -Token $Token | Set-Variable aadToken
            Invoke-AgentConfig -Command "$(Join-Path . $script) remove --auth PAT --token ${aadToken}"
        } else {
            Invoke-AgentConfig -Command "$(Join-Path . $script) remove"
        }
        Remove-Directory $pipelineWorkDirectory
        Remove-Directory $pipelineDirectory
    } finally {
        Pop-Location
    }
} else {
    if (!$IsLinux) {
        Write-Verbose "Creating pipeline agent directory '${pipelineDirectory}'"
        New-Item -ItemType directory -Path $pipelineDirectory -Force -ErrorAction SilentlyContinue | Out-Null
        if (Test-Path (Join-Path $pipelineDirectory .agent)) {
            Write-Host "Agent $AgentName already installed"
            exit 1
        }
        Write-Verbose "Creating pipeline agent work directory '${pipelineWorkDirectory}'"
        New-Item -ItemType Directory -Path $pipelineWorkDirectory -Force -ErrorAction SilentlyContinue | Out-Null
        Join-Path $pipelineDirectory _work | Set-Variable pipelineWorkDirectoryLink
        if (!(Test-Path $pipelineWorkDirectoryLink)) {
            Write-Debug "Creating symbolic link from '${pipelineWorkDirectoryLink}' to '${pipelineWorkDirectory}'"
            New-Item -ItemType symboliclink -Path "${pipelineWorkDirectoryLink}" -Value "$pipelineWorkDirectory" -Force -ErrorAction SilentlyContinue | Out-Null
        }    
    } else {
        sudo mkdir -p $pipelineDirectory 2>/dev/null
        sudo mkdir -p $pipelineWorkDirectory 2>/dev/null
        sudo ln -s $pipelineWorkDirectory $AGENT_DIRECTORY/_work 2>/dev/null
        $owner = "$(id -u):$(id -g)"
        sudo chown -R $owner $pipelineDirectory
        sudo chown -R $owner $pipelineWorkDirectory
    }
    
    try {
        $presetToken = $env:AZURE_DEVOPS_EXT_PAT
        Push-Location $pipelineDirectory 
    
        Get-AgentPackageUrl -MajorVersion $MajorVersion -VersionPreference $VersionPreference | Set-Variable agentPackageUrl
        Write-Debug "Agent package URL: '${agentPackageUrl}'"
        $agentPackageUrl -Split '/' | Select-Object -Last 1 | Set-Variable agentPackage
        Write-Debug "Agent package: '${agentPackage}'"
        
        Write-Host "Retrieving agent to '${pipelineDirectory}' from '${agentPackageUrl}'..."
        Invoke-Webrequest -Uri $agentPackageUrl -OutFile $agentPackage -UseBasicParsing
        
        Write-Host "Extracting '${agentPackage}' in '${pipelineDirectory}'..."
        if ($IsWindows) {
            Expand-Archive -Path $agentPackage -DestinationPath $pipelineDirectory
        } else {
            tar zxf $agentPackage -C $pipelineDirectory
        }
        Write-Host "Extracted '${agentPackage}' in '${pipelineDirectory}'"
                
        # Configure agent
        Write-Host "Creating agent '${AgentName}' and adding it to pool '${AgentPool}' in organization '${OrganizationUrl}'..."
        if ($UseAzureCliSession) {
            Get-AccessToken -Token $Token | Set-Variable aadToken
            if (!$OrganizationUrl) {
                $env:AZURE_DEVOPS_EXT_PAT = $aadToken
                Write-Host "Organization URL not set using -OrganizationUrl parameter or AZDO_ORG_SERVICE_URL environment variable, trying to infer..."
                if (!(az extension list --query "[?name=='azure-devops'].version" -o tsv)) {
                    Write-Host "Adding Azure CLI extension 'azure-devops'..."
                    az extension add -n azure-devops -y
                }
                Write-Debug "az devops configure --list"
                az devops configure -l | Select-String -Pattern '^organization = (?<org>.+)$' | Set-Variable result
                if ($result) {
                    $OrganizationUrl = $result.Matches.Groups[1].Value
                }
                if ($OrganizationUrl) {
                    Write-Host "Using organization URL set with 'az devops configure' : '${OrganizationUrl}'"
                } else {
                    Write-Debug "az account show --query 'user.name' -o tsv"
                    (az account show --query "user.name" -o tsv) -split '@' | Select-Object -First 1 | Set-Variable alias
                    if ($alias) {
                        $OrganizationUrl = "https://dev.azure.com/${alias}"
                        Write-Host "Using user alias as organization name : '${OrganizationUrl}'"
                    } else {
                        Write-Warning "Unable to determine Organization URL. Use the OrganizationUrl parameter or AZDO_ORG_SERVICE_URL environment variable to set it."
                        exit 1
                    }
                }
            }
            if ($AgentPool) {
                $poolArgs = "--pool ${AgentPool}"
            }
            if ($DeploymentGroup) {
                $poolArgs = "--deploymentgroup --deploymentgroupname '${DeploymentGroup}' --projectname '${Project}'"
            }
            if ($Environment) {
                $poolArgs = "--environment --environmentname '${Environment}' --projectname '${Project}'"
            }
            if (!$OrganizationUrl) {
                Write-Error "OrganizationUrl not specified, exiting"
                exit 1
            }
            Invoke-AgentConfig -Command "$(Join-Path . $script) --url $OrganizationUrl `
                                                                --auth pat --token $aadToken `
                                                                $($poolArgs) `
                                                                --agent $AgentName --replace `
                                                                --acceptTeeEula `
                                                                --work $pipelineWorkDirectory"
        } else {
            Invoke-AgentConfig -Command "$(Join-Path . $script) --url $OrganizationUrl `
                                                                $($poolArgs) `
                                                                --agent $AgentName --replace `
                                                                --acceptTeeEula `
                                                                --work $pipelineWorkDirectory"
        }
    } finally {
        $env:AZURE_DEVOPS_EXT_PAT = $presetToken
        Pop-Location
    }
}