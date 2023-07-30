function Get-AADAccessToken () {
    # Log in with Azure CLI (if not logged in yet)
    Login-Az -DisplayMessages
    Write-Debug "az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798"
    az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 `
                                --query "accessToken" `
                                --output tsv `
                                | Set-Variable aadToken
    if (!$aadToken) {
        Write-Warning "Could not obtain AAD token"
        return $null
    }
    Write-Debug "AAD Token: $($aadToken -replace '.','*')"

    return $aadToken
}

function Get-AccessToken (
    [parameter(Mandatory=$false)]
    [string]
    $Token
) {
    if ($Token) {
        Write-Verbose "Using Token parameter"
    } elseif ($env:AZURE_DEVOPS_EXT_PAT) {
        Write-Verbose "Using AZURE_DEVOPS_EXT_PAT environment variable"
        $Token = $env:AZURE_DEVOPS_EXT_PAT
    } elseif ($env:AZDO_PERSONAL_ACCESS_TOKEN) {
        Write-Verbose "Using AZDO_PERSONAL_ACCESS_TOKEN environment variable"
        $Token = $env:AZDO_PERSONAL_ACCESS_TOKEN
    } elseif (Get-Command az -ErrorAction SilentlyContinue) {
        Write-Verbose "Using Azure CLI"
        $Token = (Get-AADAccessToken)
    } elseif ($env:SYSTEM_ACCESSTOKEN) {
        Write-Verbose "Using SYSTEM_ACCESSTOKEN environment variable"
        $Token = $env:SYSTEM_ACCESSTOKEN
    }
    if ($Token) {
        Write-Verbose "Access token: $($token -replace '.','*')"
        Write-Debug "Access token: ${token}"
        return $Token
    } else {
        Write-Warning "No access token found, exiting"
        exit 1
    }
}

function Get-AgentPackageUrl (
    [parameter(Mandatory=$false)][switch]
    $ExcludeNode6,

    [parameter(Mandatory=$false)][string]
    [ValidateSet("Previous", "Current", "Prerelease")]
    $VersionPreference="Current",

    [parameter(Mandatory=$false)]
    [ValidateSet(2, 3)]
    [int]
    $MajorVersion=2
) {
    (Invoke-RestMethod -Uri https://api.github.com/repos/microsoft/azure-pipelines-agent/releases) `
                       | Where-Object {!$_.draft} `
                       | Where-Object {$_.name -match "^v${MajorVersion}"} `
                       | Sort-Object -Property @{Expression = "created_at"; Descending = $true} `
                       | Set-Variable releases
    switch ($VersionPreference) {
        "Previous" {
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
        Write-Warning "Agent VersionPreference '${VersionPreference}' release v${MajorVersion} not found, exiting"
        exit
    }
    $release | Format-List | Out-String | Write-Debug
    $release.name -replace "^v","" | Set-Variable agentVersion

    if ($IsWindows) {
        $os = "Windows"
        $osString = [Environment]::Is64BitProcess ? "win-x64" : "win-x86"
        $extension = "zip"
    }
    if ($IsMacOS) {
        $os = "macOS"
        $osString = (($PSVersionTable.OS -imatch "ARM64") -and $MajorVersion -ge 3) ? "osx-arm64" : "osx-x64"
        $extension = "tar.gz"
    }
    if ($IsLinux) {
        $os = "Linux"
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
        "Agent package for '{0}' ({1},{2}):`n{3}" -f $PSVersionTable.OS, `
                                                     $VersionPreference, `
                                                     ($ExcludeNode6 ? "ExcludeNode6" : "IncludeNode6"), `
                                                     $packageUrl `
                                                   | Write-Verbose
        return $packageUrl
    } catch {
        throw "Could not access agent package for ${os} ($($VersionPreference.ToLower())): ${packageUrl}`n$($_.Exception.Message)"
    }
}

function Login-Az (
    [parameter(Mandatory=$false)]
    [guid]
    $TenantId#=($env:ARM_TENANT_ID ?? $env:AZURE_TENANT_ID)
) {
    if (!(Get-Command az)) {
        Write-Error "Azure CLI is not installed, get it at http://aka.ms/azure-cli"
        exit 1
    }

    # Are we logged in? If so, is it the right tenant?
    $azureAccount = $null
    az account show 2>$null | ConvertFrom-Json | Set-Variable azureAccount
    if ($azureAccount -and `
        ($TenantId -and ($TenantId -ne [guid]::Empty)) -and `
        ($azureAccount.tenantId -ine $TenantId)) {
        Write-Warning "Logged into tenant $($azureAccount.tenant_id) instead of ${TenantId}"
        $azureAccount = $null
    }
    if (-not $azureAccount) {
        if ($env:CODESPACES -ieq "true") {
            $azLoginSwitches = "--use-device-code "
        }
        if ($TenantId -and ($TenantId -ne [guid]::Empty)) {
            Write-Debug "az login -t ${TenantId} --allow-no-subscriptions $($azLoginSwitches)"
            az login -t $TenantId -o none --allow-no-subscriptions $($azLoginSwitches)
        } else {
            Write-Debug "az login $($azLoginSwitches)"
            az login $($azLoginSwitches) -o none
            az account show 2>$null | ConvertFrom-Json | Set-Variable azureAccount
        }
    }
}

function Remove-Directory (
    [parameter(Mandatory=$true)][string]$Path,
    [parameter(Mandatory=$false)][int]$Interval=5,
    [parameter(Mandatory=$false)][int]$MaxTries=25
) {
    $tries = 0
    Write-Host "Removing agent directory '${Path}'" -NoNewLine
    while ((Test-Path($Path)) -and ($tries -le $MaxTries)) {
        Write-Host "." -NoNewLine
        if (Get-Command rm -ErrorAction SilentlyContinue) {
            rm -r $Path 2>$null
        } else {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            # Get-ChildItem -Path $Path -Include * -Recurse | Remove-Item -Force
        }
        if (Test-Path($Path)) {
            Write-Verbose "File locked, trying again in ${Interval} seconds..."
            Start-Sleep -seconds $Interval
        }
        $tries++
    }
    if (Test-Path($Path)) {
        Write-Host "✗"
        Write-Warning "Could not remove directory '${Path}' after ${tries} tries"
    } else {
        Write-Host "✓"
    }
}