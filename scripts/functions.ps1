function Get-AccessToken () {
    # Log in with Azure CLI (if not logged in yet)
    Login-Az -DisplayMessages
    Write-Debug "az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798"
    az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 `
                                --query "accessToken" `
                                --output tsv `
                                | Set-Variable aadToken
    if (!$aadToken) {
        Write-Warning "Could not obtain AAD token, exiting"
        exit 1
    }
    Write-Debug "AAD Token: $($aadToken -replace '.','*')"

    return $aadToken
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
    [parameter(Mandatory=$false)][switch]$DisplayMessages=$false,
    [parameter(Mandatory=$false)][guid]$TenantId=($env:ARM_TENANT_ID ?? $env:AZURE_TENANT_ID)
) {
    # Are we logged in? If so, is it the right tenant?
    $azureAccount = $null
    az account show 2>$null | ConvertFrom-Json | Set-Variable azureAccount
    if ($azureAccount -and $TenantId -and ($azureAccount.tenantId -ine $TenantId)) {
        Write-Warning "Logged into tenant $($azureAccount.tenantId) instead of ${TenantId}"
        $azureAccount = $null
    }
    if (!$azureAccount) {
        if ($IsLinux) {
            $azLoginSwitches = "--use-device-code"
        }
        if ($env:ARM_TENANT_ID) {
            Write-Debug "az login -t ${env:ARM_TENANT_ID} -o none $($azLoginSwitches)"
            az login -t $env:ARM_TENANT_ID -o none $($azLoginSwitches)
        } else {
            Write-Debug "az login -o none $($azLoginSwitches)"
            az login -o none $($azLoginSwitches)
        }
    }
}